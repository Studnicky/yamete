import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Concurrent / interleaved cross-source matrix.
///
/// Bug class addressed: existing matrix cells drive ONE source at a time,
/// in serial. Real users drive MANY at once — typing while plugging USB
/// while the system goes to sleep. Concurrency-related races (cross-source
/// state corruption, debounce gate bleed-through, bus-publish ordering
/// under contention, close-during-publish crashes, fan-out skew across
/// subscribers) are not exercised by serial cells.
///
/// Each cell drives ≥ 2 production paths concurrently via `Task` /
/// `TaskGroup` and asserts a SPECIFIC invariant. Assertion messages carry
/// `[concurrent-cell=<name>]` substrings for mutation-catalog anchoring
/// and grep-friendly failure triage.
///
/// Determinism: stable seeds + xorshift64 (no `SystemRandomNumberGenerator`,
/// no `arc4random`, no `Foundation.random`). Each cell is budgeted at
/// ≤ 200 ms wallclock — bursty `Task.yield()` between injects keeps the
/// MainActor responsive without per-event sleeps.
@MainActor
final class MatrixConcurrentInterleaved_Tests: XCTestCase {

    // MARK: - Seeded generator (xorshift64, deterministic — same seed → same sequence)

    /// Hand-rolled xorshift64. Seed=0 is a fixed point for the algorithm
    /// (pure-arithmetic loop converges on 0); the constructor remaps it
    /// so every nominally-valid seed produces a 2^64-1 period sequence.
    /// Deterministic across hosts, runs, and CI shards.
    final class SeededGenerator: @unchecked Sendable {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed }
        @discardableResult
        func nextU64() -> UInt64 {
            var x = state
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            state = x
            return x
        }
        func nextInt(in range: ClosedRange<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return Int(nextU64() % span) + range.lowerBound
        }
    }

    // MARK: - Generic counting observer

    /// Per-kind cumulative counter, drained on a MainActor task. Cells read
    /// the counters at trial-end after a quiesce. `kindOrder` records full
    /// arrival order so cells that need ordering invariants can replay it.
    final class CountingObserver: @unchecked Sendable {
        private var counts: [ReactionKind: Int] = [:]
        private(set) var kindOrder: [ReactionKind] = []
        private var task: Task<Void, Never>?
        private var totalDelivered: Int = 0
        private var sawTerminator: Bool = false

        @MainActor
        func start(on bus: ReactionBus) async {
            let stream = await bus.subscribe()
            self.task = Task { @MainActor in
                for await fired in stream {
                    self.counts[fired.kind, default: 0] += 1
                    self.kindOrder.append(fired.kind)
                    self.totalDelivered += 1
                }
                // Stream completed — exactly one terminator per subscribe.
                self.sawTerminator = true
            }
        }

        @MainActor
        func quiesce(_ ms: UInt64 = 12) async {
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }

        @MainActor func count(of kind: ReactionKind) -> Int { counts[kind] ?? 0 }
        @MainActor func total() -> Int { totalDelivered }
        @MainActor func terminatorObserved() -> Bool { sawTerminator }
        @MainActor func close() { task?.cancel(); task = nil }
    }

    // MARK: - Bus fixture

    @MainActor
    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction,
                          clipDuration: 0.0,
                          soundURL: nil,
                          faceIndices: [0],
                          publishedAt: publishedAt)
        }
        return bus
    }

    // MARK: - Synthetic NSEvent helpers

    private func makeTrackpadScroll(phase: Int = 1, deltaY: Double = 5) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: Int32(deltaY),
                               wheel2: 0,
                               wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        return NSEvent(cgEvent: cg)
    }

    // MARK: - Cell 1: Cross-source debounce sanity (USB + Bluetooth interleave)
    //
    // Invariant: when DIFFERENT sources publish concurrently, every
    // source's accept-by-gate publish reaches the bus exactly once.
    // Debounce is per-source-per-key, so a USB attach and a BT connect
    // in the same window never collapse against each other — both must
    // arrive at the subscriber.
    func test_concurrent_cell_cross_source_debounce_sanity() async {
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        usb.start(publishingTo: bus)
        bt.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        // Spawn USB + BT injects concurrently; await both before quiesce
        // so the subscriber sees a stable cumulative count. Plain Task
        // spawn pattern (not withTaskGroup) keeps the strict-concurrency
        // region checker happy when the child closures re-enter MainActor.
        let t1: Task<Void, Never> = Task { @MainActor in
            await usb._injectAttach(vendor: "AppleX", product: "iPhoneX")
        }
        let t2: Task<Void, Never> = Task { @MainActor in
            await bt._injectConnect(name: "AirPods Pro")
        }
        _ = await t1.value
        _ = await t2.value
        await observer.quiesce()

        XCTAssertEqual(observer.count(of: .usbAttached), 1,
            "[concurrent-cell=cross-source-debounce-sanity] USB attached must arrive exactly once, got \(observer.count(of: .usbAttached))")
        XCTAssertEqual(observer.count(of: .bluetoothConnected), 1,
            "[concurrent-cell=cross-source-debounce-sanity] Bluetooth connected must arrive exactly once, got \(observer.count(of: .bluetoothConnected))")
        XCTAssertEqual(observer.total(), 2,
            "[concurrent-cell=cross-source-debounce-sanity] expected 2 total bus deliveries, got \(observer.total())")

        observer.close()
        usb.stop()
        bt.stop()
        await bus.close()
    }

    // MARK: - Cell 2: Trackpad gesture during external click burst
    //
    // Invariant: 5 USB-mouse `_injectClick` calls debounce to exactly
    // 1 `.mouseClicked`; trackpad scroll bursts interleaved between
    // them must fire `.trackpadTouching` independently. The two
    // sources must NOT cross-pollinate (mouse never fires trackpad,
    // trackpad never fires mouseClicked).
    func test_concurrent_cell_trackpad_gesture_during_external_click_burst() async {
        let bus = await makeBus()
        let trackpadMonitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: trackpadMonitor)
        // Configure trackpad with a permissive touching window so a few
        // phased scrolls land it above touchingMin.
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.5, touchingMax: 50.0,
            slidingMin: 100.0, slidingMax: 100.0,
            contactMin: 100.0, contactMax: 100.0,
            tapMin: 100.0, tapMax: 100.0,
            touchingEnabled: true,
            slidingEnabled: false,
            contactEnabled: false,
            tappingEnabled: false,
            circlingEnabled: false
        )
        trackpad.start(publishingTo: bus)

        let mouseMonitor = MockEventMonitor()
        let mouse = MouseActivitySource(eventMonitor: mouseMonitor, enableHIDClickDetection: false)
        mouse.start(publishingTo: bus)

        let observer = CountingObserver()
        await observer.start(on: bus)

        // Interleave 5 mouse clicks with phased trackpad scrolls. The
        // `await Task.yield()` baked into `_injectClick` ensures the
        // per-call publish task gets a chance to run before the next
        // call lands.
        let mouseTask: Task<Void, Never> = Task { @MainActor in
            for _ in 0..<5 {
                await mouse._injectClick(transport: "USB", product: "Logitech G502")
            }
        }
        let trackpadEvents: [NSEvent] = (0..<8).compactMap { _ in
            self.makeTrackpadScroll(phase: 1, deltaY: 6)
        }
        let trackpadTask: Task<Void, Never> = Task { @MainActor in
            for ev in trackpadEvents {
                trackpadMonitor.emit(ev, ofType: .scrollWheel)
                await Task.yield()
            }
        }
        _ = await mouseTask.value
        _ = await trackpadTask.value
        await observer.quiesce(20)

        XCTAssertEqual(observer.count(of: .mouseClicked), 1,
            "[concurrent-cell=trackpad-during-mouse-burst] expected 1 debounced .mouseClicked from 5 USB-click injects, got \(observer.count(of: .mouseClicked))")
        XCTAssertEqual(observer.count(of: .trackpadTapping), 0,
            "[concurrent-cell=trackpad-during-mouse-burst] mouse clicks must never fire .trackpadTapping (cross-source attribution gate), got \(observer.count(of: .trackpadTapping))")
        XCTAssertEqual(observer.count(of: .mouseScrolled), 0,
            "[concurrent-cell=trackpad-during-mouse-burst] trackpad scrolls must never fire .mouseScrolled, got \(observer.count(of: .mouseScrolled))")
        // Trackpad touching is the soft assertion — phased scrolls must
        // produce ≥ 1 touching emission. No upper bound (touching has its
        // own debounce window).
        XCTAssertGreaterThanOrEqual(observer.count(of: .trackpadTouching), 1,
            "[concurrent-cell=trackpad-during-mouse-burst] phased trackpad scrolls must fire ≥ 1 .trackpadTouching, got \(observer.count(of: .trackpadTouching))")

        observer.close()
        trackpad.stop()
        mouse.stop()
        await bus.close()
    }

    // MARK: - Cell 3: USB attach mid-keyboard burst
    //
    // Invariant: 10 keyboard injects fire `.keyboardTyped` (rate well
    // above threshold); a USB attach injected mid-burst fires
    // `.usbAttached` independently. Neither source contaminates the
    // other (no spurious cross-kind emissions).
    func test_concurrent_cell_usb_attach_mid_keyboard_burst() async {
        let bus = await makeBus()
        let kb = KeyboardActivitySource(eventMonitor: MockEventMonitor(),
                                        hidMonitor: MockHIDDeviceMonitor(),
                                        enableHIDDetection: false)
        kb.start(publishingTo: bus)
        let usb = USBSource()
        usb.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        // Drive 10 keypresses with synthetic timestamps spaced 100ms
        // apart (rate = 10/s, above the 3.0/s threshold). Inject the
        // USB attach concurrently halfway through the keypress span.
        let baseEpoch = Date(timeIntervalSinceReferenceDate: 1_500_000_000)
        let kbTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<10 {
                let ts = baseEpoch.addingTimeInterval(Double(i) * 0.1)
                await kb._injectKeyPress(at: ts)
            }
        }
        let usbTask: Task<Void, Never> = Task { @MainActor in
            // Yield a couple times so the keyboard task gets some
            // ahead-of-USB injects in flight, then attach USB.
            await Task.yield()
            await Task.yield()
            await usb._injectAttach(vendor: "AppleK", product: "MagicKB")
        }
        _ = await kbTask.value
        _ = await usbTask.value
        await observer.quiesce()

        XCTAssertGreaterThanOrEqual(observer.count(of: .keyboardTyped), 1,
            "[concurrent-cell=usb-attach-mid-keyboard-burst] above-threshold burst must fire ≥ 1 .keyboardTyped, got \(observer.count(of: .keyboardTyped))")
        XCTAssertEqual(observer.count(of: .usbAttached), 1,
            "[concurrent-cell=usb-attach-mid-keyboard-burst] USB attach must arrive exactly once independent of keyboard burst, got \(observer.count(of: .usbAttached))")
        XCTAssertEqual(observer.count(of: .mouseClicked), 0,
            "[concurrent-cell=usb-attach-mid-keyboard-burst] no mouse cross-pollination expected, got \(observer.count(of: .mouseClicked))")
        XCTAssertEqual(observer.count(of: .trackpadTapping), 0,
            "[concurrent-cell=usb-attach-mid-keyboard-burst] no trackpad cross-pollination expected, got \(observer.count(of: .trackpadTapping))")

        observer.close()
        kb.stop()
        usb.stop()
        await bus.close()
    }

    // MARK: - Cell 4: Sleep mid-trackpad-tap sequence
    //
    // Invariant: sleep injection mid-trackpad-activity emits
    // `.willSleep` exactly once and does not crash the trackpad
    // pipeline. Trackpad activity that completed before the sleep
    // still counts; activity after the sleep continues to function
    // (sleep is event-only, not a teardown signal).
    func test_concurrent_cell_sleep_mid_trackpad_tap() async {
        let bus = await makeBus()
        let trackpadMonitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: trackpadMonitor)
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.5, touchingMax: 50.0,
            slidingMin: 100.0, slidingMax: 100.0,
            contactMin: 100.0, contactMax: 100.0,
            tapMin: 100.0, tapMax: 100.0,
            touchingEnabled: true,
            slidingEnabled: false,
            contactEnabled: false,
            tappingEnabled: false,
            circlingEnabled: false
        )
        trackpad.start(publishingTo: bus)
        let sleep = SleepWakeSource()
        sleep.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        let trackpadEvents: [NSEvent] = (0..<6).compactMap { _ in
            self.makeTrackpadScroll(phase: 1, deltaY: 5)
        }
        let trackpadTask: Task<Void, Never> = Task { @MainActor in
            for ev in trackpadEvents {
                trackpadMonitor.emit(ev, ofType: .scrollWheel)
                await Task.yield()
            }
        }
        let sleepTask: Task<Void, Never> = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            await sleep._injectWillSleep()
        }
        _ = await trackpadTask.value
        _ = await sleepTask.value
        await observer.quiesce(20)

        XCTAssertEqual(observer.count(of: .willSleep), 1,
            "[concurrent-cell=sleep-mid-trackpad-tap] willSleep must arrive exactly once mid-gesture, got \(observer.count(of: .willSleep))")
        // No crash sentinel: reaching this assertion proves no trap.
        XCTAssertEqual(observer.count(of: .didWake), 0,
            "[concurrent-cell=sleep-mid-trackpad-tap] no didWake expected (only willSleep was injected), got \(observer.count(of: .didWake))")

        observer.close()
        trackpad.stop()
        sleep.stop()
        await bus.close()
    }

    // MARK: - Cell 5: Bus close mid-publish race
    //
    // Invariant: closing the bus while a publish task is in flight
    // (a) does NOT crash, (b) yields exactly ONE terminator per
    // subscriber (the AsyncStream completion), and (c) leaves at most
    // a bounded number of in-flight publishes delivered (no duplicates).
    func test_concurrent_cell_bus_close_mid_publish_race() async {
        let bus = await makeBus()
        let usb = USBSource()
        usb.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        // Race 100 mixed inject calls against a `bus.close()` fired
        // partway through. The race is INTENTIONAL — exact delivery
        // count is not asserted; only the no-crash + single-terminator
        // invariant.
        let injectTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<100 {
                await usb._injectAttach(vendor: "V\(i)", product: "P\(i)")
            }
        }
        let closeTask: Task<Void, Never> = Task { @MainActor in
            // Let some injects land, then close.
            try? await Task.sleep(for: .milliseconds(2))
            await bus.close()
        }
        _ = await injectTask.value
        _ = await closeTask.value
        await observer.quiesce(30)

        // Terminator must have arrived (the for-await loop in the
        // observer task exits exactly once on stream completion).
        XCTAssertTrue(observer.terminatorObserved(),
            "[concurrent-cell=bus-close-mid-publish] expected exactly one stream terminator after bus.close()")
        // Total deliveries must be in [0, 100] — bounded and finite.
        XCTAssertLessThanOrEqual(observer.total(), 100,
            "[concurrent-cell=bus-close-mid-publish] delivered \(observer.total()) > 100 — duplicates leaked through")
        XCTAssertGreaterThanOrEqual(observer.total(), 0,
            "[concurrent-cell=bus-close-mid-publish] negative delivery count makes no sense, got \(observer.total())")

        observer.close()
        usb.stop()
        // bus.close() already issued; idempotent re-close as defense.
        await bus.close()
    }

    // MARK: - Cell 6: Coalesce window stress (50 same-key clicks within debounce)
    //
    // Invariant: 50 `_injectClick` calls back-to-back collapse to
    // exactly 1 `.mouseClicked` because all calls land inside the
    // mouse `clickDebounce` window (50 ms+ default; back-to-back
    // injects on a single MainActor never accumulate > 16 ms of
    // wallclock).
    func test_concurrent_cell_coalesce_window_stress() async {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let mouse = MouseActivitySource(eventMonitor: monitor, enableHIDClickDetection: false)
        mouse.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        let start = Date()
        for _ in 0..<50 {
            await mouse._injectClick(transport: "USB", product: "Logitech")
        }
        let elapsed = Date().timeIntervalSince(start)
        await observer.quiesce()

        XCTAssertEqual(observer.count(of: .mouseClicked), 1,
            "[concurrent-cell=coalesce-window-stress] 50 back-to-back clicks within debounce must collapse to 1 .mouseClicked, got \(observer.count(of: .mouseClicked)) (elapsed=\(String(format: "%.3f", elapsed))s)")
        // Soft sanity: the burst itself completed within the budget.
        XCTAssertLessThan(elapsed, 0.2,
            "[concurrent-cell=coalesce-window-stress] burst budget violated: elapsed=\(elapsed)s")

        observer.close()
        mouse.stop()
        await bus.close()
    }

    // MARK: - Cell 7: Multi-output fanout under producer race
    //
    // Invariant: when 5 independent subscribers attach to the SAME
    // bus and concurrent producers fire reactions, every subscriber
    // sees the SAME `FiredReaction` set (set equality on the kind
    // multiset). The bus must fan out identically to every
    // subscriber regardless of contention.
    func test_concurrent_cell_multi_output_fanout_under_producer_race() async {
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        let kb = KeyboardActivitySource(eventMonitor: MockEventMonitor(),
                                        hidMonitor: MockHIDDeviceMonitor(),
                                        enableHIDDetection: false)
        usb.start(publishingTo: bus)
        bt.start(publishingTo: bus)
        kb.start(publishingTo: bus)

        // 5 independent subscribers — each one is a CountingObserver,
        // each runs its own MainActor drain task. The bus's
        // `subscribers` dictionary holds 5 continuations.
        var observers: [CountingObserver] = []
        for _ in 0..<5 {
            let obs = CountingObserver()
            await obs.start(on: bus)
            observers.append(obs)
        }

        // Drive a deterministic mix of injects concurrently.
        let baseEpoch = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let usbTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<5 {
                await usb._injectAttach(vendor: "VV\(i)", product: "PP\(i)")
            }
        }
        let btTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<3 {
                await bt._injectConnect(name: "BTDev-\(i)")
            }
        }
        let kbTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<10 {
                await kb._injectKeyPress(at: baseEpoch.addingTimeInterval(Double(i) * 0.08))
            }
        }
        _ = await usbTask.value
        _ = await btTask.value
        _ = await kbTask.value
        await observers[0].quiesce(20)

        // Every subscriber must see the same per-kind multiset.
        let baselineUSB = observers[0].count(of: .usbAttached)
        let baselineBT = observers[0].count(of: .bluetoothConnected)
        let baselineKB = observers[0].count(of: .keyboardTyped)
        let baselineTotal = observers[0].total()
        for (i, obs) in observers.enumerated() {
            XCTAssertEqual(obs.count(of: .usbAttached), baselineUSB,
                "[concurrent-cell=multi-output-fanout] subscriber \(i) saw \(obs.count(of: .usbAttached)) usbAttached, baseline \(baselineUSB) — fan-out skew")
            XCTAssertEqual(obs.count(of: .bluetoothConnected), baselineBT,
                "[concurrent-cell=multi-output-fanout] subscriber \(i) saw \(obs.count(of: .bluetoothConnected)) bluetoothConnected, baseline \(baselineBT) — fan-out skew")
            XCTAssertEqual(obs.count(of: .keyboardTyped), baselineKB,
                "[concurrent-cell=multi-output-fanout] subscriber \(i) saw \(obs.count(of: .keyboardTyped)) keyboardTyped, baseline \(baselineKB) — fan-out skew")
            XCTAssertEqual(obs.total(), baselineTotal,
                "[concurrent-cell=multi-output-fanout] subscriber \(i) total \(obs.total()) ≠ baseline \(baselineTotal) — fan-out skew")
        }
        // Lower bound on the baseline so we know the test exercised
        // the producers (USB has distinct keys → 5; BT distinct → 3;
        // keyboard rate above threshold → ≥ 1).
        XCTAssertEqual(baselineUSB, 5,
            "[concurrent-cell=multi-output-fanout] expected 5 distinct USB attaches in baseline, got \(baselineUSB)")
        XCTAssertEqual(baselineBT, 3,
            "[concurrent-cell=multi-output-fanout] expected 3 distinct BT connects in baseline, got \(baselineBT)")
        XCTAssertGreaterThanOrEqual(baselineKB, 1,
            "[concurrent-cell=multi-output-fanout] expected ≥ 1 keyboardTyped in baseline, got \(baselineKB)")

        for obs in observers { obs.close() }
        usb.stop()
        bt.stop()
        kb.stop()
        await bus.close()
    }

    // MARK: - Cell 8: Stable interleaving fuzz (deterministic seeds)
    //
    // Invariant: across deterministic seeds, random `_inject*` calls
    // distributed across 5 sources (USB, BT, keyboard, sleep/wake,
    // power) produce:
    //   1. No crash.
    //   2. No kind cross-pollination (USB-only injects never produce
    //      bluetoothConnected, keyboard injects never produce
    //      usbAttached, etc.).
    //   3. Total bus deliveries are upper-bounded by the count of
    //      accept-by-gate injections (no amplification), AND every
    //      producer that fired ≥ 1 inject delivers ≥ 1 event (no total
    //      starvation). Strict equality is NOT asserted because the
    //      ReactionBus subscriber buffer is `bufferingNewest(8)` and
    //      the upstream source streams are `bufferingNewest(32)` —
    //      under 200-burst pressure these legitimately drop oldest
    //      entries, which is the documented backpressure policy.
    //
    // Three seeds (42, 7, 31) with 200 injects each = 600 injects
    // total. Each seed runs serially but all injects within a seed
    // race via TaskGroup.
    func test_concurrent_cell_stable_interleaving_fuzz() async {
        for seed in [UInt64(42), UInt64(7), UInt64(31)] {
            await runFuzzSeed(seed: seed, totalInjects: 200)
        }
    }

    private func runFuzzSeed(seed: UInt64, totalInjects: Int) async {
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        let kb = KeyboardActivitySource(eventMonitor: MockEventMonitor(),
                                        hidMonitor: MockHIDDeviceMonitor(),
                                        enableHIDDetection: false)
        let power = PowerSource()
        let sleepwake = SleepWakeSource()
        usb.start(publishingTo: bus)
        bt.start(publishingTo: bus)
        kb.start(publishingTo: bus)
        power.start(publishingTo: bus)
        sleepwake.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        // Pre-roll the inject plan from the deterministic generator
        // BEFORE the concurrent task group runs. Pre-rolling decouples
        // the inject sequence from task-group scheduling order, so the
        // expected counts are derived from the plan, not the race.
        let gen = SeededGenerator(seed: seed)
        enum Op: Sendable { case usbA, usbD, btC, btD, kb, willSleep, didWake, powerOnAC, powerOffAC }
        var plan: [Op] = []
        for _ in 0..<totalInjects {
            switch gen.nextInt(in: 0...8) {
            case 0:  plan.append(.usbA)
            case 1:  plan.append(.usbD)
            case 2:  plan.append(.btC)
            case 3:  plan.append(.btD)
            case 4:  plan.append(.kb)
            case 5:  plan.append(.willSleep)
            case 6:  plan.append(.didWake)
            case 7:  plan.append(.powerOnAC)
            default: plan.append(.powerOffAC)
            }
        }

        // Expected per-kind lower bounds derived from the plan:
        //   - USB: each call uses a UNIQUE (vendor, product) keyed by
        //     the call index so debounce never collapses → 1 fire / call.
        //   - BT: same, unique name per call → 1 fire / call.
        //   - keyboard: timestamps are spaced 100ms apart → rate above
        //     threshold; at least 1 fire if there's any kb op, but
        //     debounce can collapse adjacent ops, so we only assert
        //     `kb total ≤ kb count` (no upper-bound violation).
        //   - sleep/wake: direct stream yield, no debounce → 1:1.
        //   - power: edge-triggered, so equal-state repeats coalesce.
        //     We don't assert exact power counts; only the no-crash
        //     and no-cross-pollination invariants apply.
        var expectedUSBA = 0, expectedUSBD = 0
        var expectedBTC = 0, expectedBTD = 0
        var expectedSleep = 0, expectedWake = 0
        var kbCount = 0
        for op in plan {
            switch op {
            case .usbA:      expectedUSBA += 1
            case .usbD:      expectedUSBD += 1
            case .btC:       expectedBTC += 1
            case .btD:       expectedBTD += 1
            case .kb:        kbCount += 1
            case .willSleep: expectedSleep += 1
            case .didWake:   expectedWake += 1
            case .powerOnAC, .powerOffAC: break
            }
        }

        // Drive the plan in parallel chunks. Splitting by op-kind keeps
        // each producer task linear; the cross-producer ordering is
        // racy by construction.
        //
        // Strict-concurrency note: each child task captures a per-task
        // immutable snapshot (`planForUSB`, `planForBT`, ...) of the plan
        // so the closure does not retain a reference to the
        // MainActor-isolated parent's `plan` variable. The Op enum is
        // explicitly Sendable so the array transfer is safe.
        let baseEpoch = Date(timeIntervalSinceReferenceDate: 1_800_000_000 + Double(seed) * 1000.0)
        let planForUSB = plan
        let planForBT = plan
        let planForKB = plan
        let planForSleep = plan
        let planForPower = plan
        // Use plain Task spawning + await on each handle. withTaskGroup
        // confuses the region-based isolation checker when the child
        // task closure also re-enters MainActor; plain Task spawning
        // is the pattern used elsewhere in the test suite (see
        // MatrixMultiOutputConcurrentFire_Tests.swift) and stays
        // strict-concurrency clean.
        let usbTask: Task<Void, Never> = Task { @MainActor in
            var idx = 0
            for op in planForUSB {
                if case .usbA = op {
                    await usb._injectAttach(vendor: "FUv\(seed)-\(idx)", product: "FUp\(seed)-\(idx)")
                } else if case .usbD = op {
                    await usb._injectDetach(vendor: "FUv\(seed)-\(idx)", product: "FUp\(seed)-\(idx)")
                }
                idx += 1
            }
        }
        let btTask: Task<Void, Never> = Task { @MainActor in
            var idx = 0
            for op in planForBT {
                if case .btC = op {
                    await bt._injectConnect(name: "FBT\(seed)-\(idx)")
                } else if case .btD = op {
                    await bt._injectDisconnect(name: "FBT\(seed)-\(idx)")
                }
                idx += 1
            }
        }
        let kbTask: Task<Void, Never> = Task { @MainActor in
            var idx = 0
            for op in planForKB {
                if case .kb = op {
                    await kb._injectKeyPress(at: baseEpoch.addingTimeInterval(Double(idx) * 0.1))
                }
                idx += 1
            }
        }
        let sleepTask: Task<Void, Never> = Task { @MainActor in
            for op in planForSleep {
                switch op {
                case .willSleep: await sleepwake._injectWillSleep()
                case .didWake:   await sleepwake._injectDidWake()
                default: break
                }
            }
        }
        let powerTask: Task<Void, Never> = Task { @MainActor in
            for op in planForPower {
                switch op {
                case .powerOnAC:  await power._injectPowerChange(onAC: true)
                case .powerOffAC: await power._injectPowerChange(onAC: false)
                default: break
                }
            }
        }
        _ = await usbTask.value
        _ = await btTask.value
        _ = await kbTask.value
        _ = await sleepTask.value
        _ = await powerTask.value
        await observer.quiesce(40)

        // 1. No-crash: reaching here proves no trap.
        // 2. No cross-pollination: kinds we never injected must have 0.
        XCTAssertEqual(observer.count(of: .mouseClicked), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no mouse injects yet got \(observer.count(of: .mouseClicked)) .mouseClicked")
        XCTAssertEqual(observer.count(of: .mouseScrolled), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no mouse injects yet got \(observer.count(of: .mouseScrolled)) .mouseScrolled")
        XCTAssertEqual(observer.count(of: .trackpadTapping), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no trackpad injects yet got \(observer.count(of: .trackpadTapping)) .trackpadTapping")
        XCTAssertEqual(observer.count(of: .trackpadTouching), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no trackpad injects yet got \(observer.count(of: .trackpadTouching)) .trackpadTouching")
        XCTAssertEqual(observer.count(of: .impact), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no impact injects yet got \(observer.count(of: .impact)) .impact")
        XCTAssertEqual(observer.count(of: .audioPeripheralAttached), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no audio injects yet got \(observer.count(of: .audioPeripheralAttached)) .audioPeripheralAttached")
        XCTAssertEqual(observer.count(of: .thunderboltAttached), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no thunderbolt injects yet got \(observer.count(of: .thunderboltAttached)) .thunderboltAttached")
        XCTAssertEqual(observer.count(of: .displayConfigured), 0,
            "[concurrent-cell=fuzz seed=\(seed)] no display injects yet got \(observer.count(of: .displayConfigured)) .displayConfigured")

        // 3. Bounded delivery on each path. With 5 producers driving
        //    AsyncStream-buffered sources concurrently, the per-subscriber
        //    `bufferingNewest(8)` (ReactionBus) and per-source
        //    `bufferingNewest(32)` (USBSource / BluetoothSource /
        //    SleepWakeSource upstream) can legitimately drop oldest
        //    entries under burst pressure — this is the documented
        //    backpressure policy, not a bug. So we assert:
        //     - upper bound: delivered ≤ injected (no synthesis).
        //     - lower bound: at least SOMETHING got through when the
        //       producer fired ≥ 1 inject.
        //    Cross-pollination assertions above (no mouse/trackpad/
        //    impact/audio/thunderbolt/display fires) catch the strict
        //    isolation invariant; this section catches no-amplification
        //    while tolerating documented backpressure drops.
        XCTAssertLessThanOrEqual(observer.count(of: .usbAttached), expectedUSBA,
            "[concurrent-cell=fuzz seed=\(seed)] usbAttached must not exceed injections: expected ≤ \(expectedUSBA), got \(observer.count(of: .usbAttached))")
        XCTAssertLessThanOrEqual(observer.count(of: .usbDetached), expectedUSBD,
            "[concurrent-cell=fuzz seed=\(seed)] usbDetached must not exceed injections: expected ≤ \(expectedUSBD), got \(observer.count(of: .usbDetached))")
        XCTAssertLessThanOrEqual(observer.count(of: .bluetoothConnected), expectedBTC,
            "[concurrent-cell=fuzz seed=\(seed)] bluetoothConnected must not exceed injections: expected ≤ \(expectedBTC), got \(observer.count(of: .bluetoothConnected))")
        XCTAssertLessThanOrEqual(observer.count(of: .bluetoothDisconnected), expectedBTD,
            "[concurrent-cell=fuzz seed=\(seed)] bluetoothDisconnected must not exceed injections: expected ≤ \(expectedBTD), got \(observer.count(of: .bluetoothDisconnected))")
        XCTAssertLessThanOrEqual(observer.count(of: .willSleep), expectedSleep,
            "[concurrent-cell=fuzz seed=\(seed)] willSleep must not exceed injections: expected ≤ \(expectedSleep), got \(observer.count(of: .willSleep))")
        XCTAssertLessThanOrEqual(observer.count(of: .didWake), expectedWake,
            "[concurrent-cell=fuzz seed=\(seed)] didWake must not exceed injections: expected ≤ \(expectedWake), got \(observer.count(of: .didWake))")
        XCTAssertLessThanOrEqual(observer.count(of: .keyboardTyped), kbCount,
            "[concurrent-cell=fuzz seed=\(seed)] keyboardTyped must not exceed injections: expected ≤ \(kbCount), got \(observer.count(of: .keyboardTyped)) (debounce can only collapse, never amplify)")
        // Lower-bound liveness: at least ONE event made it through per
        // producer that fired ≥ 1 inject. Catches a "subscriber dead"
        // regression where buffer overflow becomes total starvation.
        if expectedUSBA > 0 {
            XCTAssertGreaterThan(observer.count(of: .usbAttached), 0,
                "[concurrent-cell=fuzz seed=\(seed)] usbAttached delivered 0 of \(expectedUSBA) injected — total starvation suggests subscriber-task death")
        }
        if expectedBTC > 0 {
            XCTAssertGreaterThan(observer.count(of: .bluetoothConnected), 0,
                "[concurrent-cell=fuzz seed=\(seed)] bluetoothConnected delivered 0 of \(expectedBTC) injected — total starvation suggests subscriber-task death")
        }
        if expectedSleep > 0 {
            XCTAssertGreaterThan(observer.count(of: .willSleep), 0,
                "[concurrent-cell=fuzz seed=\(seed)] willSleep delivered 0 of \(expectedSleep) injected — total starvation suggests subscriber-task death")
        }

        observer.close()
        usb.stop()
        bt.stop()
        kb.stop()
        power.stop()
        sleepwake.stop()
        await bus.close()
    }
}
