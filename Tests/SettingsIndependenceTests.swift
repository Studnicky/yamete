import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Locks down the per-trackpad-kind threshold pairs so they are written to
/// distinct UserDefaults keys and never cross-contaminate.
///
/// Bug previously caught in the wild: `trackpadScrollMin/Max`,
/// `trackpadTouchingMin/Max`, `trackpadSlidingMin/Max` were bound to the same
/// UI slider — moving one slider would write to all three pairs at once,
/// which then persisted on next launch and silently destroyed the user's
/// per-kind tuning. This file pins (a) every pair has a distinct rawValue and
/// (b) writing one pair does not perturb any other pair across a fresh
/// SettingsStore round-trip.
@MainActor
final class SettingsIndependenceTests: XCTestCase {

    // MARK: - Setup

    /// Wipes all persisted defaults for every Settings key so each test
    /// starts from registered defaults.
    private func freshStore() -> SettingsStore {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        return SettingsStore()
    }

    // MARK: - Distinct UserDefaults keys

    /// Catches the literal bug class: two trackpad pairs sharing a rawValue.
    /// `Key.allCases` is iterated to assert that every relevant trackpad
    /// rawValue is unique within itself and across the pairs.
    func testTrackpadKeyRawValuesAreDistinct() {
        let trackpadKeys: [SettingsStore.Key] = [
            .trackpadScrollMin,    .trackpadScrollMax,
            .trackpadTouchingMin,  .trackpadTouchingMax,
            .trackpadSlidingMin,   .trackpadSlidingMax,
            .trackpadContactMin,   .trackpadContactMax,
            .trackpadTapMin,       .trackpadTapMax,
        ]
        let raws = trackpadKeys.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count,
                       "every trackpad key must have a distinct rawValue, got \(raws)")
        // Spot-check the literal expected mapping. If anyone swaps one of
        // these for a shared key they'll fail this case before they ship.
        let expected: [String] = [
            "trackpadScrollMin", "trackpadScrollMax",
            "trackpadTouchingMin", "trackpadTouchingMax",
            "trackpadSlidingMin", "trackpadSlidingMax",
            "trackpadContactMin", "trackpadContactMax",
            "trackpadTapMin", "trackpadTapMax",
        ]
        XCTAssertEqual(raws, expected,
                       "trackpad key rawValues drifted from canonical set")
    }

    /// Whole-store sanity: NO two `Key` cases share a rawValue. Settings keys
    /// are addressed by rawValue across the codebase (UserDefaults set/get,
    /// reaction matrices, persistence test cases) and a collision would
    /// silently merge two settings into one persistence slot.
    func testEverySettingsKeyRawValueIsUnique() {
        let raws = SettingsStore.Key.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count,
                       "every SettingsStore.Key rawValue must be unique")
    }

    // MARK: - Round-trip independence

    /// Sets each pair to a unique sentinel value, then constructs a FRESH
    /// `SettingsStore` (forces UserDefaults round-trip), then asserts every
    /// pair reads back exactly what was written — no cross-talk.
    func testTrackpadPairsRoundTripIndependently() {
        let store = freshStore()

        // Pre-clamp ranges so each pair stays within its didSet clamp:
        //   scroll/touching/sliding clamp 0...1
        //   contactMin clamp 0.1...5.0,  contactMax clamp 0.5...10.0
        //   tapMin clamp 0.5...10.0,     tapMax clamp 1.0...15.0
        store.trackpadScrollMin   = 0.11
        store.trackpadScrollMax   = 0.81
        store.trackpadTouchingMin = 0.12
        store.trackpadTouchingMax = 0.52
        store.trackpadSlidingMin  = 0.13
        store.trackpadSlidingMax  = 0.93
        store.trackpadContactMin  = 0.14
        store.trackpadContactMax  = 2.54
        store.trackpadTapMin      = 2.05
        store.trackpadTapMax      = 6.05

        // Force a fresh UserDefaults round-trip — same store would just read
        // out of memory and miss the actual persistence path.
        let reread = SettingsStore()
        XCTAssertEqual(reread.trackpadScrollMin,   0.11, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadScrollMax,   0.81, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadTouchingMin, 0.12, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadTouchingMax, 0.52, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadSlidingMin,  0.13, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadSlidingMax,  0.93, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadContactMin,  0.14, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadContactMax,  2.54, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadTapMin,      2.05, accuracy: 0.0001)
        XCTAssertEqual(reread.trackpadTapMax,      6.05, accuracy: 0.0001)
    }

    /// Mutating one pair must not perturb any of the others. This test
    /// targets the exact bug shape: one slider bound to multiple settings.
    func testMutatingOnePairDoesNotMutateOthers() {
        let store = freshStore()

        // Snapshot pre-write values for every other pair.
        let baseline = TrackpadSnapshot(store: store)

        // Drive ONE pair only.
        store.trackpadTouchingMin = 0.27
        store.trackpadTouchingMax = 0.73

        // Every other pair must equal its baseline value.
        XCTAssertEqual(store.trackpadScrollMin,   baseline.scrollMin,   accuracy: 0.0001,
                       "writing trackpadTouching* must NOT mutate scrollMin")
        XCTAssertEqual(store.trackpadScrollMax,   baseline.scrollMax,   accuracy: 0.0001,
                       "writing trackpadTouching* must NOT mutate scrollMax")
        XCTAssertEqual(store.trackpadSlidingMin,  baseline.slidingMin,  accuracy: 0.0001,
                       "writing trackpadTouching* must NOT mutate slidingMin")
        XCTAssertEqual(store.trackpadSlidingMax,  baseline.slidingMax,  accuracy: 0.0001,
                       "writing trackpadTouching* must NOT mutate slidingMax")
        XCTAssertEqual(store.trackpadContactMin,  baseline.contactMin,  accuracy: 0.0001)
        XCTAssertEqual(store.trackpadContactMax,  baseline.contactMax,  accuracy: 0.0001)
        XCTAssertEqual(store.trackpadTapMin,      baseline.tapMin,      accuracy: 0.0001)
        XCTAssertEqual(store.trackpadTapMax,      baseline.tapMax,      accuracy: 0.0001)

        // And the pair we wrote IS persisted to its own keys.
        XCTAssertEqual(store.trackpadTouchingMin, 0.27, accuracy: 0.0001)
        XCTAssertEqual(store.trackpadTouchingMax, 0.73, accuracy: 0.0001)
    }

    /// All-pair independence sweep: for each pair, set it to a unique value;
    /// verify every other pair retained its baseline. Counterpart to the
    /// "one-pair" test but proving non-interference holds when ANY pair is
    /// the mover.
    func testEveryPairIsIndependentlyAddressable() {
        let pairs: [PairSpec] = [
            PairSpec(name: "scroll",
                     read: { ($0.trackpadScrollMin, $0.trackpadScrollMax) },
                     write: { $0.trackpadScrollMin = $1; $0.trackpadScrollMax = $2 },
                     value: (0.21, 0.71)),
            PairSpec(name: "touching",
                     read: { ($0.trackpadTouchingMin, $0.trackpadTouchingMax) },
                     write: { $0.trackpadTouchingMin = $1; $0.trackpadTouchingMax = $2 },
                     value: (0.22, 0.42)),
            PairSpec(name: "sliding",
                     read: { ($0.trackpadSlidingMin, $0.trackpadSlidingMax) },
                     write: { $0.trackpadSlidingMin = $1; $0.trackpadSlidingMax = $2 },
                     value: (0.55, 0.85)),
            PairSpec(name: "contact",
                     read: { ($0.trackpadContactMin, $0.trackpadContactMax) },
                     write: { $0.trackpadContactMin = $1; $0.trackpadContactMax = $2 },
                     value: (0.6, 2.7)),
            PairSpec(name: "tap",
                     read: { ($0.trackpadTapMin, $0.trackpadTapMax) },
                     write: { $0.trackpadTapMin = $1; $0.trackpadTapMax = $2 },
                     value: (2.1, 6.1)),
        ]

        for active in pairs {
            let store = freshStore()
            // Snapshot every pair's baseline.
            let snapshot = pairs.map { ($0.name, $0.read(store)) }
            // Write only the active pair.
            active.write(store, active.value.0, active.value.1)
            // Verify only the active pair changed; all others equal baseline.
            for (name, baseline) in snapshot where name != active.name {
                let now = pairs.first { $0.name == name }!.read(store)
                XCTAssertEqual(now.0, baseline.0, accuracy: 0.0001,
                               "writing \(active.name) leaked into \(name).min")
                XCTAssertEqual(now.1, baseline.1, accuracy: 0.0001,
                               "writing \(active.name) leaked into \(name).max")
            }
            // Active pair reads back what we wrote.
            let readback = active.read(store)
            XCTAssertEqual(readback.0, active.value.0, accuracy: 0.0001,
                           "\(active.name).min did not retain written value")
            XCTAssertEqual(readback.1, active.value.1, accuracy: 0.0001,
                           "\(active.name).max did not retain written value")
        }
    }

    // MARK: - Test helpers

    /// Snapshot of every trackpad pair value at a moment in time.
    private struct TrackpadSnapshot: Sendable {
        let scrollMin: Double, scrollMax: Double
        let touchingMin: Double, touchingMax: Double
        let slidingMin: Double, slidingMax: Double
        let contactMin: Double, contactMax: Double
        let tapMin: Double, tapMax: Double

        @MainActor
        init(store: SettingsStore) {
            scrollMin   = store.trackpadScrollMin
            scrollMax   = store.trackpadScrollMax
            touchingMin = store.trackpadTouchingMin
            touchingMax = store.trackpadTouchingMax
            slidingMin  = store.trackpadSlidingMin
            slidingMax  = store.trackpadSlidingMax
            contactMin  = store.trackpadContactMin
            contactMax  = store.trackpadContactMax
            tapMin      = store.trackpadTapMin
            tapMax      = store.trackpadTapMax
        }
    }

    /// One pair's read/write closures + a unique sentinel pair value.
    private struct PairSpec {
        let name: String
        let read: @MainActor (SettingsStore) -> (Double, Double)
        let write: @MainActor (SettingsStore, Double, Double) -> Void
        let value: (Double, Double)
    }
}
