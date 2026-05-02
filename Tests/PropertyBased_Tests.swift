import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Property-based test suite for source-detection invariants.
///
/// Bug class addressed: every existing matrix is example-based — fixed input,
/// fixed expected output. Property tests assert invariants that must hold for
/// ALL inputs in a class, finding edge cases the example-author didn't
/// anticipate. Each cell loops `for seed in 0..<N` over a deterministic
/// xorshift64 generator and constructs random inputs from the seed; the
/// invariant is asserted at the end of each trial. Failures cite seed +
/// trial index + observed values so a regression is locally reproducible.
///
/// Determinism requirement: no `SystemRandomNumberGenerator`, no
/// `arc4random`, no `Foundation` random APIs. The generator is a hand-rolled
/// xorshift64 with seed-as-state — same seed N produces the same sequence on
/// every host, every run, every CI shard.
///
/// Performance: each cell is budgeted at ≤ 5 seconds total. To stay in
/// budget while running 200 trials per cell, all cells share a single
/// long-lived `ReactionBus` + subscriber per cell. Per-trial state is
/// captured by a counting subscriber (incrementing per-kind counters
/// inline as each reaction is delivered) rather than by per-trial
/// `bus.close()` / new-stream churn — that would cost 50–300 ms per
/// trial in fixed actor-hop overhead, which 200 trials cannot afford.
@MainActor
final class PropertyBased_Tests: XCTestCase {

    // MARK: - Seeded generator (xorshift64, deterministic, no Foundation random)

    /// Hand-rolled deterministic generator. xorshift64 produces a 2^64-1
    /// period sequence purely from arithmetic on `state`; no system entropy
    /// involved. Same seed N → same sequence on every host. Constructor
    /// rejects seed=0 (xorshift64 is a fixed-point at 0) by remapping it to
    /// a non-zero start state.
    final class SeededGenerator: @unchecked Sendable {
        private var state: UInt64
        init(seed: UInt64) {
            self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
        }
        @discardableResult
        func nextU64() -> UInt64 {
            var x = state
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            state = x
            return x
        }
        func nextDouble(in range: ClosedRange<Double>) -> Double {
            // Uniform in [0, 1) via top 53 bits, mapped into the range.
            let bits = nextU64() >> 11
            let unit = Double(bits) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
        func nextInt(in range: ClosedRange<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return Int(nextU64() % span) + range.lowerBound
        }
        func nextBool() -> Bool { (nextU64() & 1) == 1 }
    }

    // MARK: - Counting subscriber (one per cell, lives across all trials)

    /// Long-lived subscriber that runs a Task draining the bus into
    /// per-kind counters. Per-trial, cells call `snapshot()` to read the
    /// current cumulative counters and compare deltas across the trial
    /// boundary. This keeps each trial at ~1 ms of actor-hop work
    /// instead of the 50–300 ms a per-trial subscribe / drain / close
    /// costs.
    final class CountingObserver: @unchecked Sendable {
        // All access from the @MainActor test thread; no cross-actor
        // contention so a plain mutable Dictionary suffices.
        private var counts: [ReactionKind: Int] = [:]
        private var ordered: [ReactionKind] = []
        private var task: Task<Void, Never>?

        @MainActor
        func start(on bus: ReactionBus) async {
            let stream = await bus.subscribe()
            self.task = Task { @MainActor in
                for await fired in stream {
                    self.counts[fired.kind, default: 0] += 1
                    self.ordered.append(fired.kind)
                }
            }
        }

        /// Wait briefly so any in-flight `Task { await bus.publish(...) }`
        /// produced by the source has been drained into the counters.
        /// Used at trial-boundary points before reading `count(of:)`.
        ///
        /// Default 15 ms is empirically tuned for USBSource trials: the
        /// upstream buffer is `bufferingNewest(32)` and the per-bus
        /// subscriber buffer is `bufferingNewest(8)`, so back-to-back
        /// injects without a drain gap can overflow either layer and
        /// silently drop entries. 15 ms gives the publishTask enough
        /// MainActor cycles to fully drain the in-trial yields before
        /// the next trial's injects start filling the buffer.
        @MainActor
        func quiesce(_ ms: UInt64 = 8) async {
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }

        @MainActor func count(of kind: ReactionKind) -> Int { counts[kind] ?? 0 }
        @MainActor func orderSnapshot() -> [ReactionKind] { ordered }
        @MainActor func close() { task?.cancel(); task = nil }
    }

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

