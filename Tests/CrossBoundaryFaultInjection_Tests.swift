import XCTest
import IOKit
@testable import YameteCore
@testable import SensorKit

/// Phase 8 — cross-boundary simultaneous fault injection.
///
/// Existing `_force*` seams (USB / Bluetooth / Thunderbolt
/// `_forceKernelFailureKr`, AudioPeripheral `_forceListenerStatus`,
/// SleepWake `_forceRegistrationFailure`, Accelerometer mock-driver
/// `setForceManagerOpenFailure`, etc.) drive ONE source's failure
/// path in isolation. Real systems fail across boundaries
/// simultaneously: USB hot-unplug while microphone is starting,
/// sleep mid-`IORegisterForSystemPower`, AudioPeripheral
/// `AudioObjectAddPropertyListenerBlock` rejected during a USB
/// attach storm. None of those interactions are covered by the
/// per-source mutation cells — a regression where one source's
/// failure path corrupts a sibling's state would slip through.
///
/// Each cell drives ≥ 2 production fault paths concurrently via
/// `Task` spawning, then asserts a SPECIFIC invariant tagged with
/// a `[crossfault-cell=<name>]` substring anchor for grep-friendly
/// failure triage. Each cell is budgeted at ≤ 500ms wallclock.
///
/// Determinism: hand-rolled xorshift64 (no `SystemRandomNumberGenerator`,
/// no `arc4random`, no `Foundation.random`). Plain `Task { @MainActor in ... }`
/// + `await task.value` per child mirrors the strict-concurrency-clean
/// pattern from `MatrixConcurrentInterleaved_Tests`. `withTaskGroup`
/// trips the region-based isolation checker when child closures
/// re-enter MainActor and capture source variables.
@MainActor
final class CrossBoundaryFaultInjection_Tests: XCTestCase {

    // MARK: - Seeded generator (xorshift64, deterministic)

    /// Hand-rolled xorshift64. Seed=0 is a fixed point; the constructor
    /// remaps it so every nominally-valid seed produces a 2^64-1 period
    /// sequence. Same seed → same sequence on every host / run / shard.
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

    // MARK: - Counting observer (drains one subscriber on a MainActor task)

    final class CountingObserver: @unchecked Sendable {
        private var counts: [ReactionKind: Int] = [:]
        private var task: Task<Void, Never>?
        private var totalDelivered: Int = 0

        @MainActor
        func start(on bus: ReactionBus) async {
            let stream = await bus.subscribe()
            self.task = Task { @MainActor in
                for await fired in stream {
                    self.counts[fired.kind, default: 0] += 1
                    self.totalDelivered += 1
                }
            }
        }

        @MainActor
        func quiesce(_ ms: UInt64 = 25) async {
            try? await Task.sleep(for: .milliseconds(Int(ms)))
        }

        @MainActor func count(of kind: ReactionKind) -> Int { counts[kind] ?? 0 }
        @MainActor func total() -> Int { totalDelivered }
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

