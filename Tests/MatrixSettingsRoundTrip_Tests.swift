import XCTest
@testable import YameteApp

/// Per-(field × value × persist round-trip × resetToDefaults × cross-contamination)
/// matrix asserting every settings field is independently addressable. Catches
/// the binding-alias bug class — two sliders silently writing to the same
/// UserDefaults key — at the persistence layer.
///
/// Complements `SettingsIndependenceTests.swift` (which proves the trackpad
/// pairs in particular) by sweeping every range pair plus exercising the
/// reset and persistence surfaces.
@MainActor
final class MatrixSettingsRoundTripTests: IntegrationTestCase {

    // MARK: - One row per range pair

    private struct RangePair: Sendable {
        let name: String
        let lowKey: SettingsStore.Key
        let highKey: SettingsStore.Key
        let read: @MainActor (SettingsStore) -> (Double, Double)
        let write: @MainActor (SettingsStore, Double, Double) -> Void
        let validRange: ClosedRange<Double>
    }

    /// Every `(min, max)` settings pair currently exposed by `SettingsStore`.
    /// Each entry's `validRange` matches the `clamped(to:)` band in the
    /// production didSet, so sentinels picked from this range survive the
    /// clamp without being snapped.
    private static let pairs: [RangePair] = [
        .init(name: "sensitivity",
              lowKey: .sensitivityMin, highKey: .sensitivityMax,
              read: { ($0.sensitivityMin, $0.sensitivityMax) },
              write: { $0.sensitivityMin = $1; $0.sensitivityMax = $2 },
              validRange: 0.0...1.0),
        .init(name: "volumeRange",
              lowKey: .volumeMin, highKey: .volumeMax,
              read: { ($0.volumeMin, $0.volumeMax) },
              write: { $0.volumeMin = $1; $0.volumeMax = $2 },
              validRange: 0.0...1.0),
        .init(name: "flashOpacity",
              lowKey: .flashOpacityMin, highKey: .flashOpacityMax,
              read: { ($0.flashOpacityMin, $0.flashOpacityMax) },
              write: { $0.flashOpacityMin = $1; $0.flashOpacityMax = $2 },
              validRange: 0.0...1.0),
        .init(name: "ledBrightness",
              lowKey: .ledBrightnessMin, highKey: .ledBrightnessMax,
              read: { ($0.ledBrightnessMin, $0.ledBrightnessMax) },
              write: { $0.ledBrightnessMin = $1; $0.ledBrightnessMax = $2 },
              validRange: 0.0...1.0),
        .init(name: "trackpadScroll",
              lowKey: .trackpadScrollMin, highKey: .trackpadScrollMax,
              read: { ($0.trackpadScrollMin, $0.trackpadScrollMax) },
              write: { $0.trackpadScrollMin = $1; $0.trackpadScrollMax = $2 },
              validRange: 0.0...1.0),
        .init(name: "trackpadTouching",
              lowKey: .trackpadTouchingMin, highKey: .trackpadTouchingMax,
              read: { ($0.trackpadTouchingMin, $0.trackpadTouchingMax) },
              write: { $0.trackpadTouchingMin = $1; $0.trackpadTouchingMax = $2 },
              validRange: 0.0...1.0),
        .init(name: "trackpadSliding",
              lowKey: .trackpadSlidingMin, highKey: .trackpadSlidingMax,
              read: { ($0.trackpadSlidingMin, $0.trackpadSlidingMax) },
              write: { $0.trackpadSlidingMin = $1; $0.trackpadSlidingMax = $2 },
              validRange: 0.0...1.0),
        // contactMin clamps to 0.1...5.0; contactMax clamps to 0.5...10.0.
        // Pick a band valid for both ends.
        .init(name: "trackpadContact",
              lowKey: .trackpadContactMin, highKey: .trackpadContactMax,
              read: { ($0.trackpadContactMin, $0.trackpadContactMax) },
              write: { $0.trackpadContactMin = $1; $0.trackpadContactMax = $2 },
              validRange: 0.5...5.0),
        // tapMin clamps to 0.5...10.0; tapMax clamps to 1.0...15.0.
        .init(name: "trackpadTap",
              lowKey: .trackpadTapMin, highKey: .trackpadTapMax,
              read: { ($0.trackpadTapMin, $0.trackpadTapMax) },
              write: { $0.trackpadTapMin = $1; $0.trackpadTapMax = $2 },
              validRange: 1.0...10.0),
    ]

    // MARK: - Setup

    /// Wipes every persisted SettingsStore key so each test starts from a
    /// clean UserDefaults state. Mirrors `SettingsIndependenceTests.freshStore`.
    private func freshStore() -> SettingsStore {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        return SettingsStore()
    }