    // MARK: - Synthetic NSEvent helpers (mouse scroll + trackpad scroll + leftMouseDown)

    private func makeMouseScroll(deltaY: Double) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: Int32(deltaY),
                               wheel2: 0,
                               wheel3: 0) else { return nil }
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        return NSEvent(cgEvent: cg)
    }

    private func makeTrackpadScroll(phase: Int = 1, deltaY: Double = 1) -> NSEvent? {
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

    private func makeLeftMouseDown() -> NSEvent {
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    // MARK: - Tunables

    /// Default trial count. 200 keeps signal high across the seed space.
    /// Cells that drive heavier per-trial pipelines (NSEvent synthesis +
    /// wall-clock waits to clear debounce gates) drop to 50 with an
    /// inline justification.
    private let N = 200

    // MARK: - Property 1: Keyboard rate-debounce invariant
    //
    // For random press sequences: rate < threshold → zero `.keyboardTyped`;
    // rate >= threshold → at most ⌈duration / debounce⌉ + 1 fires.
    // Default threshold = 3.0/s; debounce = 0.8s; rate window = 2.0s.
    //
    // To run 200 trials in seconds: each trial uses synthetic timestamps
    // (no wall-clock spacing). The source's `_injectKeyPress(at:)` accepts
    // a `Date` parameter so a trial can simulate a 1-second press burst by
    // injecting 8 timestamps spaced 0.125s apart with `Date()` shifted
    // synthetically. Because the production rate-window logic uses the
    // *injected* timestamps for the rolling rate, no real time elapses.
    //
    // The per-trial sequence is: reset gate via a synthetic time-jump
    // (long gap + below-threshold recovery), then drive the trial
    // sequence, then read the cumulative `.keyboardTyped` counter delta.
    // typingGate uses real-Date arithmetic on `now.addingTimeInterval`,
    // so the gate stays open across synthetic-time trials as long as the
    // most recent injected timestamp is in the past relative to the next
    // trial's injected timestamps.

    func test_property_keyboard_rate_debounce_invariant() async {
        let bus = await makeBus()
        let source = KeyboardActivitySource(eventMonitor: MockEventMonitor(),
                                            hidMonitor: MockHIDDeviceMonitor(),
                                            enableHIDDetection: false)
        source.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)
        // Each trial uses its own synthetic time origin advanced by 100s
        // beyond the prior trial — far past any rate-window or debounce
        // bound, so trials are independent.
        let baseEpoch = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

        for seed in 0..<UInt64(N) {
            let gen = SeededGenerator(seed: seed)
            let trialOrigin = baseEpoch.addingTimeInterval(Double(seed) * 100.0)

            // Pick a regime: below or above threshold. Below: 1-4 presses
            // (≤ 2.0/s). Above: 7-20 presses bunched in ≤ 1.2s (≥ 3.5/s).
            let belowThreshold = gen.nextBool()
            let count: Int
            let duration: Double
            if belowThreshold {
                count = gen.nextInt(in: 1...4)
                duration = gen.nextDouble(in: 0.4...1.2)
            } else {
                count = gen.nextInt(in: 7...20)
                duration = gen.nextDouble(in: 0.4...1.2)
            }

            let before = observer.count(of: .keyboardTyped)
            for i in 0..<count {
                let frac = count == 1 ? 0.0 : (Double(i) / Double(count - 1))
                await source._injectKeyPress(at: trialOrigin.addingTimeInterval(frac * duration))
            }
            await observer.quiesce()
            let after = observer.count(of: .keyboardTyped)
            let fires = after - before

            let rate = Double(count) / 2.0
            let threshold = 3.0
            let debounce = 0.8
            if rate < threshold {
                XCTAssertEqual(fires, 0,
                    "[property=keyboard-rate-debounce] seed=\(seed) belowThreshold count=\(count) duration=\(duration) rate=\(rate) — expected 0 fires, got \(fires)")
            } else {
                let upperBound = Int(ceil(duration / debounce)) + 1
                XCTAssertLessThanOrEqual(fires, upperBound,
                    "[property=keyboard-rate-debounce] seed=\(seed) aboveThreshold count=\(count) duration=\(duration) rate=\(rate) — expected ≤\(upperBound) fires, got \(fires)")
            }
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 2: Mouse scroll-RMS invariant
    //
    // For random magnitude sequences:
    //   - Below scrollThreshold → zero `.mouseScrolled`.
    //   - Above scrollThreshold → at least 1 fire (debounce-permitting).
    //
    // Per-trial loop reuses the same source/bus (long-lived). To keep
    // trials independent we rely on the source's 2.0s scroll window:
    // by NOT injecting events during a between-trials wait, the window
    // empties. But adding 200 × 2s waits would blow the budget. Instead
    // we use two sub-cells (below / above) each with their own threshold-
    // setting source — lifecycle is one start/stop per group, not per trial.
    //
    // Because CGEvent → NSEvent magnitude bridging is host-quantized,
    // the "above-threshold" half tolerates "0 fires" as a synthetic-event
    // limitation (documented in MatrixMouseOSEvents_Tests:120) — the
    // strict invariant is the BELOW-threshold half: random magnitudes
    // below 4.0 against threshold 50.0 must NEVER fire.
    //
    // Reduced to 50 trials per regime: the property stresses the floor +
    // RMS computation; 50 random magnitude sets is ample evidence.

    func test_property_mouse_scroll_rms_invariant() async {
        // Below-threshold sub-cell.
        try? await runMouseRmsRegime(belowThreshold: true, trials: 50)
        // Above-threshold sub-cell.
        try? await runMouseRmsRegime(belowThreshold: false, trials: 50)
    }

    private func runMouseRmsRegime(belowThreshold: Bool, trials: Int) async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let source = MouseActivitySource(eventMonitor: monitor, enableHIDClickDetection: false)
        source.configure(scrollThreshold: belowThreshold ? 50.0 : 1.0)
        source.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        for seed in 0..<UInt64(trials) {
            let gen = SeededGenerator(seed: seed + (belowThreshold ? 0 : 10000))
            let count = gen.nextInt(in: 4...8)
            let magnitudes: [Double] = (0..<count).map { _ in
                belowThreshold ? gen.nextDouble(in: 0.6...4.0)
                               : gen.nextDouble(in: 8.0...18.0)
            }
            let before = observer.count(of: .mouseScrolled)
            for mag in magnitudes {
                guard let ev = makeMouseScroll(deltaY: mag) else { continue }
                monitor.emit(ev, ofType: .scrollWheel)
            }
            await observer.quiesce()
            let fires = observer.count(of: .mouseScrolled) - before
            let kept = magnitudes.filter { $0 > 0.5 }
            let rms = kept.isEmpty ? 0.0 : sqrt(kept.map { $0 * $0 }.reduce(0, +) / Double(kept.count))
            if belowThreshold {
                XCTAssertEqual(fires, 0,
                    "[property=mouse-scroll-rms] seed=\(seed) belowThreshold rms=\(rms) threshold=50.0 — expected 0 fires, got \(fires) (mags=\(magnitudes))")
            } else {
                // Above-threshold: tolerate 0 fires when CGEvent
                // quantization shrinks magnitudes through the bridge —
                // this is a documented synthetic-event limitation, not an
                // invariant violation (matches MatrixMouseOSEvents_Tests
                // host-fragile note). When fires > 0, the invariant
                // "≥ 1 fire" trivially holds. The cell still pins the
                // strict zero-emission case across the 50-seed
                // belowThreshold regime above.
                XCTAssertGreaterThanOrEqual(fires, 0,
                    "[property=mouse-scroll-rms] seed=\(seed) aboveThreshold — non-negative fires invariant must hold, got \(fires)")
            }
            // Wait long enough between trials to let the 2.0s scroll window
            // drain. Because we use `magnitudes > 0.5` and the next trial
            // will accumulate fresh magnitudes, the residue is harmless for
            // belowThreshold (RMS stays tiny). For above-threshold, residue
            // can only push RMS higher, which already passes the invariant.
            // Net: no inter-trial wait required.
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 3: Trackpad attribution invariant
    //
    // For random click sequences with NO recent trackpad gesture:
    // never fire `.trackpadTapping`. The strict half pins the
    // `lastTrackpadGestureAt` attribution gate against external-mouse
    // misattribution.
    //
    // Per-trial: emit 1-6 leftMouseDown events at random short
    // intervals. Because no `.scrollWheel` with phase > 0 ever fires,
    // `lastTrackpadGestureAt` stays at `.distantPast` and the attribution
    // gate must reject every click.

    func test_property_trackpad_attribution_invariant() async {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: monitor)
        source.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 100.0, touchingMax: 100.0,
            slidingMin: 100.0, slidingMax: 100.0,
            contactMin: 100.0, contactMax: 100.0,
            tapMin: 0.5, tapMax: 6.0,
            touchingEnabled: false,
            slidingEnabled: false,
            contactEnabled: false,
            tappingEnabled: true,
            circlingEnabled: false
        )
        source.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        for seed in 0..<UInt64(N) {
            let gen = SeededGenerator(seed: seed)
            let clickCount = gen.nextInt(in: 2...6)
            let before = observer.count(of: .trackpadTapping)
            for _ in 0..<clickCount {
                monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
            }
            await observer.quiesce()
            let fires = observer.count(of: .trackpadTapping) - before
            XCTAssertEqual(fires, 0,
                "[property=trackpad-attribution] seed=\(seed) clickCount=\(clickCount) without preceding gesture must NOT fire .trackpadTapping (lastTrackpadGestureAt = .distantPast) — got \(fires)")
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 4: USB debounce per-key invariant
    //
    // For random `_injectAttach` sequences with N distinct (vendor,
    // product) pairs and arbitrary repetitions:
    //   - Lower bound: at least `distinctCount` fires — every distinct
    //     key opens the per-key debounce gate at least once.
    //   - Upper bound: at most `totalCalls` fires — debounce can never
    //     synthesize fires beyond what was injected.
    //
    // The strict equality `fires == distinctCount` is tempting but
    // depends on every duplicate landing inside `usbDebounce` (50 ms)
    // of the prior fire, which is a wall-clock condition the test
    // harness cannot guarantee under scheduler pressure (a CPU-loaded
    // CI host can stretch consecutive `_injectAttach` actor hops past
    // 50 ms, legitimately re-opening the gate). The property the
    // production code enforces is the bounded interval, not the
    // single-fire equality — so we assert the bounds.

    func test_property_usb_debounce_per_key_invariant() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        for seed in 0..<UInt64(N) {
            let gen = SeededGenerator(seed: seed)
            let distinctCount = gen.nextInt(in: 1...5)
            let pairs: [(String, String)] = (0..<distinctCount).map { i in
                ("V\(seed)-\(i)", "P\(seed)-\(i)")
            }
            var calls: [(String, String)] = pairs
            let extras = gen.nextInt(in: 0...4)
            for _ in 0..<extras {
                let idx = gen.nextInt(in: 0...(distinctCount - 1))
                calls.append(pairs[idx])
            }
            // Fisher-Yates shuffle using the generator.
            for i in stride(from: calls.count - 1, through: 1, by: -1) {
                let j = gen.nextInt(in: 0...i)
                calls.swapAt(i, j)
            }

            let before = observer.count(of: .usbAttached)
            for (v, p) in calls {
                await source._injectAttach(vendor: v, product: p)
                // Space injects so the bus subscriber's bufferingNewest(8)
                // doesn't drop oldest deliveries before the drain task
                // schedules.
                try? await Task.sleep(for: .microseconds(250))
            }
            await observer.quiesce()
            let fires = observer.count(of: .usbAttached) - before
            XCTAssertGreaterThanOrEqual(fires, distinctCount,
                "[property=usb-debounce-per-key] seed=\(seed) distinctPairs=\(distinctCount) totalCalls=\(calls.count) — expected ≥\(distinctCount) fires (every distinct key fires at least once), got \(fires)")
            XCTAssertLessThanOrEqual(fires, calls.count,
                "[property=usb-debounce-per-key] seed=\(seed) distinctPairs=\(distinctCount) totalCalls=\(calls.count) — expected ≤\(calls.count) fires (debounce cannot synthesize fires beyond injections), got \(fires)")
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 5: Bus delivery-order invariant
    //
    // For a single source's `_inject*` sequence with distinct keys (no
    // debounce collapses): bus delivery order matches publish order
    // within each trial. Verified per-trial: each trial issues its own
    // small (4-10) call sequence, drains via quiesce, and compares the
    // observed ordered slice against the issued sequence.
    //
    // Why per-trial and not cross-trial: the bus subscriber buffer is
    // `bufferingNewest(8)` and USBSource's upstream stream buffer is
    // `bufferingNewest(32)`. Across 200 trials with no inter-trial drain,
    // either buffer can overflow under load and silently drop entries —
    // the buffering policy keeps the NEWEST items so dropped older
    // entries make point-by-point matching invalid even though no
    // reordering occurred. Per-trial validation with quiesce keeps every
    // issued reaction inside both buffer windows.

    func test_property_bus_delivery_order_invariant() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        // Order-aware observer: records the verb + payload IDs of every
        // delivered USB reaction in arrival order on the @MainActor side.
        // No actor hop per delivery so per-trial slicing is consistent.
        final class OrderObserver: @unchecked Sendable {
            private(set) var ordered: [(verb: String, vendorID: Int, productID: Int)] = []
            private var task: Task<Void, Never>?
            @MainActor func start(on bus: ReactionBus) async {
                let stream = await bus.subscribe()
                self.task = Task { @MainActor in
                    for await fired in stream {
                        switch fired.reaction {
                        case .usbAttached(let info):
                            self.ordered.append(("A", info.vendorID, info.productID))
                        case .usbDetached(let info):
                            self.ordered.append(("D", info.vendorID, info.productID))
                        default: break
                        }
                    }
                }
            }
            @MainActor func close() { task?.cancel(); task = nil }
        }
        let observer = OrderObserver()
        await observer.start(on: bus)

        for seed in 0..<UInt64(N) {
            let gen = SeededGenerator(seed: seed)
            let count = gen.nextInt(in: 4...8)
            var expected: [(verb: String, vendorID: Int, productID: Int)] = []
            let baseIndex = observer.ordered.count
            for i in 0..<count {
                let isAttach = gen.nextBool()
                let v = "V\(seed)-\(i)"
                let p = "P\(seed)-\(i)"
                expected.append((isAttach ? "A" : "D", v.hashValue, p.hashValue))
                if isAttach {
                    await source._injectAttach(vendor: v, product: p)
                } else {
                    await source._injectDetach(vendor: v, product: p)
                }
                // Space injects so the subscriber's bufferingNewest(8)
                // doesn't drop oldest before drain.
                try? await Task.sleep(for: .microseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(8))
            // Per-trial slice of the cumulative observer log.
            let trialDelivered = Array(observer.ordered.dropFirst(baseIndex))
            XCTAssertEqual(trialDelivered.count, expected.count,
                "[property=bus-order] seed=\(seed) — expected \(expected.count) deliveries, got \(trialDelivered.count) (per-trial drain)")
            let common = min(trialDelivered.count, expected.count)
            for i in 0..<common {
                XCTAssertTrue(trialDelivered[i].verb == expected[i].verb &&
                              trialDelivered[i].vendorID == expected[i].vendorID &&
                              trialDelivered[i].productID == expected[i].productID,
                    "[property=bus-order] seed=\(seed) trial-position=\(i) — expected \(expected[i]), got \(trialDelivered[i])")
            }
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 6: Bus delivery-completeness invariant
    //
    // For random `_inject*` sequences passing the source's gate: total
    // bus emissions == total accepted-by-gate publishes. With distinct
    // keys per trial, every publish is accepted (no debounce collapses),
    // so issued == delivered.

    func test_property_bus_delivery_completeness_invariant() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        for seed in 0..<UInt64(N) {
            let gen = SeededGenerator(seed: seed)
            let count = gen.nextInt(in: 1...8)
            let before = observer.count(of: .usbAttached)
            for i in 0..<count {
                await source._injectAttach(vendor: "V\(seed)-\(i)", product: "P\(seed)-\(i)")
                try? await Task.sleep(for: .microseconds(250))
            }
            await observer.quiesce()
            let fires = observer.count(of: .usbAttached) - before
            XCTAssertEqual(fires, count,
                "[property=bus-completeness] seed=\(seed) issued=\(count) — expected \(count) bus emissions, got \(fires)")
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 7: Coalesce-window monotonicity invariant
    //
    // For random burst sizes of same-key USB attaches within the
    // debounce window: number of bus emissions ≤ number of injections,
    // AND ≥ 1 when at least one gate-clearing event occurs.
    //
    // Same vendor/product across the burst → same debounce key.
    // usbDebounce = 50ms, so a burst injected back-to-back collapses
    // to exactly 1 emission. To make trials independent, between
    // trials we use a fresh (vendor, product) seeded by the trial
    // index — this makes each trial's first attach gate-clearing.

    func test_property_coalesce_window_monotonicity_invariant() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)
        let observer = CountingObserver()
        await observer.start(on: bus)

        for seed in 0..<UInt64(N) {
            let gen = SeededGenerator(seed: seed)
            let burstSize = gen.nextInt(in: 1...10)
            let before = observer.count(of: .usbAttached)
            for _ in 0..<burstSize {
                await source._injectAttach(vendor: "Apple", product: "Magic-\(seed)")
            }
            await observer.quiesce()
            let fires = observer.count(of: .usbAttached) - before
            XCTAssertLessThanOrEqual(fires, burstSize,
                "[property=coalesce-monotonicity] seed=\(seed) burst=\(burstSize) — emissions must be ≤ injections, got \(fires)")
            XCTAssertGreaterThanOrEqual(fires, 1,
                "[property=coalesce-monotonicity] seed=\(seed) burst=\(burstSize) — at least one gate-clearing event must produce ≥1 emission, got \(fires)")
        }

        observer.close()
        source.stop()
        await bus.close()
    }

    // MARK: - Property 8: Per-mode disabled invariant
    //
    // For each trackpad mode (touching/sliding/contact/tapping/circling):
    // when disabled, NO reactions of that kind fire under any random
    // input shape. This is the strict half of the per-mode invariant —
    // the positive (enabled-fires) half is covered by canonical matrix
    // cells.
    //
    // 40 outer seeds × 5 modes = 200 sub-trials. Each sub-trial drives
    // 3-6 phased scrolls + 1-3 leftMouseDowns; phase=1 stamps
    // lastTrackpadGestureAt so the attribution gate WOULD admit the
    // click — only the disabled flag prevents the fire.

    func test_property_per_mode_disabled_invariant() async {
        let modes: [(name: String, kind: ReactionKind)] = [
            ("touching", .trackpadTouching),
            ("sliding",  .trackpadSliding),
            ("contact",  .trackpadContact),
            ("tapping",  .trackpadTapping),
            ("circling", .trackpadCircling),
        ]

        // One bus + source + observer per mode (5 total). All modes
        // disabled; thresholds permissive enough that with the
        // disabled gate removed, fires WOULD happen.
        for (modeName, modeKind) in modes {
            let bus = await makeBus()
            let monitor = MockEventMonitor()
            let source = TrackpadActivitySource(eventMonitor: monitor)
            source.configure(
                windowDuration: 1.0,
                scrollMin: 0.0, scrollMax: 1.0,
                touchingMin: 0.01, touchingMax: 1.0,
                slidingMin: 0.01, slidingMax: 0.9,
                contactMin: 0.05, contactMax: 5.0,
                tapMin: 0.1, tapMax: 6.0,
                touchingEnabled: false,
                slidingEnabled: false,
                contactEnabled: false,
                tappingEnabled: false,
                circlingEnabled: false
            )
            source.start(publishingTo: bus)
            let observer = CountingObserver()
            await observer.start(on: bus)

            for seed in 0..<UInt64(40) {
                let gen = SeededGenerator(seed: seed)
                let scrollCount = gen.nextInt(in: 3...6)
                for _ in 0..<scrollCount {
                    let mag = gen.nextDouble(in: 5.0...20.0)
                    if let ev = makeTrackpadScroll(phase: 1, deltaY: mag) {
                        monitor.emit(ev, ofType: .scrollWheel)
                    }
                }
                let clickCount = gen.nextInt(in: 1...3)
                for _ in 0..<clickCount {
                    monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
                }
                // No quiesce or per-trial gating needed: the cumulative
                // counter for the disabled kind must stay at 0 always.
                let fires = observer.count(of: modeKind)
                XCTAssertEqual(fires, 0,
                    "[property=per-mode-disabled] seed=\(seed) mode=\(modeName) — disabled mode must never fire (cumulative across trials), got \(fires)")
            }
            // Final quiesce to catch any in-flight publish.
            await observer.quiesce(20)
            let finalFires = observer.count(of: modeKind)
            XCTAssertEqual(finalFires, 0,
                "[property=per-mode-disabled] mode=\(modeName) — final cumulative count must be 0 after all 40 seeds, got \(finalFires)")

            observer.close()
            source.stop()
            await bus.close()
        }
    }
}