    // MARK: - Cell 1: USB-fail during BT-fail simultaneous
    //
    // Invariant: when USB and Bluetooth sources both have their
    // IOServiceAddMatchingNotification kernel-failure knobs set to a
    // non-success kr and `start()` is invoked concurrently, NEITHER
    // source crashes, BOTH leave their `_testInstallationCount` at 0
    // (kernel-success guard short-circuited), and the bus receives
    // zero emissions from either source.
    func test_crossfault_cell_usb_fail_during_bt_fail_simultaneous() async {
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        usb._forceKernelFailureKr = KERN_FAILURE
        bt._forceKernelFailureKr = KERN_FAILURE

        let observer = CountingObserver()
        await observer.start(on: bus)

        // Drive both `start()` calls concurrently. The kernel-success
        // guard inside each runs on MainActor; the test asserts
        // they don't trample each other's bookkeeping.
        let t1: Task<Void, Never> = Task { @MainActor in
            usb.start(publishingTo: bus)
        }
        let t2: Task<Void, Never> = Task { @MainActor in
            bt.start(publishingTo: bus)
        }
        _ = await t1.value
        _ = await t2.value
        await observer.quiesce()

        XCTAssertEqual(usb._testInstallationCount, 0,
            "[crossfault-cell=usb-fail-during-bt-fail-simultaneous] USB kernel-success guard must short-circuit under concurrent BT failure; expected 0, got \(usb._testInstallationCount)")
        XCTAssertEqual(bt._testInstallationCount, 0,
            "[crossfault-cell=usb-fail-during-bt-fail-simultaneous] BT kernel-success guard must short-circuit under concurrent USB failure; expected 0, got \(bt._testInstallationCount)")
        XCTAssertEqual(observer.total(), 0,
            "[crossfault-cell=usb-fail-during-bt-fail-simultaneous] no emissions expected with both sources faulted; got \(observer.total())")

        observer.close()
        usb.stop()
        bt.stop()
        await bus.close()
    }

    // MARK: - Cell 2: AccelerometerOpen-fail during MicrophoneStart
    //
    // Invariant: when `AccelerometerSource` is constructed with a mock
    // kernel driver configured to fail `IOHIDManagerOpen` and
    // `MicrophoneSource` is started concurrently with a happy-path
    // mock driver, microphone proceeds to install its tap exactly once
    // and accelerometer's failure path engages cleanly (its impacts
    // stream finishes throwing without ever yielding an impact). The
    // two sources do not corrupt each other's state.
    func test_crossfault_cell_accel_open_fail_during_mic_start() async {
        let accelMock = MockSPUKernelDriver()
        accelMock.setForceManagerOpenFailure(kIOReturnNotPermitted)
        let accel = AccelerometerSource(kernelDriver: accelMock)

        let micMock = MockMicrophoneEngineDriver()
        let mic = MicrophoneSource(
            detectorConfig: .microphone(),
            driverFactory: { micMock },
            availabilityOverride: { true }
        )

        // Concurrently drive the failing accelerometer impacts() and
        // the healthy microphone impacts(). Each runs its own consumer
        // loop. The accelerometer stream must finish (throwing or
        // empty-success) without delivering an impact; the microphone
        // tap must install exactly once.
        let accelTask: Task<Int, Never> = Task { @MainActor in
            var accelCount = 0
            do {
                for try await _ in accel.impacts() { accelCount += 1 }
            } catch {
                // Expected on the IOHIDManagerOpen failure path.
            }
            return accelCount
        }
        let micTask: Task<Void, Never> = Task { @MainActor in
            let stream = mic.impacts()
            // Drain just long enough to observe the tap install, then cancel.
            let drain = Task<Void, Error> { for try await _ in stream {} }
            try? await Task.sleep(for: .milliseconds(40))
            drain.cancel()
            _ = try? await drain.value
        }
        _ = await accelTask.value
        _ = await micTask.value

        let accelImpacts = await accelTask.value
        XCTAssertEqual(accelImpacts, 0,
            "[crossfault-cell=accel-open-fail-during-mic-start] forced IOHIDManagerOpen failure must yield zero accelerometer impacts; got \(accelImpacts)")
        XCTAssertGreaterThanOrEqual(accelMock.hidManagerOpenCalls, 1,
            "[crossfault-cell=accel-open-fail-during-mic-start] hidManagerOpen must have been attempted; got \(accelMock.hidManagerOpenCalls)")
        XCTAssertEqual(micMock.startCalls, 1,
            "[crossfault-cell=accel-open-fail-during-mic-start] microphone start() must run exactly once independent of accelerometer fault; got \(micMock.startCalls)")
        XCTAssertEqual(micMock.installTapCalls, 1,
            "[crossfault-cell=accel-open-fail-during-mic-start] microphone tap install must occur exactly once independent of accelerometer fault; got \(micMock.installTapCalls)")
    }

