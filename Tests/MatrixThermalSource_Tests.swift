import XCTest
import Foundation
@testable import SensorKit
@testable import YameteCore

/// Mutation-anchor cells for `Sources/SensorKit/ThermalSource.swift`.
/// Each cell pins a single behavioural gate so removing the gate
/// flips the assertion and makes `make mutate`
/// (`scripts/mutation-test.sh`) report the corresponding catalog
/// entry CAUGHT.
///
/// Catalog rows wired to these cells:
///   - thermal-initial-suppression -> testThermal_initialSuppression_isCaught
///   - thermal-state-dedup         -> testThermal_stateDedup_isCaught
///   - thermal-state-mapping       -> testThermal_stateMapping_isCaught
///   - thermal-observer-removal    -> testThermal_observerRemoval_isCaught
final class MatrixThermalSource_Tests: XCTestCase {

    // MARK: - Helpers

    private static func makeSource(initial: ProcessInfo.ThermalState = .nominal) -> (ThermalSource, MockThermalStateProvider) {
        let mock = MockThermalStateProvider(initial)
        return (ThermalSource(provider: mock), mock)
    }

    @MainActor
    private static func runAndCount(on bus: ReactionBus,
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

    // MARK: - thermal-initial-suppression
    //
    // Pins the cold-start baseline capture in `start()`. The source
    // captures the current state via `provider.thermalState` at start
    // BEFORE registering the observer; this baseline guards the
    // dedup gate against the very first observation. If the mutation
    // drops the baseline assignment (e.g. forces `s.lastState = nil`
    // at start), the first triggered notification is treated as a
    // genuine transition from nil-state and would publish the matching
    // Reaction even though no real transition occurred.
    //
    // Trace: start at .fair. Trigger one change with the provider
    // still at .fair. With the cold-start gate present, the dedup
    // gate (lastState == .fair, current == .fair) suppresses. With
    // the gate dropped, lastState is nil and the same observation
    // erroneously publishes .thermalFair.
    func testThermal_initialSuppression_isCaught() async {
        let (source, _) = Self.makeSource(initial: .fair)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalFair, windowMs: 80) { @MainActor in
            // Trigger one notification cycle WITHOUT mutating the
            // provider — provider.thermalState still returns .fair.
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 0,
            "[thermal-gate=initial-suppression] first observation matching cold-start state must NOT publish (got \(count))")
    }

    // MARK: - thermal-state-dedup
    //
    // Pins the dedup gate `s.lastState == current → no emission`.
    // Two notifications with the same NEW state (e.g. nominal → fair,
    // then fair re-asserted) must collapse to one emission. Mutating
    // the gate (e.g. flipping the comparator) lets the second
    // observation re-publish.
    func testThermal_stateDedup_isCaught() async {
        let (source, mock) = Self.makeSource(initial: .nominal)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .thermalFair, windowMs: 80) { @MainActor in
            mock.set(.fair)
            await source._testTriggerStateChange()    // 1st: fires
            await source._testTriggerStateChange()    // 2nd: must dedup
            await source._testTriggerStateChange()    // 3rd: must dedup
        }
        XCTAssertEqual(count, 1,
            "[thermal-gate=state-dedup] same-state re-notification must produce 1 emission (got \(count))")
    }

    // MARK: - thermal-state-mapping
    //
    // Pins the state→reaction mapping in `ThermalSource.reaction(for:)`.
    // Transitioning to `.serious` MUST emit `.thermalSerious`, not
    // any other thermal kind. Mutating one entry of the mapping
    // (e.g. `.serious → .thermalFair`) makes the assertion observe
    // the wrong kind.
    func testThermal_stateMapping_isCaught() async {
        let (source, mock) = Self.makeSource(initial: .nominal)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let seriousCount = await Self.runAndCount(on: bus, kind: .thermalSerious, windowMs: 80) { @MainActor in
            mock.set(.serious)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(seriousCount, 1,
            "[thermal-gate=state-mapping] .serious must map to .thermalSerious (got \(seriousCount))")
    }

    // MARK: - thermal-observer-removal
    //
    // Pins the `NotificationCenter.removeObserver` call in `stop()`.
    // After stop(), the source's bus reference is cleared — even if
    // the observer remained registered, no transition can publish
    // because the publish gate requires a non-nil bus inside the
    // lock. Mutating the gate (e.g. dropping the bus = nil clear in
    // stop) leaves the observer wired to the bus and a subsequent
    // _testTriggerStateChange would publish even after stop().
    func testThermal_observerRemoval_isCaught() async {
        let (source, mock) = Self.makeSource(initial: .nominal)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        // Stop BEFORE injecting the change. After stop() bus is nil,
        // and the change handler must early-return without publishing.
        source.stop()

        let count = await Self.runAndCount(on: bus, kind: .thermalCritical, windowMs: 80) { @MainActor in
            mock.set(.critical)
            await source._testTriggerStateChange()
        }
        XCTAssertEqual(count, 0,
            "[thermal-gate=observer-removal] post-stop transition must NOT publish (got \(count))")
    }
}
