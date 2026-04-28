import XCTest
@testable import YameteCore
@testable import SensorKit

/// AC power source matrix.
///
/// Bug class: edge-trigger logic in `handlePowerChange(onAC:)` regresses to
/// always-publish, so every IOPS callback (which fires for any change to ANY
/// power source attribute, not just AC presence) emits a redundant
/// `.acConnected` / `.acDisconnected`. The user feels this as repeated
/// reactions while AC is steady and the OS broadcasts unrelated power
/// updates (battery percentage, charge state, time-remaining estimates).
///
/// `_injectPowerChange(onAC:)` mirrors the
/// `IOPSNotificationCreateRunLoopSource` callback, bypassing
/// `IOPSCopyPowerSourcesInfo` so the test passes the synthetic AC state
/// directly. Drives the same `handlePowerChange(onAC:)` edge-trigger gate.
@MainActor
final class MatrixPowerSourceTests: XCTestCase {

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(
                reaction: reaction,
                clipDuration: 0.5,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: publishedAt
            )
        }
        return bus
    }

    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [FiredReaction] {
        let stream = await bus.subscribe()
        let task = Task {
            var collected: [FiredReaction] = []
            for await fired in stream {
                collected.append(fired)
            }
            return collected
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        return await task.value
    }

    // MARK: - Cell: edge-trigger — repeated same-state injects publish once

    /// `acConnected → acConnected` with no intervening transition must
    /// publish exactly once. Production `lastWasOnAC` edge-trigger drops
    /// the second.
    func testRepeatedSameState_publishesOnce() async {
        let bus = await makeBus()
        let source = PowerSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        // First inject sets the new edge.
        await source._injectPowerChange(onAC: !PowerSource._currentlyOnAC())
        try? await Task.sleep(for: .milliseconds(20))
        // Same state again — must be dropped.
        await source._injectPowerChange(onAC: !PowerSource._currentlyOnAC())
        try? await Task.sleep(for: .milliseconds(20))
        await source._injectPowerChange(onAC: !PowerSource._currentlyOnAC())
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let acEvents = collected.filter { $0.kind == .acConnected || $0.kind == .acDisconnected }
        XCTAssertEqual(acEvents.count, 1,
            "[scenario=repeated-same-state] edge-trigger must collapse 3 same-state injects → 1 publish, got \(acEvents.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: oscillation — true→false→true publishes thrice (alternates)

    /// Each transition is a real edge — three transitions, three publishes.
    func testRapidOscillation_publishesEveryEdge() async {
        let bus = await makeBus()
        let source = PowerSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        // Determine starting edge so each subsequent inject IS a transition.
        let baseline = PowerSource._currentlyOnAC()
        await source._injectPowerChange(onAC: !baseline) // edge 1
        try? await Task.sleep(for: .milliseconds(15))
        await source._injectPowerChange(onAC: baseline)  // edge 2
        try? await Task.sleep(for: .milliseconds(15))
        await source._injectPowerChange(onAC: !baseline) // edge 3
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let acEvents = collected.filter { $0.kind == .acConnected || $0.kind == .acDisconnected }
        XCTAssertEqual(acEvents.count, 3,
            "[scenario=oscillation] each transition must publish, got \(acEvents.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: idempotent start — second start preserves edge-baseline state

    /// `start` is gated by `runLoopSource == nil` so a second call is a no-op.
    /// The observable consequence: the second start must NOT re-seed
    /// `lastWasOnAC` from `currentlyOnAC()`. If the gate regresses (second
    /// start runs through and resets `lastWasOnAC`), an inject that was
    /// previously a no-op (because it matched the post-first-edge state)
    /// becomes a fresh edge again and publishes redundantly.
    ///
    /// Sequence:
    ///   1. start → `lastWasOnAC = baseline`.
    ///   2. inject(!baseline) → real edge, publishes #1, `lastWasOnAC=!baseline`.
    ///   3. start (must be no-op).
    ///   4. inject(!baseline) → with gate intact `lastWasOnAC` is still
    ///      `!baseline` → no edge → no publish. With gate removed
    ///      `lastWasOnAC` was reset to `baseline` → edge → publishes #2.
    /// Production must hold the count at 1.
    func testStartIsIdempotent_preservesEdgeBaseline() async {
        let bus = await makeBus()
        let source = PowerSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        let baseline = PowerSource._currentlyOnAC()
        // Step 2 — first edge, publishes.
        await source._injectPowerChange(onAC: !baseline)
        try? await Task.sleep(for: .milliseconds(20))

        // Step 3 — second start must be a no-op. With the idempotency gate
        // removed, this would re-seed `lastWasOnAC` back to `baseline`.
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))

        // Step 4 — inject the SAME post-edge state. Gate intact → no edge.
        // Gate removed → fresh edge → second publish leaks through.
        await source._injectPowerChange(onAC: !baseline)
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let acEvents = collected.filter { $0.kind == .acConnected || $0.kind == .acDisconnected }
        XCTAssertEqual(acEvents.count, 1,
            "[scenario=idempotent-start-baseline] second start must not reset lastWasOnAC; expected 1 publish, got \(acEvents.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: no-change — first inject matching the snapshotted baseline drops

    /// On `start`, `lastWasOnAC` is seeded to `Self.currentlyOnAC()`. An
    /// inject of the SAME baseline state is a no-op — must not publish.
    func testInitialNoChange_doesNotPublish() async {
        let bus = await makeBus()
        let source = PowerSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        // Inject the SAME state the source was started with — no edge.
        await source._injectPowerChange(onAC: PowerSource._currentlyOnAC())
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let acEvents = collected.filter { $0.kind == .acConnected || $0.kind == .acDisconnected }
        XCTAssertEqual(acEvents.count, 0,
            "[scenario=initial-no-change] no edge → no publish, got \(acEvents.count)")
        source.stop()
        await bus.close()
    }
}