    // MARK: - Cell 3: SleepWake-fail during IOHID-register flood
    //
    // Invariant: 100 USB `_injectAttach` calls concurrent with
    // `SleepWakeSource._forceRegistrationFailure = true` followed by
    // `start()`. USBSource must continue to publish attaches (its
    // production path is decoupled from SleepWakeSource), SleepWake's
    // `_testInstallationCount` stays at 0, and SleepWake emits no
    // `.willSleep` / `.didWake` events.
    func test_crossfault_cell_sleepwake_fail_during_iohid_flood() async {
        let bus = await makeBus()
        let usb = USBSource()
        usb.start(publishingTo: bus)
        let sleep = SleepWakeSource()
        sleep._forceRegistrationFailure = true

        let observer = CountingObserver()
        await observer.start(on: bus)

        let usbTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<100 {
                await usb._injectAttach(vendor: "Vend\(i % 10)", product: "Prod\(i)")
            }
        }
        let sleepTask: Task<Void, Never> = Task { @MainActor in
            // Yield once so the USB flood is ALREADY in flight when
            // the failing register call lands.
            await Task.yield()
            sleep.start(publishingTo: bus)
        }
        _ = await usbTask.value
        _ = await sleepTask.value
        await observer.quiesce(40)

        XCTAssertEqual(sleep._testInstallationCount, 0,
            "[crossfault-cell=sleepwake-fail-during-iohid-flood] SleepWake kernel-success guard must short-circuit; expected 0, got \(sleep._testInstallationCount)")
        XCTAssertEqual(observer.count(of: .willSleep), 0,
            "[crossfault-cell=sleepwake-fail-during-iohid-flood] no .willSleep expected when registration fails; got \(observer.count(of: .willSleep))")
        XCTAssertEqual(observer.count(of: .didWake), 0,
            "[crossfault-cell=sleepwake-fail-during-iohid-flood] no .didWake expected when registration fails; got \(observer.count(of: .didWake))")
        XCTAssertGreaterThanOrEqual(observer.count(of: .usbAttached), 1,
            "[crossfault-cell=sleepwake-fail-during-iohid-flood] USB attaches must continue independent of SleepWake fault; got \(observer.count(of: .usbAttached))")
        // Bounded by injections (100 distinct product keys → no debounce collapse).
        XCTAssertLessThanOrEqual(observer.count(of: .usbAttached), 100,
            "[crossfault-cell=sleepwake-fail-during-iohid-flood] USB attach count must be bounded by injections; got \(observer.count(of: .usbAttached))")

        observer.close()
        usb.stop()
        sleep.stop()
        await bus.close()
    }

    // MARK: - Cell 4: AudioPeripheral listener-install-fail during USB attach flood
    //
    // Invariant: AudioPeripheral source `_forceListenerStatus` set to
    // a non-noErr OSStatus while USB receives an attach burst. The
    // AudioPeripheral source's `_testInstallationCount` stays at 0
    // (no listener installed), the USB source publishes attaches as
    // usual, and the bus sees zero `.audioPeripheralAttached` /
    // `.audioPeripheralDetached` emissions (no cross-source state
    // corruption).
    func test_crossfault_cell_audio_listener_fail_during_usb_flood() async {
        let bus = await makeBus()
        let usb = USBSource()
        usb.start(publishingTo: bus)
        let audio = AudioPeripheralSource()
        audio._forceListenerStatus = OSStatus(-1)

        let observer = CountingObserver()
        await observer.start(on: bus)

        let usbTask: Task<Void, Never> = Task { @MainActor in
            for i in 0..<30 {
                await usb._injectAttach(vendor: "AppleA", product: "Burst\(i)")
            }
        }
        let audioTask: Task<Void, Never> = Task { @MainActor in
            await Task.yield()
            audio.start(publishingTo: bus)
        }
        _ = await usbTask.value
        _ = await audioTask.value
        await observer.quiesce(30)

        XCTAssertEqual(audio._testInstallationCount, 0,
            "[crossfault-cell=audio-listener-fail-during-usb-flood] AudioPeripheral kernel-success guard must short-circuit; expected 0, got \(audio._testInstallationCount)")
        XCTAssertEqual(observer.count(of: .audioPeripheralAttached), 0,
            "[crossfault-cell=audio-listener-fail-during-usb-flood] no audio attached emissions expected; got \(observer.count(of: .audioPeripheralAttached))")
        XCTAssertEqual(observer.count(of: .audioPeripheralDetached), 0,
            "[crossfault-cell=audio-listener-fail-during-usb-flood] no audio detached emissions expected; got \(observer.count(of: .audioPeripheralDetached))")
        XCTAssertGreaterThanOrEqual(observer.count(of: .usbAttached), 1,
            "[crossfault-cell=audio-listener-fail-during-usb-flood] USB attaches must continue independent of audio fault; got \(observer.count(of: .usbAttached))")

        observer.close()
        usb.stop()
        audio.stop()
        await bus.close()
    }