    // MARK: - Cross-contamination matrix
    //
    // For each pair (the "active" row), pick valid sentinels from its own
    // valid range, write only that pair, then assert no other pair in the
    // matrix shifted from its baseline. Catches "two sliders bound to the
    // same UserDefaults key" silently swapping values across pairs.

    func testEveryRangePair_isIndependentlyAddressable() {
        var cells = 0
        for active in Self.pairs {
            let store = freshStore()
            // Snapshot every other pair before writing.
            let baselines: [(String, Double, Double)] = Self.pairs
                .filter { $0.name != active.name }
                .map { ($0.name, $0.read(store).0, $0.read(store).1) }

            // Sentinels: pick interior points so didSet clamps don't snap them.
            let span = active.validRange.upperBound - active.validRange.lowerBound
            let lowSentinel  = active.validRange.lowerBound + span * 0.13
            let highSentinel = active.validRange.lowerBound + span * 0.87
            active.write(store, lowSentinel, highSentinel)

            let coords = "[active=\(active.name) sc=cross-contam]"

            // 1) Active pair retained the values we wrote.
            let readback = active.read(store)
            XCTAssertEqual(readback.0, lowSentinel, accuracy: 0.0001,
                           "\(coords) low write did not stick")
            XCTAssertEqual(readback.1, highSentinel, accuracy: 0.0001,
                           "\(coords) high write did not stick")

            // 2) No other pair shifted from its baseline.
            for (otherName, prevLow, prevHigh) in baselines {
                let other = Self.pairs.first { $0.name == otherName }!
                let now = other.read(store)
                XCTAssertEqual(now.0, prevLow, accuracy: 0.0001,
                               "\(coords) write to \(active.name).low must not affect \(otherName).low")
                XCTAssertEqual(now.1, prevHigh, accuracy: 0.0001,
                               "\(coords) write to \(active.name).high must not affect \(otherName).high")
                cells += 2
            }
            cells += 2 // active low + active high readback
        }
        // Sanity check: 9 pairs × (2 active asserts + 2 × 8 baseline asserts) = 162.
        XCTAssertEqual(cells, Self.pairs.count * (2 + 2 * (Self.pairs.count - 1)),
                       "matrix cell count drifted")
    }

    // MARK: - Persist round-trip
    //
    // Write distinct sentinels into a SettingsStore, then construct a fresh
    // SettingsStore that reads back from UserDefaults. The sentinels must
    // survive — proves persistence is wired through the canonical Key path.

    func testPersistedFields_surviveReload() {
        _ = freshStore()
        let store1 = SettingsStore()
        store1.trackpadTouchingMin = 0.234567
        store1.trackpadSlidingMin  = 0.876543
        store1.flashOpacityMin     = 0.345678
        store1.volumeMin           = 0.456789

        // Force UserDefaults to flush before opening a fresh store.
        UserDefaults.standard.synchronize()

        let store2 = SettingsStore()
        let coords = "[scope=persist-roundtrip]"
        XCTAssertEqual(store2.trackpadTouchingMin, 0.234567, accuracy: 0.0001,
                       "\(coords) trackpadTouchingMin lost on reload")
        XCTAssertEqual(store2.trackpadSlidingMin,  0.876543, accuracy: 0.0001,
                       "\(coords) trackpadSlidingMin lost on reload")
        XCTAssertEqual(store2.flashOpacityMin,     0.345678, accuracy: 0.0001,
                       "\(coords) flashOpacityMin lost on reload")
        XCTAssertEqual(store2.volumeMin,           0.456789, accuracy: 0.0001,
                       "\(coords) volumeMin lost on reload")
    }

    /// Round-trip every range pair via a fresh `SettingsStore`. Uses sentinels
    /// chosen from each pair's valid range (so didSet clamps don't reshape
    /// them) and asserts each pair re-reads exactly what was written.
    func testEveryRangePair_persistsThroughReload() {
        _ = freshStore()
        let store1 = SettingsStore()
        var sentinels: [(String, Double, Double)] = []
        for (idx, pair) in Self.pairs.enumerated() {
            let span = pair.validRange.upperBound - pair.validRange.lowerBound
            // Make every sentinel unique via a per-pair offset to expose any
            // accidental aliasing across keys.
            let lo = pair.validRange.lowerBound + span * (0.10 + 0.005 * Double(idx))
            let hi = pair.validRange.lowerBound + span * (0.85 - 0.005 * Double(idx))
            pair.write(store1, lo, hi)
            sentinels.append((pair.name, lo, hi))
        }
        UserDefaults.standard.synchronize()

        let store2 = SettingsStore()
        for (name, lo, hi) in sentinels {
            let pair = Self.pairs.first { $0.name == name }!
            let now = pair.read(store2)
            let coords = "[active=\(name) sc=persist]"
            XCTAssertEqual(now.0, lo, accuracy: 0.0001,
                           "\(coords) low did not persist (wrote \(lo), read \(now.0))")
            XCTAssertEqual(now.1, hi, accuracy: 0.0001,
                           "\(coords) high did not persist (wrote \(hi), read \(now.1))")
        }
    }

