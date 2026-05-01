import XCTest
import AppKit
@testable import YameteCore
@testable import ResponseKit
@testable import SensorKit

/// Bus-interaction matrix: for every meaningful pair of `(kindA, kindB)` and
/// every lifecycle scenario, assert ReactionBus + ReactiveOutput honor the
/// drop-not-cancel + coalesce + cancelAndReset semantics.
///
/// Scenarios:
///   1. A then B in the coalesce window → bus fans out BOTH reactions to
///      every subscriber (the output's action coalesces them, but the bus
///      itself fans out two `FiredReaction` envelopes).
///   2. A in flight (action() sleeping), B published → B dropped at the
///      output; A's action still completes normally (drop-not-cancel).
///   3. A's lifecycle fully completes, then B published → B fires fresh
///      (no bleed-through state from A).
///   4. `cancelAndReset()` between A and B → A's `reset()` runs, A's
///      postAction does NOT, then B fires fresh.
///
/// 5 representative kinds × 5 = 25 ordered pairs × 4 scenarios = 100 cells
/// (scenario 3 skips same-kind, so the actual cell count is slightly lower
/// — see test for the exact tally).
@MainActor
final class MatrixBusInteractionTests: IntegrationTestCase {

    /// Representative spread across reaction families: impact, trackpad,
    /// device, mouse. Picked for variety rather than exhaustiveness — the
    /// invariant is bus+output semantics, not per-kind branching.
    private static let representativeKinds: [ReactionKind] = [
        .impact, .trackpadTouching, .trackpadCircling, .usbAttached, .mouseScrolled
    ]

    // MARK: - Top-level matrix entry

    func testBusInteractionMatrix() async {
        var cells = 0
        for kindA in Self.representativeKinds {
            for kindB in Self.representativeKinds {
                await assertScenario1_busFansOutBoth(kindA: kindA, kindB: kindB)
                cells += 1
                await assertScenario2_inFlightDrops(kindA: kindA, kindB: kindB)
                cells += 1
                if kindA != kindB {
                    await assertScenario3_independentAfterCompletion(kindA: kindA, kindB: kindB)
                    cells += 1
                }
                await assertScenario4_cancelAndResetBetween(kindA: kindA, kindB: kindB)
                cells += 1
            }
        }
        let n = Self.representativeKinds.count
        // 5 × 5 = 25 ordered pairs. Scenario 3 only runs when kindA != kindB,
        // i.e. n*(n-1) = 20 times. Scenarios 1, 2, 4 run for all n*n = 25.
        let expected = (n * n * 3) + (n * (n - 1))
        XCTAssertEqual(cells, expected,
                       "matrix cell count drifted from \(expected) (got \(cells))")
    }

    // MARK: - Scenario 1: bus fans out both reactions

    /// Bus broadcast invariant: every published reaction reaches every
    /// subscriber. The output's coalesce window is independent of the bus —
    /// a passive subscriber should observe two FiredReaction envelopes when
    /// the producer publishes twice in rapid succession.
    private func assertScenario1_busFansOutBoth(kindA: ReactionKind, kindB: ReactionKind) async {
        let harness = BusHarness()
        await harness.setUp()

        // Drain the bus for a fixed window. Publish A then B inside it.
        let collectTask = Task { await harness.collectFor(seconds: 0.20) }
        // Tiny lead so the subscriber is registered before publish.
        try? await Task.sleep(for: .milliseconds(20))
        await harness.bus.publish(reactionFor(kind: kindA))
        await harness.bus.publish(reactionFor(kind: kindB))
        let collected = await collectTask.value

        let coords = "[A=\(kindA.rawValue) B=\(kindB.rawValue) sc=1]"
        XCTAssertEqual(collected.count, 2,
                       "\(coords) bus must fan out exactly 2 reactions, got \(collected.count)")
        let kinds = collected.map(\.kind)
        XCTAssertEqual(kinds, [kindA, kindB],
                       "\(coords) bus must preserve publish order, got \(kinds)")
    }

    // MARK: - Scenario 2: in-flight drop-not-cancel