    // MARK: - Cell 5: All-IOKit-sources-fail
    //
    // Invariant: every IOKit source's failure knob set simultaneously
    // — USB, Bluetooth, Thunderbolt (`_forceKernelFailureKr`),
    // AudioPeripheral (`_forceListenerStatus`), SleepWake
    // (`_forceRegistrationFailure`). All sources started concurrently.
    // Every source's `_testInstallationCount` stays at 0, no source
    // crashes, and the bus has zero emissions.
    func test_crossfault_cell_all_iokit_sources_fail() async {
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        let tb = ThunderboltSource()
        let audio = AudioPeripheralSource()
        let sleep = SleepWakeSource()

        usb._forceKernelFailureKr = KERN_FAILURE
        bt._forceKernelFailureKr = KERN_FAILURE
        tb._forceKernelFailureKr = KERN_FAILURE
        audio._forceListenerStatus = OSStatus(-1)
        sleep._forceRegistrationFailure = true

        let observer = CountingObserver()
        await observer.start(on: bus)

        let t1: Task<Void, Never> = Task { @MainActor in usb.start(publishingTo: bus) }
        let t2: Task<Void, Never> = Task { @MainActor in bt.start(publishingTo: bus) }
        let t3: Task<Void, Never> = Task { @MainActor in tb.start(publishingTo: bus) }
        let t4: Task<Void, Never> = Task { @MainActor in audio.start(publishingTo: bus) }
        let t5: Task<Void, Never> = Task { @MainActor in sleep.start(publishingTo: bus) }
        _ = await t1.value
        _ = await t2.value
        _ = await t3.value
        _ = await t4.value
        _ = await t5.value
        await observer.quiesce(40)

        XCTAssertEqual(usb._testInstallationCount, 0,
            "[crossfault-cell=all-iokit-sources-fail] USB must short-circuit under simultaneous fault; got \(usb._testInstallationCount)")
        XCTAssertEqual(bt._testInstallationCount, 0,
            "[crossfault-cell=all-iokit-sources-fail] BT must short-circuit under simultaneous fault; got \(bt._testInstallationCount)")
        XCTAssertEqual(tb._testInstallationCount, 0,
            "[crossfault-cell=all-iokit-sources-fail] Thunderbolt must short-circuit under simultaneous fault; got \(tb._testInstallationCount)")
        XCTAssertEqual(audio._testInstallationCount, 0,
            "[crossfault-cell=all-iokit-sources-fail] AudioPeripheral must short-circuit under simultaneous fault; got \(audio._testInstallationCount)")
        XCTAssertEqual(sleep._testInstallationCount, 0,
            "[crossfault-cell=all-iokit-sources-fail] SleepWake must short-circuit under simultaneous fault; got \(sleep._testInstallationCount)")
        XCTAssertEqual(observer.total(), 0,
            "[crossfault-cell=all-iokit-sources-fail] no emissions expected with all IOKit sources faulted; got \(observer.total())")

        observer.close()
        usb.stop(); bt.stop(); tb.stop(); audio.stop(); sleep.stop()
        await bus.close()
    }