    // MARK: - resetToDefaults restores per-field defaults

    /// `resetToDefaults` must restore each field to its OWN declared default,
    /// not to a shared "0" or "default for category" placeholder. Catches the
    /// regression where someone refactors `resetToDefaults` to assign every
    /// trackpad min to the same constant.
    func testResetToDefaults_restoresPerFieldDefaults() {
        let store = freshStore()
        // Mutate trackpad pairs to obviously-non-default values.
        store.trackpadTouchingMin = 0.99
        store.trackpadSlidingMin  = 0.01
        store.trackpadContactMin  = 4.5
        store.trackpadTapMin      = 9.0
        store.trackpadScrollMin   = 0.77

        store.resetToDefaults()

        // Each per-kind default must match the declared constant in
        // `SettingsStore.defaults`. These are the trackpad minimums and
        // they must be DISTINCT — the bug shape is "all reset to same value".
        let coords = "[scope=reset]"
        XCTAssertEqual(store.trackpadScrollMin,   0.1, accuracy: 0.0001,
                       "\(coords) trackpadScrollMin default drift")
        XCTAssertEqual(store.trackpadTouchingMin, 0.1, accuracy: 0.0001,
                       "\(coords) trackpadTouchingMin default drift")
        XCTAssertEqual(store.trackpadSlidingMin,  0.5, accuracy: 0.0001,
                       "\(coords) trackpadSlidingMin default drift")
        XCTAssertEqual(store.trackpadContactMin,  0.5, accuracy: 0.0001,
                       "\(coords) trackpadContactMin default drift")
        XCTAssertEqual(store.trackpadTapMin,      2.0, accuracy: 0.0001,
                       "\(coords) trackpadTapMin default drift")

        // Spot-check a few non-trackpad defaults too.
        XCTAssertEqual(store.ledBrightnessMin, 0.30, accuracy: 0.0001,
                       "\(coords) ledBrightnessMin default drift")
        XCTAssertEqual(store.ledBrightnessMax, 1.00, accuracy: 0.0001,
                       "\(coords) ledBrightnessMax default drift")

        // Distinctness check: at least three trackpad min defaults differ
        // — proves they aren't aliased to a single shared default value.
        let mins: Set<Double> = [
            store.trackpadTouchingMin,
            store.trackpadSlidingMin,
            store.trackpadContactMin,
            store.trackpadTapMin,
        ]
        XCTAssertGreaterThanOrEqual(mins.count, 3,
            "\(coords) trackpad min defaults collapsed into ≤2 distinct values: \(mins)")
    }

    /// After `resetToDefaults`, every range pair must satisfy `min ≤ max` —
    /// the lazy regression where someone ships a default set with crossed
    /// values.
    func testResetToDefaults_yieldsConsistentMinMaxOrdering() {
        let store = freshStore()
        store.resetToDefaults()
        for pair in Self.pairs {
            let (lo, hi) = pair.read(store)
            let coords = "[active=\(pair.name) sc=reset-ordering]"
            XCTAssertLessThanOrEqual(lo, hi,
                "\(coords) post-reset min(\(lo)) must be ≤ max(\(hi))")
        }
    }

    // MARK: - Key uniqueness (catches duplicate raw values)

    /// `SettingsStore.Key.allCases` must have unique raw values. A duplicate
    /// (e.g. `trackpadTouchingMin = "trackpadScrollMin"`) would silently
    /// merge two sliders into one persistence slot.
    func testKey_rawValues_areUnique() {
        let raws = SettingsStore.Key.allCases.map(\.rawValue)
        let coords = "[scope=key-uniqueness]"
        XCTAssertEqual(raws.count, Set(raws).count,
                       "\(coords) duplicate Key raw values: \(raws.sorted())")
    }

    /// Each pair's low and high keys must be DISTINCT raw values. Catches
    /// the bug where someone copy-pastes a pair declaration and forgets to
    /// rename one end (`min` and `max` collapsing to the same key).
    func testEveryPair_lowAndHighKeysAreDistinct() {
        for pair in Self.pairs {
            let coords = "[active=\(pair.name) sc=pair-distinctness]"
            XCTAssertNotEqual(pair.lowKey.rawValue, pair.highKey.rawValue,
                "\(coords) low and high keys collapsed to same rawValue: \(pair.lowKey.rawValue)")
        }
    }
}