    /// While A's `action()` is sleeping, the output's `lifecycleTask` is
    /// non-nil. B arriving on the bus must be dropped — the output does
    /// not pre-empt the in-flight action. A's action MUST still complete.
    private func assertScenario2_inFlightDrops(kindA: ReactionKind, kindB: ReactionKind) async {
        let harness = BusHarness()
        await harness.setUp()
        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()
        spy.allow = true
        // Pin A's action `in flight` deterministically — instead of racing
        // a wall-clock `actionDuration` against slow CI hardware (which
        // could let A finish before B publishes and falsify drop-not-cancel),
        // gate A's action on an explicit token. Test releases the token
        // only AFTER B has been published and the in-flight drop has had
        // a chance to register.
        let token = PauseToken()
        spy.pauseUntil = token

        let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: provider) }
        // Wait until the subscriber is actually registered on the bus —
        // polling beats a fixed lead because GitHub's macos runner can
        // delay Task scheduling beyond the old 20 ms allowance.
        _ = await awaitUntil(timeout: 1.0) {
            await harness.bus._testSubscriberCount() > 0
        }

        await harness.bus.publish(reactionFor(kind: kindA))
        // Poll until A's action() has actually begun — i.e. the .action
        // phase is recorded. At that point A is unambiguously in flight
        // (blocked on the token) and the next publish targets the
        // drop-not-cancel guard, not a finished lifecycle.
        let aInFlight = await awaitUntil(timeout: 2.0) {
            spy.actionKinds().contains(kindA)
        }
        let coords = "[A=\(kindA.rawValue) B=\(kindB.rawValue) sc=2]"
        XCTAssertTrue(aInFlight,
                      "\(coords) A's action must begin within timeout — gate setup is broken")

        await harness.bus.publish(reactionFor(kind: kindB))
        // Give the bus + output enough time to evaluate B against the
        // in-flight guard. Poll-with-timeout: if B is going to surface
        // (bug), it will land within this window; if B is dropped (correct),
        // the predicate stays false and we fall through to the assertion.
        _ = await awaitUntil(timeout: 0.3) {
            kindA != kindB && spy.actionKinds().contains(kindB)
        }

        // Release A so the lifecycle drains, then wait for postAction
        // before tearing down — keeps the spy state consistent for callers
        // that read `calls` afterwards.
        token.release()
        _ = await awaitUntil(timeout: 1.0) {
            spy.calls.contains { $0.phase == .post && $0.kind == kindA }
        }

        let actionKinds = spy.actionKinds()
        XCTAssertTrue(actionKinds.contains(kindA),
                      "\(coords) A must still deliver during in-flight drop: got \(actionKinds)")
        if kindA != kindB {
            XCTAssertFalse(actionKinds.contains(kindB),
                           "\(coords) B must be dropped (drop-not-cancel) while A in flight: got \(actionKinds)")
        } else {
            // Same-kind: B is also dropped, so we still expect exactly one A action.
            XCTAssertEqual(actionKinds.filter { $0 == kindA }.count, 1,
                           "\(coords) same-kind B must also be dropped while A in flight: got \(actionKinds)")
        }

        consumeTask.cancel()
        await harness.close()
    }

    // MARK: - Scenario 3: independent after A's lifecycle completes

    /// After A's lifecycle (preAction → action → postAction) completes,
    /// `lifecycleTask` resets to nil and the output is ready to fire again.
    /// Publishing B at that point must produce a fresh action delivery —
    /// no leftover coalesce state, no leftover in-flight guard.
    /// Skips same-kind to avoid noise from coalesce vs. fresh-fire ambiguity.
    private func assertScenario3_independentAfterCompletion(kindA: ReactionKind, kindB: ReactionKind) async {
        precondition(kindA != kindB, "scenario 3 requires distinct kinds")
        let harness = BusHarness()
        await harness.setUp()
        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()
        spy.allow = true
        spy.actionDuration = .milliseconds(20)

        let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: provider) }
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 20))

        await harness.bus.publish(reactionFor(kind: kindA))
        // Poll until A's full lifecycle completes (preAction, action, post all
        // recorded). On a fast box this lands in ~40 ms; on slow CI it can
        // take 200+ ms. Poll-until-condition replaces the brittle 150 ms sleep.
        _ = await awaitUntil(timeout: 1.0) {
            spy.actionKinds().contains(kindA)
                && spy.calls.contains { $0.phase == .post && $0.kind == kindA }
        }
        // Tiny yield so any tail of A's lifecycle (lifecycleTask = nil) lands
        // before we publish B.
        await Task.yield()

        await harness.bus.publish(reactionFor(kind: kindB))
        // Poll for B's action delivery.
        _ = await awaitUntil(timeout: 1.0) {
            spy.actionKinds().contains(kindB)
        }

        let coords = "[A=\(kindA.rawValue) B=\(kindB.rawValue) sc=3]"
        let actionKinds = spy.actionKinds()
        XCTAssertTrue(actionKinds.contains(kindA),
                      "\(coords) A must deliver: got \(actionKinds)")
        XCTAssertTrue(actionKinds.contains(kindB),
                      "\(coords) B must fire fresh after A completes: got \(actionKinds)")

        consumeTask.cancel()
        await harness.close()
    }

    // MARK: - Scenario 4: cancelAndReset between A and B

    /// `cancelAndReset()` invoked while A is in flight cancels the lifecycle
    /// task and runs `reset()` (postAction must NOT run after cancel — the
    /// production contract is "reset is the cleanup, post races with reset
    /// are forbidden"). A subsequent publish of B must fire fresh.
    private func assertScenario4_cancelAndResetBetween(kindA: ReactionKind, kindB: ReactionKind) async {
        let harness = BusHarness()
        await harness.setUp()
        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()
        spy.allow = true
        spy.actionDuration = .milliseconds(200)

        let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: provider) }
        try? await Task.sleep(for: .milliseconds(20))

        await harness.bus.publish(reactionFor(kind: kindA))
        // Let coalesce fire and action begin.
        try? await Task.sleep(for: .milliseconds(80))
        spy.cancelAndReset()
        // Give cancellation/reset a moment to settle.
        try? await Task.sleep(for: .milliseconds(50))
        await harness.bus.publish(reactionFor(kind: kindB))
        try? await Task.sleep(for: .milliseconds(300))

        let coords = "[A=\(kindA.rawValue) B=\(kindB.rawValue) sc=4]"
        let phases = spy.calls.map(\.phase)
        XCTAssertTrue(phases.contains(.reset),
                      "\(coords) cancelAndReset must invoke reset(): got \(phases)")
        // postAction for A MUST NOT run — A was cancelled mid-action. Use the
        // reset boundary to delimit A's calls from B's: any .post observed
        // BEFORE the .reset belongs to A's lifecycle (forbidden); any .post
        // observed AFTER the .reset belongs to B's fresh lifecycle (expected).
        guard let resetIdx = phases.firstIndex(of: .reset) else {
            XCTFail("\(coords) reset() never observed; phases=\(phases)")
            consumeTask.cancel(); await harness.close(); return
        }
        let postsBeforeReset = phases.prefix(resetIdx).filter { $0 == .post }.count
        XCTAssertEqual(postsBeforeReset, 0,
                       "\(coords) postAction must NOT run after cancelAndReset for A: phases=\(phases)")
        // B must fire fresh.
        XCTAssertTrue(spy.actionKinds().contains(kindB),
                      "\(coords) B must fire fresh after cancelAndReset: got \(spy.actionKinds())")

        consumeTask.cancel()
        await harness.close()
    }

    // MARK: - OS-surface cell — full path through detection to subscriber

    /// Bus-fanout invariant via the OS-event-routing surface. A trackpad
    /// gesture synthesized through `MockEventMonitor.emit(...)` flows through
    /// `TrackpadActivitySource`'s real detection (RMS, debounce, attribution)
    /// and lands at the subscriber as a `FiredReaction`. Confirms the
    /// OS-surface path also reaches outputs — not just `bus.publish` shortcuts.
    func testOSSurface_trackpadGesture_reachesSubscriber() async throws {
        let harness = BusHarness()
        await harness.setUp()
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
        trackpad.start(publishingTo: harness.bus)

        let collectTask = Task { await harness.collectFor(seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

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
            try? await Task.sleep(for: .milliseconds(10))
        }
        let collected = await collectTask.value
        let trackpadKinds: Set<ReactionKind> = [.trackpadTouching, .trackpadSliding, .trackpadContact, .trackpadCircling]
        XCTAssertTrue(collected.contains(where: { trackpadKinds.contains($0.kind) }),
                      "[scenario=os-surface] trackpad gesture must produce a fired reaction at subscriber; got \(collected.map(\.kind))")
        trackpad.stop()
    }

    // MARK: - Helpers

    /// Builds a representative `Reaction` value for the given kind. Mirrors
    /// the shape used by `MatrixRouting_Tests.reactionFor` so tests sharing
    /// these kinds produce comparable bus envelopes.
    private func reactionFor(kind: ReactionKind, intensity: Float = 0.5) -> Reaction {
        switch kind {
        case .impact:
            return .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: []))
        case .usbAttached:              return .usbAttached(.init(name: "test", vendorID: 0, productID: 0))
        case .usbDetached:              return .usbDetached(.init(name: "test", vendorID: 0, productID: 0))
        case .acConnected:              return .acConnected
        case .acDisconnected:           return .acDisconnected
        case .audioPeripheralAttached: return .audioPeripheralAttached(.init(uid: "u", name: "n"))
        case .audioPeripheralDetached: return .audioPeripheralDetached(.init(uid: "u", name: "n"))
        case .bluetoothConnected:       return .bluetoothConnected(.init(address: "a", name: "n"))
        case .bluetoothDisconnected:    return .bluetoothDisconnected(.init(address: "a", name: "n"))
        case .thunderboltAttached:      return .thunderboltAttached(.init(name: "n"))
        case .thunderboltDetached:      return .thunderboltDetached(.init(name: "n"))
        case .displayConfigured:        return .displayConfigured
        case .willSleep:                return .willSleep
        case .didWake:                  return .didWake
        case .trackpadTouching:         return .trackpadTouching
        case .trackpadSliding:          return .trackpadSliding
        case .trackpadContact:          return .trackpadContact
        case .trackpadTapping:          return .trackpadTapping
        case .trackpadCircling:         return .trackpadCircling
        case .mouseClicked:             return .mouseClicked
        case .mouseScrolled:            return .mouseScrolled
        case .keyboardTyped:            return .keyboardTyped
        }
    }
}
