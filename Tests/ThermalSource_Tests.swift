import XCTest
import Foundation
@testable import SensorKit
@testable import YameteCore

/// Behavioural cells for `ThermalSource`, the discrete state-transition
/// reaction source over `ProcessInfo.thermalState`.
///
/// The source registers a `NotificationCenter` observer for
/// `ProcessInfo.thermalStateDidChangeNotification`, captures the
/// current state at start (cold-start suppression), and on every
/// notification re-reads the state via the injected provider, dedups
/// against the last-observed state, and publishes the matching
/// Reaction on a transition. Tests inject a `MockThermalStateProvider`
/// and drive transitions via the `_testTriggerStateChange(to:)` seam,
/// bypassing NSNotificationCenter entirely so the cells are
/// deterministic regardless of any real OS thermal-pressure signal
/// during the test window.
final class ThermalSource_Tests: XCTestCase {

    // MARK: - Helpers

    /// Build a source wired to a fresh mock provider with the
    /// requested initial state. Returns both so the cell can mutate
    /// the provider directly when needed.
    static func makeSource(initial: ProcessInfo.ThermalState = .nominal) -> (ThermalSource, MockThermalStateProvider) {
        let mock = MockThermalStateProvider(initial)
        let source = ThermalSource(provider: mock)
        return (source, mock)
    }

    /// Subscribe FIRST, then run `inject`, await `windowMs`, close
    /// the bus, and return the count of reactions matching `kind`.
    @MainActor
    static func runAndCount(on bus: ReactionBus,
                            kind: ReactionKind,
                            windowMs: Int,
                            inject: @MainActor () async -> Void) async -> Int {
        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == kind { count += 1 }
            return count
        }
        await inject()
        try? await Task.sleep(for: CITiming.scaledDuration(ms: windowMs))
        await bus.close()
        return await collector.value
    }

    /// Subscribe FIRST, run `inject`, await `windowMs`, close the
    /// bus, and return the kinds of every thermal reaction observed
    /// in emission order.
    @MainActor
    static func runAndCollectKinds(on bus: ReactionBus,
                                   windowMs: Int,
                                   inject: @MainActor () async -> Void) async -> [ReactionKind] {
        let stream = await bus.subscribe()
        let collector = Task { () -> [ReactionKind] in
            var kinds: [ReactionKind] = []
            for await fired in stream {
                let k = fired.reaction.kind
                switch k {
                case .thermalNominal, .thermalFair, .thermalSerious, .thermalCritical:
                    kinds.append(k)
                default: break
                }
            }
            return kinds
        }
        await inject()
        try? await Task.sleep(for: CITiming.scaledDuration(ms: windowMs))
        await bus.close()
        return await collector.value
    }

    // MARK: - Lifecycle

    func test_lifecycle_startStop_idempotent() async {
        let (source, _) = Self.makeSource(initial: .nominal)
        let bus = ReactionBus()

        await MainActor.run { source.start(publishingTo: bus) }
        await MainActor.run { source.start(publishingTo: bus) }
        // Second start must be a no-op — lastState should still be set.
        XCTAssertNotNil(source._testCurrentLastState(),
            "[thermal=lifecycle-start] start must capture cold-start baseline")

        source.stop()
        source.stop()
        XCTAssertNil(source._testCurrentLastState(),
            "[thermal=lifecycle-stop-idempotent] stop must clear lastState")

        // Restart cycle works.
        await MainActor.run { source.start(publishingTo: bus) }
        XCTAssertNotNil(source._testCurrentLastState(),
            "[thermal=lifecycle-restart] restart after stop must re-capture baseline")
        source.stop()

        await bus.close()
    }

    // MARK: - Cold-start suppression

    func test_initialState_doesNotEmit() async {
        // Host starts at .fair. Source captures .fair at start. Without
        // any subsequent transition, no reaction must publish.
        let (source, _) = Self.makeSource(initial: .fair)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let kinds = await Self.runAndCollectKinds(on: bus, windowMs: 80) { @MainActor in
            // No transition driven — just wait and confirm silence.
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(kinds, [],
            "[thermal=cold-start] initial state must not publish (got \(kinds))")
    }

    // MARK: - Transitions

    func test_transition_nominalToFair_emits() async {
        let (source, mock) = Self.makeSource(initial: .nominal)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalFair, windowMs: 80) { @MainActor in
            mock.set(.fair)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 1,
            "[thermal=nominal→fair] transition must emit exactly one .thermalFair (got \(count))")
    }

    func test_transition_fairToSerious_emits() async {
        let (source, mock) = Self.makeSource(initial: .fair)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalSerious, windowMs: 80) { @MainActor in
            mock.set(.serious)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 1,
            "[thermal=fair→serious] transition must emit exactly one .thermalSerious (got \(count))")
    }

    func test_transition_seriousToCritical_emits() async {
        let (source, mock) = Self.makeSource(initial: .serious)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalCritical, windowMs: 80) { @MainActor in
            mock.set(.critical)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 1,
            "[thermal=serious→critical] transition must emit exactly one .thermalCritical (got \(count))")
    }

    func test_transition_criticalToNominal_emits() async {
        let (source, mock) = Self.makeSource(initial: .critical)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalNominal, windowMs: 80) { @MainActor in
            mock.set(.nominal)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 1,
            "[thermal=critical→nominal] transition must emit exactly one .thermalNominal (got \(count))")
    }

    // MARK: - Dedup

    func test_idempotentTransition_noEmit() async {
        // Inject the same state twice. Only the first transition (from
        // initial) should fire; the second (same-state) must dedup.
        let (source, mock) = Self.makeSource(initial: .nominal)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalSerious, windowMs: 80) { @MainActor in
            mock.set(.serious)
            await source._testTriggerStateChange()
            // Second trigger with the same state — must dedup.
            await source._testTriggerStateChange()
            mock.set(.serious)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 1,
            "[thermal=dedup] same-state notifications must collapse to 1 emission (got \(count))")
    }

    // MARK: - Hardware presence

    func test_isAvailable_alwaysTrue() {
        let (source, _) = Self.makeSource(initial: .nominal)
        XCTAssertTrue(source.isAvailable,
            "[thermal=isAvailable] thermal source must always be available — universal OS surface")
    }
}
