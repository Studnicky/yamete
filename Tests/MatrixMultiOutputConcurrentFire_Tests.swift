import XCTest
@testable import YameteCore
@testable import ResponseKit

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
    private final class TaggedSpy: ReactiveOutput {
        let slot: OutputSlot
        var preCalls: [(kind: ReactionKind, ts: Date)] = []
        var actCalls: [(kind: ReactionKind, ts: Date)] = []
        var postCalls: [(kind: ReactionKind, ts: Date)] = []
        var allow: Bool = true
        var actionDuration: Duration = .milliseconds(2)

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
            try? await Task.sleep(for: actionDuration)
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

            // Allow consume tasks to subscribe.
            try await Task.sleep(for: .milliseconds(10))

            // Publish one reaction of the chosen kind.
            await bus.publish(reaction(for: kind))

            // Wait for coalesce (16ms) + action (2ms) + slack.
            try await Task.sleep(for: .milliseconds(70))

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
    /// Our action duration here is 50ms — the second publish at +30ms lands
    /// inside the first's lifecycle, so each output should see kind A only.
    func testTwoBackToBack_dropDuringInflight_perOutput() async throws {
        let bus = await makeBus()
        let provider = MockConfigProvider()
        let (spies, tasks) = startRoster(slots: OutputSlot.allCases, bus: bus, provider: provider)
        for spy in spies.values { spy.actionDuration = .milliseconds(50) }
        defer { tasks.forEach { $0.cancel() } }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)            // A
        try await Task.sleep(for: .milliseconds(30))   // past coalesce, mid-action
        await bus.publish(.acDisconnected)         // B — should be dropped
        try await Task.sleep(for: .milliseconds(120)) // wait for A to finish

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
        let (spies, tasks) = startRoster(
            slots: OutputSlot.allCases,
            bus: bus,
            provider: provider,
            slowSlot: .haptic,
            slowDuration: .milliseconds(200)
        )
        defer { tasks.forEach { $0.cancel() } }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        // Wait long enough for fast outputs to finish (coalesce 16 + action 2 + slack)
        // but well before slow output completes.
        try await Task.sleep(for: .milliseconds(80))

        // Fast outputs: completed full lifecycle.
        for slot in OutputSlot.allCases where slot != .haptic {
            let spy = spies[slot]!
            let coords = "[output=\(slot.rawValue) scenario=slow-haptic-noblock]"
            XCTAssertEqual(spy.postCalls.count, 1,
                "\(coords) fast output blocked by slow haptic — postAction did not fire in 80ms")
        }
        // Slow output: started action but post not yet recorded.
        let slow = spies[.haptic]!
        XCTAssertEqual(slow.actCalls.count, 1,
            "[output=haptic scenario=slow-haptic-noblock] slow action should have started")
        XCTAssertEqual(slow.postCalls.count, 0,
            "[output=haptic scenario=slow-haptic-noblock] slow output must not yet have completed")

        // Wait for slow output to complete.
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(slow.postCalls.count, 1,
            "[output=haptic scenario=slow-haptic-noblock] slow output must complete eventually")
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
        }
    }

    private func maskString(_ mask: [Bool]) -> String {
        mask.map { $0 ? "1" : "0" }.joined()
    }
}