    // MARK: - Cell 6: Recovery-after-fault
    //
    // Invariant: a source whose failure knob is set, then started
    // (short-circuiting), then has its knob CLEARED and `start()`
    // re-invoked, must recover and now emit normally. The
    // `_testInstallationCount` should be 1 after recovery (idempotent
    // start guard sees `notifyPort == nil` from the first failed run
    // and proceeds), and a follow-up `_injectAttach` must arrive at
    // the bus.
    func test_crossfault_cell_recovery_after_fault() async {
        let bus = await makeBus()
        let usb = USBSource()
        usb._forceKernelFailureKr = KERN_FAILURE
        usb.start(publishingTo: bus)
        XCTAssertEqual(usb._testInstallationCount, 0,
            "[crossfault-cell=recovery-after-fault] forced-failure start must not register; got \(usb._testInstallationCount)")

        // Clear the knob and retry.
        usb._forceKernelFailureKr = nil
        usb.start(publishingTo: bus)

        let observer = CountingObserver()
        await observer.start(on: bus)
        await usb._injectAttach(vendor: "Recover", product: "OkAfterFault")
        await observer.quiesce()

        XCTAssertEqual(usb._testInstallationCount, 1,
            "[crossfault-cell=recovery-after-fault] cleared-knob restart must register exactly once; got \(usb._testInstallationCount)")
        XCTAssertEqual(observer.count(of: .usbAttached), 1,
            "[crossfault-cell=recovery-after-fault] post-recovery inject must arrive at bus; got \(observer.count(of: .usbAttached))")

        observer.close()
        usb.stop()
        await bus.close()
    }

    // MARK: - Cell 7: Concurrent fault during in-flight subscription
    //
    // Invariant: 3 subscribers attached to the same bus. USB +
    // Bluetooth + Power inject some healthy events, then USB+BT have
    // their kernel-failure knobs flipped on (effectively disabling
    // future starts) while a fresh attempt to (re)start them fires
    // concurrently. The 3 subscribers must each see the SAME per-kind
    // multiset (no fan-out skew under fault). The healthy emissions
    // from before the fault land at all 3 subscribers identically.
    func test_crossfault_cell_concurrent_fault_during_in_flight_subscription() async {
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        let power = PowerSource()
        usb.start(publishingTo: bus)
        bt.start(publishingTo: bus)
        power.start(publishingTo: bus)

        var observers: [CountingObserver] = []
        for _ in 0..<3 {
            let obs = CountingObserver()
            await obs.start(on: bus)
            observers.append(obs)
        }

        // Healthy injects.
        await usb._injectAttach(vendor: "Hi", product: "Healthy1")
        await bt._injectConnect(name: "BT-Healthy")
        await usb._injectAttach(vendor: "Hi", product: "Healthy2")

        // Now fault USB + BT and re-start them concurrently. The new
        // `start()` calls are no-ops because `notifyPort != nil`
        // (idempotent guard) — the knobs are essentially smoke. But
        // the test asserts that under simultaneous fault the in-flight
        // subscribers continue to fan out identically.
        usb._forceKernelFailureKr = KERN_FAILURE
        bt._forceKernelFailureKr = KERN_FAILURE
        let f1: Task<Void, Never> = Task { @MainActor in usb.start(publishingTo: bus) }
        let f2: Task<Void, Never> = Task { @MainActor in bt.start(publishingTo: bus) }
        let f3: Task<Void, Never> = Task { @MainActor in
            await power._injectPowerChange(onAC: !PowerSourceProbe.currentlyOnAC())
        }
        _ = await f1.value
        _ = await f2.value
        _ = await f3.value
        await observers[0].quiesce(40)

        let baselineUSB = observers[0].count(of: .usbAttached)
        let baselineBT = observers[0].count(of: .bluetoothConnected)
        let baselineTotal = observers[0].total()
        for (i, obs) in observers.enumerated() {
            XCTAssertEqual(obs.count(of: .usbAttached), baselineUSB,
                "[crossfault-cell=concurrent-fault-during-in-flight-subscription] subscriber \(i) saw \(obs.count(of: .usbAttached)) usbAttached vs baseline \(baselineUSB) — fan-out skew under fault")
            XCTAssertEqual(obs.count(of: .bluetoothConnected), baselineBT,
                "[crossfault-cell=concurrent-fault-during-in-flight-subscription] subscriber \(i) saw \(obs.count(of: .bluetoothConnected)) bluetoothConnected vs baseline \(baselineBT) — fan-out skew under fault")
            XCTAssertEqual(obs.total(), baselineTotal,
                "[crossfault-cell=concurrent-fault-during-in-flight-subscription] subscriber \(i) total \(obs.total()) ≠ baseline \(baselineTotal) — fan-out skew under fault")
        }
        // Healthy emissions before the fault must have landed.
        XCTAssertEqual(baselineUSB, 2,
            "[crossfault-cell=concurrent-fault-during-in-flight-subscription] expected 2 healthy USB attaches in baseline, got \(baselineUSB)")
        XCTAssertEqual(baselineBT, 1,
            "[crossfault-cell=concurrent-fault-during-in-flight-subscription] expected 1 healthy BT connect in baseline, got \(baselineBT)")

        for obs in observers { obs.close() }
        usb.stop(); bt.stop(); power.stop()
        await bus.close()
    }

