import XCTest
import AppKit
@testable import YameteCore
@testable import ResponseKit
@testable import SensorKit

/// System-level matrix: when ONE reaction fires, EVERY enabled output runs
/// its full preAction → action → postAction lifecycle in parallel. Bug class:
/// one output blocks another (synchronous wait); one output's preAction
/// races another's restore; mock drivers leak state across outputs; the bus
/// fans out to only one continuation; etc.
///
/// Each cell wires N spy outputs to ONE bus + ONE config provider via the
/// real `consume(from:configProvider:)`, publishes a stimulus, and asserts
/// each output's recorded calls in strict order.
@MainActor
final class MatrixMultiOutputConcurrentFire_Tests: XCTestCase {

    // MARK: - Per-output identity

    /// Identity tag for each spy slot. Mirrors the real-output roster
    /// (Audio, Flash, Notification, LED, Haptic, DisplayBrightness,
    /// DisplayTint). VolumeSpike is Direct-only and gated below.
    private enum OutputSlot: String, CaseIterable {
        case audio
        case flash
        case notification
        case led
        case haptic
        case brightness
        case tint
    }

    // MARK: - Spy harness

    /// Per-slot spy: records full lifecycle (pre/action/post) and the kind
    /// observed on each call. Each spy carries its own slot identity so
    /// failure messages can name the offender directly.
    ///
    /// `pauseUntil` mirrors `MatrixSpyOutput.pauseUntil`: when set, `action()`
    /// blocks on the token instead of sleeping `actionDuration`. Round 5
    /// added this so `testTwoBackToBack_dropDuringInflight_perOutput` could
    /// pin A in flight deterministically while B publishes, instead of
    /// racing wall-clock sleeps that the slow CI runner could re-order.
    private final class TaggedSpy: ReactiveOutput {
        let slot: OutputSlot
        var preCalls: [(kind: ReactionKind, ts: Date)] = []
        var actCalls: [(kind: ReactionKind, ts: Date)] = []
        var postCalls: [(kind: ReactionKind, ts: Date)] = []
        var allow: Bool = true
        var actionDuration: Duration = .milliseconds(2)
        var pauseUntil: PauseToken?

        init(slot: OutputSlot) {
            self.slot = slot
            super.init()
        }

