import XCTest
import Observation
@testable import YameteCore
@testable import SensorKit
@testable import YameteApp

/// Locks down the SwiftUI-Observation contract for classes whose
/// stored properties views read directly via dot-chains
/// (e.g. `yamete.fusion.isRunning` in `HeaderSection` and
/// `MenuBarIcon`). When such a class is not `@Observable`,
/// mutations to its stored properties are silent to SwiftUI:
/// the value flips, no view re-renders, and every existing
/// behaviour test still passes because the test reads the value
/// directly instead of through Observation.
///
/// Two layers of coverage:
///   1. **Structural** — a static `Observable`-conformance check on
///      every type a view reads from via a dot-chain. Compile-time
///      guard against forgetting the macro on a new inner class.
///   2. **Behavioural** — `withObservationTracking { ... } onChange:`
///      around each mutation point. Asserts that a SwiftUI consumer
///      reading the property would have been notified, not just that
///      the property itself updated.
@MainActor
final class ObservationContractTests: XCTestCase {

    // MARK: - Layer 1: structural conformance

    /// Compile-time + runtime guard: every type a view reads via
    /// `yamete.X.Y` chain must conform to `Observable`. Adding a new
    /// view consumer of the form `yamete.foo.bar` requires extending
    /// this list AND marking `foo`'s class `@Observable`. The cell
    /// fails the build if a listed type loses its conformance.
    func testObservableConformance_classesReadViaDotChainsFromViews() {
        // Generic checker: takes a metatype and confirms it conforms
        // to Observable. The function-generic constraint is what
        // produces the compile-time guarantee — passing a class that
        // is not Observable will not compile.
        func assertObservable<T: Observable>(_ type: T.Type, file: StaticString = #filePath, line: UInt = #line) {
            // Body is a no-op; the constraint does the work.
            _ = type
        }

        // Every entry here mirrors a `yamete.<thing>.<property>` read
        // somewhere under `Sources/YameteApp/Views/`. Greppable from
        // CI via:
        //   grep -rn 'yamete\.<thing>\.' Sources/YameteApp/Views/
        assertObservable(ImpactFusion.self)
        assertObservable(Yamete.self)
        assertObservable(MenuBarFace.self)
        assertObservable(SettingsStore.self)
    }

    // MARK: - Layer 2: behavioural — withObservationTracking notifies

    /// Mutating `ImpactFusion.isRunning` MUST trigger SwiftUI
    /// Observation. This is the regression that nearly shipped: the
    /// flag flipped on `start()` / `stop()` but views reading
    /// `yamete.fusion.isRunning` never re-rendered because the class
    /// was not `@Observable`. Asserts the observer's `onChange` fires
    /// in response to the flag transition.
    func testImpactFusion_isRunningMutation_firesObservationTracking() async {
        let fusion = ImpactFusion()
        // Start in a non-running state so the transition we drive is
        // observable. Stop first as a no-op precondition; some test
        // hosts inherit a leftover running fusion across cells.
        fusion.stop()
        XCTAssertFalse(fusion.isRunning, "precondition: fusion stopped before observation registers")

        let bus = ReactionBus()
        let observed = ObservationFlag()
        withObservationTracking {
            _ = fusion.isRunning
        } onChange: {
            Task { @MainActor in observed.fire() }
        }

        fusion.start(sources: [TestableSensorSource()], bus: bus)

        let fired = await awaitUntil(timeout: 1.0) { observed.didFire }
        XCTAssertTrue(fired,
                      "withObservationTracking must observe `ImpactFusion.isRunning` " +
                      "transition; missing `@Observable` on ImpactFusion would silence " +
                      "every SwiftUI view that reads `yamete.fusion.isRunning`")

        fusion.stop()
    }

    /// Symmetric to the above: `stop()` must also notify observers
    /// reading `isRunning`. The flag transitions in both directions
    /// should both register.
    func testImpactFusion_stopMutation_firesObservationTracking() async {
        let fusion = ImpactFusion()
        let bus = ReactionBus()
        fusion.start(sources: [TestableSensorSource()], bus: bus)
        XCTAssertTrue(fusion.isRunning, "precondition: fusion running before observation registers")

        let observed = ObservationFlag()
        withObservationTracking {
            _ = fusion.isRunning
        } onChange: {
            Task { @MainActor in observed.fire() }
        }

        fusion.stop()

        let fired = await awaitUntil(timeout: 1.0) { observed.didFire }
        XCTAssertTrue(fired,
                      "withObservationTracking must observe `ImpactFusion.isRunning` " +
                      "transition on stop()")
    }

    /// Configuration mutations on `ImpactFusion.config` must also
    /// register. Views that surface tuning state (e.g. via
    /// `consensusRequired`) would otherwise lag the persisted value.
    func testImpactFusion_configMutation_firesObservationTracking() async {
        let fusion = ImpactFusion()
        let initial = fusion.config

        let observed = ObservationFlag()
        withObservationTracking {
            _ = fusion.config
        } onChange: {
            Task { @MainActor in observed.fire() }
        }

        let next = FusionConfig(
            consensusRequired: initial.consensusRequired == 1 ? 2 : 1,
            rearmDuration: initial.rearmDuration
        )
        fusion.configure(next)

        let fired = await awaitUntil(timeout: 1.0) { observed.didFire }
        XCTAssertTrue(fired,
                      "withObservationTracking must observe `ImpactFusion.config` " +
                      "transition on configure(_:)")
    }
}

/// Shared one-shot flag the observation tests use to capture whether
/// `onChange:` fired without racing the assertion. `withObservationTracking`'s
/// `onChange:` callback runs once per registration; tests register a
/// fresh tracker per cell so the flag never gets reused across cells.
@MainActor
private final class ObservationFlag {
    private(set) var didFire: Bool = false
    func fire() { didFire = true }
}


/// Minimal `SensorSource` fixture for the observation tests so
/// `ImpactFusion.start(...)` clears the empty-source guard and the
/// `isRunning` transition fires.
private final class TestableSensorSource: SensorSource, @unchecked Sendable {
    let id = SensorID("observation-test-source")
    let name = "Observation Test Source"
    var isAvailable: Bool { true }
    func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        AsyncThrowingStream { _ in /* never yields; test does not consume */ }
    }
}