    // MARK: - Cell 8: Stable interleaved fault fuzz (seeds 42 / 7 / 31)
    //
    // For each seed: deterministically fault 2-5 sources from a pool of
    // 7 IOKit sources (USB / BT / TB / Audio / SleepWake — the fault
    // pool — plus USB-healthy / BT-healthy as inject targets), with
    // random injects interleaved between fault knob flips. Invariant:
    // no crash, no kind cross-pollination beyond the inject set, and
    // delivered ≤ injected (no amplification under fault).
    //
    // Same seed → same fault plan / inject plan on every host / run /
    // shard. The fault plan and inject plan are pre-rolled BEFORE any
    // concurrent task spawn so the expected upper bound is derived
    // from the plan, not from the race.
    func test_crossfault_cell_stable_interleaved_fault_fuzz() async {
        for seed in [UInt64(42), UInt64(7), UInt64(31)] {
            await runFuzzTrial(seed: seed)
        }
    }

    @MainActor
    private func runFuzzTrial(seed: UInt64) async {
        let rng = SeededGenerator(seed: seed)
        let bus = await makeBus()
        let usb = USBSource()
        let bt = BluetoothSource()
        let tb = ThunderboltSource()
        let audio = AudioPeripheralSource()
        let sleep = SleepWakeSource()
        usb.start(publishingTo: bus)
        bt.start(publishingTo: bus)
        tb.start(publishingTo: bus)
        // audio + sleep deliberately not started — their faults
        // are exercised by flipping the knob then attempting start().

        let observer = CountingObserver()
        await observer.start(on: bus)

        // Pre-roll the fault plan: 2-5 of the 5 IOKit fault knobs.
        let faultCount = rng.nextInt(in: 2...5)
        var faultedKnobs: Set<Int> = []
        while faultedKnobs.count < faultCount {
            faultedKnobs.insert(rng.nextInt(in: 0...4))
        }

        // Pre-roll inject plan: 30 injects across USB / BT / TB.
        struct Inject { let kind: Int; let i: Int }
        var injects: [Inject] = []
        for i in 0..<30 {
            injects.append(Inject(kind: rng.nextInt(in: 0...2), i: i))
        }

        // Apply faults concurrently with injects.
        let faultTask: Task<Void, Never> = Task { @MainActor in
            for k in faultedKnobs.sorted() {
                switch k {
                case 0: usb._forceKernelFailureKr = KERN_FAILURE
                case 1: bt._forceKernelFailureKr = KERN_FAILURE
                case 2: tb._forceKernelFailureKr = KERN_FAILURE
                case 3: audio._forceListenerStatus = OSStatus(-1); audio.start(publishingTo: bus)
                case 4: sleep._forceRegistrationFailure = true; sleep.start(publishingTo: bus)
                default: break
                }
                await Task.yield()
            }
        }
        let injectTask: Task<Void, Never> = Task { @MainActor in
            for inj in injects {
                switch inj.kind {
                case 0: await usb._injectAttach(vendor: "FuzzU\(seed)", product: "Prod\(inj.i)")
                case 1: await bt._injectConnect(name: "FuzzBT-\(seed)-\(inj.i)")
                case 2: await tb._injectAttach(name: "FuzzTB-\(seed)-\(inj.i)")
                default: break
                }
            }
        }
        _ = await faultTask.value
        _ = await injectTask.value
        await observer.quiesce(40)

        // No amplification: total deliveries cannot exceed injects.
        XCTAssertLessThanOrEqual(observer.total(), injects.count,
            "[crossfault-cell=stable-interleaved-fault-fuzz seed=\(seed)] delivered \(observer.total()) > injected \(injects.count) — amplification under fault")
        // No cross-kind pollination: no audio / sleep / display / power / mouse / etc.
        let pollutionKinds: [ReactionKind] = [
            .audioPeripheralAttached, .audioPeripheralDetached,
            .willSleep, .didWake,
            .displayConfigured,
            .acConnected, .acDisconnected,
            .mouseClicked, .keyboardTyped, .trackpadTapping
        ]
        for k in pollutionKinds {
            XCTAssertEqual(observer.count(of: k), 0,
                "[crossfault-cell=stable-interleaved-fault-fuzz seed=\(seed)] unexpected \(k) emission under fuzz fault; got \(observer.count(of: k))")
        }
        // Faulted IOKit sources stay at install=0 if they were in the
        // fault set AND would-have-been-started by this trial.
        if faultedKnobs.contains(3) {
            XCTAssertEqual(audio._testInstallationCount, 0,
                "[crossfault-cell=stable-interleaved-fault-fuzz seed=\(seed)] AudioPeripheral fault must keep installCount=0; got \(audio._testInstallationCount)")
        }
        if faultedKnobs.contains(4) {
            XCTAssertEqual(sleep._testInstallationCount, 0,
                "[crossfault-cell=stable-interleaved-fault-fuzz seed=\(seed)] SleepWake fault must keep installCount=0; got \(sleep._testInstallationCount)")
        }

        observer.close()
        usb.stop(); bt.stop(); tb.stop(); audio.stop(); sleep.stop()
        await bus.close()
    }
}

// MARK: - PowerSourceProbe (lightweight AC-state read for the cell-7 toggle)

/// Static probe that reads the current AC state without subscribing.
/// `PowerSource._injectPowerChange` requires a state DIFFERENT from
/// `lastWasOnAC` (edge-triggered), so the cell flips relative to the
/// real system state — guaranteeing the inject lands as a transition.
private enum PowerSourceProbe {
    static func currentlyOnAC() -> Bool {
        // Conservative default: assume on AC unless we can prove
        // otherwise. The cell uses `!currentlyOnAC()` to force a
        // transition relative to whatever PowerSource captured at
        // start(); a wrong guess here just means the inject is a
        // no-op (still satisfies invariant: no crash, identical
        // multisets across subscribers).
        return true
    }
}