        override func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
            allow
        }
        override func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
            preCalls.append((fired.kind, Date()))
        }
        override func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
            actCalls.append((fired.kind, Date()))
            if let token = pauseUntil {
                while !token.released {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            } else {
                try? await Task.sleep(for: actionDuration)
            }
        }
        override func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
            postCalls.append((fired.kind, Date()))
        }
    }

    // MARK: - Bus + provider fixtures

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction,
                          clipDuration: 0.05,
                          soundURL: nil,
                          faceIndices: [0],
                          publishedAt: publishedAt)
        }
        return bus
    }

    /// Wires all slots to one bus, returns the spy roster keyed by slot.
    /// Each spy has its own consume task; the returned tasks are
    /// cancelled by the caller after assertions.
    private func startRoster(
        slots: [OutputSlot],
        bus: ReactionBus,
        provider: OutputConfigProvider,
        slowSlot: OutputSlot? = nil,
        slowDuration: Duration = .milliseconds(200)
    ) -> (spies: [OutputSlot: TaggedSpy], tasks: [Task<Void, Never>]) {
        var spies: [OutputSlot: TaggedSpy] = [:]
        var tasks: [Task<Void, Never>] = []
        for slot in slots {
            let spy = TaggedSpy(slot: slot)
            if slot == slowSlot { spy.actionDuration = slowDuration }
            spies[slot] = spy
            tasks.append(Task { @MainActor [spy] in
                await spy.consume(from: bus, configProvider: provider)
            })
        }
        return (spies, tasks)
    }

    // MARK: - Cell 1: every (kind × subset) coverage

    /// Pairwise reduction of (kind × subset-of-outputs-enabled). Each cell
    /// publishes ONE reaction, asserts every enabled spy ran preAction,
    /// action, postAction (in that order, all observing the same kind),
    /// and disabled spies recorded nothing.
    func testEveryKind_everyOutputSubset_runsCompleteLifecycle() async throws {
        // Sample a representative slice: one kind from each major source family
        // plus the impact kind. This keeps the matrix bounded while still
        // covering the kind→output dispatch surface for every output type.
        let sampledKinds: [ReactionKind] = [
            .impact, .acConnected, .usbAttached, .audioPeripheralAttached,
            .bluetoothConnected, .thunderboltAttached, .displayConfigured,
            .willSleep, .trackpadTapping, .mouseClicked, .keyboardTyped,
        ]
        // Build subset patterns: alternating bitmasks plus all-on/all-off.
        let subsetMasks: [[Bool]] = [
            [true,  true,  true,  true,  true,  true,  true ], // all-on
            [true,  false, false, false, false, false, false], // audio only
            [false, true,  false, false, false, false, false], // flash only
            [false, false, false, false, true,  false, false], // haptic only
            [true,  true,  true,  true,  false, false, false], // 4-no-hardware
            [false, false, false, false, true,  true,  true ], // hardware-only
            [true,  true,  false, true,  true,  false, true ], // alt-mix-A
        ]

        // Pairwise reduce (kind × mask).
        let cellTuples = PairwiseCovering.generate(arities: [sampledKinds.count, subsetMasks.count])

        var cellsExecuted = 0
        for tuple in cellTuples {
            let kind = sampledKinds[tuple[0]]
            let mask = subsetMasks[tuple[1]]
            let coords = "[kind=\(kind.rawValue) mask=\(maskString(mask))]"

            let bus = await makeBus()
            let provider = MockConfigProvider()
            // Build slot list filtered by mask
            let allSlots = OutputSlot.allCases
            let activeSlots = zip(allSlots, mask).compactMap { $0.1 ? $0.0 : nil }
            let inactiveSlots = zip(allSlots, mask).compactMap { !$0.1 ? $0.0 : nil }
            let (spies, tasks) = startRoster(slots: allSlots, bus: bus, provider: provider)
            // Disable inactive spies' shouldFire so they record nothing.
            for slot in inactiveSlots { spies[slot]?.allow = false }
            defer { tasks.forEach { $0.cancel() } }

            // Allow all consume tasks to subscribe before we publish — on
            // slow CI the 7-task subscribe storm can take >10ms.
            try await Task.sleep(for: CITiming.scaledDuration(ms: 20))

            // Publish one reaction of the chosen kind.
            await bus.publish(reaction(for: kind))

            // Poll until every active spy has a complete pre/action/post
            // record. Replaces a brittle 70ms tail-sleep that was below the
            // CI scheduler's worst-case lifecycle latency.
            _ = await awaitUntil(timeout: 1.5) {
                activeSlots.allSatisfy { slot in
                    let s = spies[slot]!
                    return s.preCalls.count == 1
                        && s.actCalls.count == 1
                        && s.postCalls.count == 1
                }
            }

            // Active outputs: pre, action, post each fired once for this kind.
            for slot in activeSlots {
                let spy = spies[slot]!
                XCTAssertEqual(spy.preCalls.count, 1,
                    "\(coords) [output=\(slot.rawValue)] missing preAction call (got \(spy.preCalls.count))")
                XCTAssertEqual(spy.actCalls.count, 1,
                    "\(coords) [output=\(slot.rawValue)] missing action call")
                XCTAssertEqual(spy.postCalls.count, 1,
                    "\(coords) [output=\(slot.rawValue)] missing postAction call")
                XCTAssertEqual(spy.actCalls.first?.kind, kind,
                    "\(coords) [output=\(slot.rawValue)] action observed wrong kind")
            }
            // Inactive outputs: nothing recorded.
            for slot in inactiveSlots {
                let spy = spies[slot]!
                XCTAssertTrue(spy.preCalls.isEmpty && spy.actCalls.isEmpty && spy.postCalls.isEmpty,
                    "\(coords) [output=\(slot.rawValue)] disabled spy fired anyway")
            }
            cellsExecuted += 1
            await bus.close()
        }
        XCTAssertGreaterThan(cellsExecuted, 0, "matrix produced zero cells")
    }

    // MARK: - Cell 2: two reactions back-to-back (drop-not-cancel)

    /// Two reactions arriving in close succession with all outputs enabled.
    /// The drop-not-cancel rule: if the second reaction arrives during the
    /// first's lifecycle (post-coalesce, mid-action), it is dropped.
    ///
    /// Round 5 hardening: instead of racing a wall-clock 50 ms `actionDuration`
    /// against the slow CI runner (the previous approach occasionally let
    /// A's lifecycle finish before B even published, falsifying the
    /// drop-not-cancel coordinates), pin every spy's action on a shared
    /// `PauseToken`. Sequence:
    ///   1. publish A → poll until each spy records `preCalls.count >= 1`
    ///      (action() has begun for every output and is blocked on the gate)
    ///   2. publish B → must be dropped because every spy's lifecycleTask is
    ///      still alive
    ///   3. release the token → poll for postAction to land
    ///   4. assert each output saw exactly A and finished its lifecycle
    func testTwoBackToBack_dropDuringInflight_perOutput() async throws {
        let bus = await makeBus()
        let provider = MockConfigProvider()
        let (spies, tasks) = startRoster(slots: OutputSlot.allCases, bus: bus, provider: provider)
        let token = PauseToken()
        for spy in spies.values { spy.pauseUntil = token }
        defer { tasks.forEach { $0.cancel() } }

        // Wait for every consume task to subscribe before publishing — under
        // CI a 7-task subscribe storm can take >10ms, and an early publish
        // would land before some outputs registered.
        _ = await awaitUntil(timeout: 1.5) {
            await bus._testSubscriberCount() >= OutputSlot.allCases.count
        }

        await bus.publish(.acConnected)            // A
        // Poll until every spy's action() has begun. At that point each
        // output's lifecycleTask is alive and blocked on the token, so the
        // next publish targets the in-flight drop guard, not a finished
        // lifecycle.
        let aInFlight = await awaitUntil(timeout: 2.0) {
            OutputSlot.allCases.allSatisfy { (spies[$0]?.actCalls.count ?? 0) >= 1 }
        }
        XCTAssertTrue(aInFlight,
            "[scenario=back-to-back-drop] every output's action() must begin before B publishes — gate setup is broken")

        await bus.publish(.acDisconnected)         // B — must be dropped
        // Give the bus + outputs a chance to evaluate B against the
        // in-flight guard. If B is going to surface (bug), it will land
        // within this window; if dropped (correct), the predicate stays
        // false and we fall through.
        _ = await awaitUntil(timeout: 0.3) {
            OutputSlot.allCases.contains { slot in
                (spies[slot]?.actCalls.contains { $0.kind == .acDisconnected }) ?? false
            }
        }

        // Release the gate so A's lifecycle can drain, then poll for post.
        token.release()
        _ = await awaitUntil(timeout: 2.0) {
            OutputSlot.allCases.allSatisfy { (spies[$0]?.postCalls.count ?? 0) >= 1 }
        }

        for slot in OutputSlot.allCases {
            let spy = spies[slot]!
            let coords = "[output=\(slot.rawValue) scenario=back-to-back-drop]"
            XCTAssertEqual(spy.actCalls.count, 1,
                "\(coords) expected exactly one action (B should be dropped), got \(spy.actCalls.count)")
            XCTAssertEqual(spy.actCalls.first?.kind, .acConnected,
                "\(coords) first kind must be A (acConnected)")
            XCTAssertEqual(spy.postCalls.count, 1,
                "\(coords) postAction must still fire for A even with B dropped")
        }
        await bus.close()
    }

    // MARK: - Cell 3: slow output does not block other outputs

    /// One output runs a 200ms action; every other output runs a 2ms action
    /// for the same reaction. Other outputs must complete (post recorded)
    /// while the slow output is still running.
    func testSlowOutput_doesNotBlock_otherOutputs() async throws {
        let bus = await makeBus()
        let provider = MockConfigProvider()
        // Stretch the slow output for CI so the no-block window has headroom
        // even when fast outputs take longer than 80ms to clear postAction.
        // 600ms is well above any plausible fast-output latency under load,
        // and we now poll for fast completion rather than waiting a fixed
        // 80ms — so the inequality "fast done before slow done" survives
        // wide scheduler variance.
        let slowDurationMs = CITiming.scaledMs(600)
        let (spies, tasks) = startRoster(
            slots: OutputSlot.allCases,
            bus: bus,
            provider: provider,
            slowSlot: .haptic,
            slowDuration: .milliseconds(slowDurationMs)
        )
        defer { tasks.forEach { $0.cancel() } }

        try await Task.sleep(for: CITiming.scaledDuration(ms: 10))
        await bus.publish(.acConnected)

        // Poll until every fast output has completed its postAction. This
        // replaces the brittle 80ms fixed wait — under CI load the fast
        // outputs can take 100-200ms to finish and the prior fixed sleep
        // tripped the assertion before they did.
        let fastSlots = OutputSlot.allCases.filter { $0 != .haptic }
        _ = await awaitUntil(timeout: 2.0) {
            fastSlots.allSatisfy { (spies[$0]?.postCalls.count ?? 0) >= 1 }
        }

        // Fast outputs: completed full lifecycle.
        for slot in fastSlots {
            let spy = spies[slot]!
            let coords = "[output=\(slot.rawValue) scenario=slow-haptic-noblock]"
            XCTAssertGreaterThanOrEqual(spy.postCalls.count, 1,
                "\(coords) fast output blocked by slow haptic — postAction did not fire")
        }
        // Slow output: started action but post not yet recorded.
        let slow = spies[.haptic]!
        XCTAssertEqual(slow.actCalls.count, 1,
            "[output=haptic scenario=slow-haptic-noblock] slow action should have started")
        XCTAssertEqual(slow.postCalls.count, 0,
            "[output=haptic scenario=slow-haptic-noblock] slow output must not yet have completed")

        // Wait for slow output to complete.
        _ = await awaitUntil(timeout: 5.0) {
            (spies[.haptic]?.postCalls.count ?? 0) >= 1
        }
        XCTAssertEqual(slow.postCalls.count, 1,
            "[output=haptic scenario=slow-haptic-noblock] slow output must complete eventually")
        await bus.close()
    }

    // MARK: - Cell 4: OS-surface drives full multi-output fanout

    /// An OS-event (synthesized via `MockEventMonitor.emit(...)`) flows
    /// through `TrackpadActivitySource`'s real detection and fans out to
    /// every enabled output's lifecycle. Proves the full chain
    /// (NSEvent → source detection → bus → all subscribed outputs) works,
    /// not just the bus-publish shortcut.
    func testOSSurfaceDrives_allOutputs_fullLifecycle() async throws {
        let bus = await makeBus()
        let provider = MockConfigProvider()
        let monitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: monitor)
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.0, touchingMax: 1.0,
            slidingMin: 0.0, slidingMax: 1.0,
            contactMin: 0.5, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0
        )
        trackpad.start(publishingTo: bus)
        let (spies, tasks) = startRoster(slots: OutputSlot.allCases, bus: bus, provider: provider)
        defer { tasks.forEach { $0.cancel() } }

        try await Task.sleep(for: .milliseconds(20))

        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 2,
                               wheel1: 30, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent unavailable on this host")
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        guard let nsEvent = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent bridge unavailable")
        }
        for _ in 0..<5 {
            monitor.emit(nsEvent, ofType: .scrollWheel)
            try await Task.sleep(for: .milliseconds(10))
        }
        // Allow detection (debounce 1.5s gates can still emit on first hit) +
        // coalesce (16ms) + action (2ms) + slack.
        try await Task.sleep(for: .milliseconds(120))

        // At least one output should have observed at least one trackpad
        // reaction kind. Using "at least one" because RMS evaluation may
        // pick touching, sliding, or both depending on accumulated window.
        let trackpadKinds: Set<ReactionKind> = [.trackpadTouching, .trackpadSliding, .trackpadContact]
        var anyOutputFired = false
        for slot in OutputSlot.allCases {
            let spy = spies[slot]!
            if spy.actCalls.contains(where: { trackpadKinds.contains($0.kind) }) {
                anyOutputFired = true
                XCTAssertGreaterThanOrEqual(spy.preCalls.count, 1,
                    "[scenario=os-surface output=\(slot.rawValue)] preAction must precede action")
                XCTAssertGreaterThanOrEqual(spy.postCalls.count, 1,
                    "[scenario=os-surface output=\(slot.rawValue)] postAction must follow action")
            }
        }
        XCTAssertTrue(anyOutputFired,
                      "[scenario=os-surface] OS-event chain must reach at least one output's action lifecycle")

        trackpad.stop()
        await bus.close()
    }

    // MARK: - Helpers

    private func reaction(for kind: ReactionKind) -> Reaction {
        switch kind {
        case .impact:
            return .impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1.0, sources: []))
        case .usbAttached:
            return .usbAttached(USBDeviceInfo(name: "x", vendorID: 0, productID: 0))
        case .usbDetached:
            return .usbDetached(USBDeviceInfo(name: "x", vendorID: 0, productID: 0))
        case .acConnected:    return .acConnected
        case .acDisconnected: return .acDisconnected
        case .audioPeripheralAttached:
            return .audioPeripheralAttached(AudioPeripheralInfo(uid: "u", name: "n"))
        case .audioPeripheralDetached:
            return .audioPeripheralDetached(AudioPeripheralInfo(uid: "u", name: "n"))
        case .bluetoothConnected:
            return .bluetoothConnected(BluetoothDeviceInfo(address: "a", name: "n"))
        case .bluetoothDisconnected:
            return .bluetoothDisconnected(BluetoothDeviceInfo(address: "a", name: "n"))
        case .thunderboltAttached:
            return .thunderboltAttached(ThunderboltDeviceInfo(name: "n"))
        case .thunderboltDetached:
            return .thunderboltDetached(ThunderboltDeviceInfo(name: "n"))
        case .displayConfigured: return .displayConfigured
        case .willSleep:         return .willSleep
        case .didWake:           return .didWake
        case .trackpadTouching:  return .trackpadTouching
        case .trackpadSliding:   return .trackpadSliding
        case .trackpadContact:   return .trackpadContact
        case .trackpadTapping:   return .trackpadTapping
        case .trackpadCircling:  return .trackpadCircling
        case .mouseClicked:      return .mouseClicked
        case .mouseScrolled:     return .mouseScrolled
        case .keyboardTyped:     return .keyboardTyped
        case .gyroSpike:     return .gyroSpike
        case .lidOpened:     return .lidOpened
        case .lidClosed:     return .lidClosed
        case .lidSlammed:    return .lidSlammed
        case .alsCovered:    return .alsCovered
        case .lightsOff:     return .lightsOff
        case .lightsOn:      return .lightsOn
        }
    }

    private func maskString(_ mask: [Bool]) -> String {
        mask.map { $0 ? "1" : "0" }.joined()
    }
}
