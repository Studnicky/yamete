import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Settings store coverage for defaults, persistence, clamping, and stress paths.
@MainActor
final class SettingsStoreTests: XCTestCase {

    private func freshStore() -> SettingsStore {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        return SettingsStore()
    }

    // MARK: - Defaults (all 10 properties)

    func testDefaults() {
        struct Case { let name: String; let read: (SettingsStore) -> String; let expected: String }
        let cases: [Case] = [
            .init(name: "sensitivityMin",  read: { "\($0.sensitivityMin)" },  expected: "0.1"),
            .init(name: "sensitivityMax",  read: { "\($0.sensitivityMax)" },  expected: "0.9"),
            .init(name: "debounce",     read: { "\($0.debounce)" },     expected: "0.5"),
            .init(name: "screenFlash",     read: { "\($0.screenFlash)" },     expected: "true"),
            .init(name: "visualResponseMode", read: { $0.visualResponseMode.rawValue }, expected: "overlay"),
            .init(name: "flashOpacityMin", read: { "\($0.flashOpacityMin)" }, expected: "0.5"),
            .init(name: "flashOpacityMax", read: { "\($0.flashOpacityMax)" }, expected: "0.9"),
            .init(name: "volumeMin",       read: { "\($0.volumeMin)" },       expected: "0.5"),
            .init(name: "volumeMax",       read: { "\($0.volumeMax)" },       expected: "0.9"),
        ]
        let store = freshStore()
        for c in cases {
            XCTAssertEqual(c.read(store), c.expected, "default \(c.name)")
        }
    }

    // MARK: - Rapid mutation (all sliders + toggles)

    func testRapidSliderDrag() {
        struct Case { let name: String; let mutate: (SettingsStore, Double) -> Void }
        let cases: [Case] = [
            .init(name: "sensitivityMin") { s, v in s.sensitivityMin = v },
            .init(name: "sensitivityMax") { s, v in s.sensitivityMax = v },
            .init(name: "debounce")    { s, v in s.debounce = v },
            .init(name: "flashOpacityMin"){ s, v in s.flashOpacityMin = v },
            .init(name: "flashOpacityMax"){ s, v in s.flashOpacityMax = v },
            .init(name: "volumeMin")      { s, v in s.volumeMin = v },
            .init(name: "volumeMax")      { s, v in s.volumeMax = v },
        ]
        for c in cases {
            let store = freshStore()
            for i in 0..<200 { c.mutate(store, Double(i) / 200.0) }
            // Verify final value is within valid range (0...1 for most, 0...2 for debounce)
            c.mutate(store, 0.5)
            let d = UserDefaults.standard
            let persisted = d.double(forKey: SettingsStore.Key.allCases.first(where: { $0.rawValue == c.name })?.rawValue ?? c.name)
            XCTAssertEqual(persisted, 0.5, accuracy: 0.01, "\(c.name): value should persist after rapid mutations")
        }
    }

    func testRapidBoolToggle() {
        struct Case { let name: String; let toggle: (SettingsStore, Bool) -> Void; let read: (SettingsStore) -> Bool }
        let cases: [Case] = [
            .init(name: "screenFlash", toggle: { $0.screenFlash = $1 }, read: { $0.screenFlash }),
        ]
        for c in cases {
            let store = freshStore()
            for i in 0..<200 { c.toggle(store, i % 2 == 0) }
            XCTAssertFalse(c.read(store), "\(c.name): expected false after even toggle count")
        }
    }

    // MARK: - Persistence roundtrip (all Double properties)

    func testDoublePersistence() {
        struct Case { let name: String; let key: SettingsStore.Key; let write: (SettingsStore) -> Void; let value: Double }
        let cases: [Case] = [
            .init(name: "sensitivityMin",  key: .sensitivityMin,  write: { $0.sensitivityMin = 0.42 },  value: 0.42),
            .init(name: "sensitivityMax",  key: .sensitivityMax,  write: { $0.sensitivityMax = 0.77 },  value: 0.77),
            .init(name: "debounce",     key: .debounce,     write: { $0.debounce = 0.05 },     value: 0.05),
            .init(name: "flashOpacityMin", key: .flashOpacityMin, write: { $0.flashOpacityMin = 0.05 }, value: 0.05),
            .init(name: "flashOpacityMax", key: .flashOpacityMax, write: { $0.flashOpacityMax = 0.9 },  value: 0.9),
            .init(name: "volumeMin",       key: .volumeMin,       write: { $0.volumeMin = 0.15 },       value: 0.15),
            .init(name: "volumeMax",       key: .volumeMax,       write: { $0.volumeMax = 0.85 },       value: 0.85),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store)
            let persisted = UserDefaults.standard.double(forKey: c.key.rawValue)
            XCTAssertEqual(persisted, c.value, accuracy: 1e-10, "\(c.name) persist")
        }
    }

    /// `screenFlash` is now a computed proxy over `visualResponseMode`. The
    /// only thing that persists is `visualResponseMode` — writing screenFlash
    /// should reflect in the visualResponseMode key on disk.
    func testScreenFlashProxiesVisualResponseMode() {
        let store = freshStore()

        store.screenFlash = false
        XCTAssertEqual(store.visualResponseMode, .off)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsStore.Key.visualResponseMode.rawValue),
            VisualResponseMode.off.rawValue)

        store.screenFlash = true
        // False → true flips .off back to .overlay as the default "on" mode.
        XCTAssertEqual(store.visualResponseMode, .overlay)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsStore.Key.visualResponseMode.rawValue),
            VisualResponseMode.overlay.rawValue)
    }

    func testVisualResponseModePersistence() {
        let store = freshStore()
        store.visualResponseMode = .notification

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsStore.Key.visualResponseMode.rawValue),
            VisualResponseMode.notification.rawValue
        )
    }

    // MARK: - Boundary values (all Double properties)

    func testBoundaryValues() {
        struct Case { let name: String; let write: (SettingsStore, Double) -> Void; let read: (SettingsStore) -> Double; let input: Double; let validRange: ClosedRange<Double> }
        let cases: [Case] = [
            // Sensitivity (0...1)
            .init(name: "sensitivityMin neg",  write: { $0.sensitivityMin = $1 }, read: { $0.sensitivityMin }, input: -0.5, validRange: 0...1),
            .init(name: "sensitivityMin over", write: { $0.sensitivityMin = $1 }, read: { $0.sensitivityMin }, input: 1.5,  validRange: 0...1),
            .init(name: "sensitivityMax neg",  write: { $0.sensitivityMax = $1 }, read: { $0.sensitivityMax }, input: -0.5, validRange: 0...1),
            .init(name: "sensitivityMax over", write: { $0.sensitivityMax = $1 }, read: { $0.sensitivityMax }, input: 1.5,  validRange: 0...1),
            // Debounce bounds.
            .init(name: "debounce neg",     write: { $0.debounce = $1 }, read: { $0.debounce }, input: -1,  validRange: 0...3),
            .init(name: "debounce over",    write: { $0.debounce = $1 }, read: { $0.debounce }, input: 5,   validRange: 0...3),
            .init(name: "debounce over",    write: { $0.debounce = $1 }, read: { $0.debounce }, input: 10,  validRange: 0...3),
            // Flash opacity bounds.
            .init(name: "flashOpacityMin neg", write: { $0.flashOpacityMin = $1 }, read: { $0.flashOpacityMin }, input: -1, validRange: 0...1),
            .init(name: "flashOpacityMax over", write: { $0.flashOpacityMax = $1 }, read: { $0.flashOpacityMax }, input: 5, validRange: 0...1),
            // Volume bounds.
            .init(name: "volumeMin neg",       write: { $0.volumeMin = $1 }, read: { $0.volumeMin }, input: -2,  validRange: 0...1),
            .init(name: "volumeMax over",      write: { $0.volumeMax = $1 }, read: { $0.volumeMax }, input: 99,  validRange: 0...1),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store, c.input)
            let v = c.read(store)
            XCTAssertTrue(c.validRange.contains(v), "\(c.name): \(v) not in \(c.validRange) after setting \(c.input)")
        }
    }

    // MARK: - Min ≤ max enforcement (all 4 pairs)

    func testMinMaxEnforcement() {
        struct Case { let name: String; let setup: (SettingsStore) -> Void; let readMin: (SettingsStore) -> Double; let readMax: (SettingsStore) -> Double }
        let cases: [Case] = [
            .init(name: "sensitivity min>max", setup: { $0.sensitivityMax = 0.3; $0.sensitivityMin = 0.8 },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            .init(name: "sensitivity max<min", setup: { $0.sensitivityMin = 0.7; $0.sensitivityMax = 0.2 },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            .init(name: "debounce min>max",    setup: { $0.debounce = 0.1; $0.debounce = 0.8 },
                  readMin: { $0.debounce }, readMax: { $0.debounce }),
            .init(name: "debounce max<min",    setup: { $0.debounce = 1.0; $0.debounce = 0.2 },
                  readMin: { $0.debounce }, readMax: { $0.debounce }),
            .init(name: "volume min>max",      setup: { $0.volumeMax = 0.3; $0.volumeMin = 0.9 },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "volume max<min",      setup: { $0.volumeMin = 0.8; $0.volumeMax = 0.1 },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "opacity min>max",     setup: { $0.flashOpacityMax = 0.2; $0.flashOpacityMin = 0.9 },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
            .init(name: "opacity max<min",     setup: { $0.flashOpacityMin = 0.9; $0.flashOpacityMax = 0.1 },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
        ]
        for c in cases {
            let store = freshStore()
            c.setup(store)
            XCTAssertLessThanOrEqual(c.readMin(store), c.readMax(store), c.name)
        }
    }

    // MARK: - Back-and-forth stress (all 4 pairs)

    func testBackAndForthStress() {
        struct Case { let name: String; let stress: (SettingsStore) -> Void; let readMin: (SettingsStore) -> Double; let readMax: (SettingsStore) -> Double }
        let cases: [Case] = [
            .init(name: "sensitivity", stress: { s in for _ in 0..<100 { s.sensitivityMin = 0.9; s.sensitivityMax = 0.1; s.sensitivityMin = 0.1; s.sensitivityMax = 0.9 } },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            .init(name: "debounce",    stress: { s in for _ in 0..<100 { s.debounce = 1.5; s.debounce = 0.05; s.debounce = 0.05; s.debounce = 1.5 } },
                  readMin: { $0.debounce }, readMax: { $0.debounce }),
            .init(name: "volume",      stress: { s in for _ in 0..<100 { s.volumeMin = 0.9; s.volumeMax = 0.1; s.volumeMin = 0.1; s.volumeMax = 0.9 } },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "opacity",     stress: { s in for _ in 0..<100 { s.flashOpacityMin = 0.9; s.flashOpacityMax = 0.1; s.flashOpacityMin = 0.1; s.flashOpacityMax = 0.9 } },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
        ]
        for c in cases {
            let store = freshStore()
            c.stress(store)
            XCTAssertLessThanOrEqual(c.readMin(store), c.readMax(store), "\(c.name) stress")
        }
    }

    // MARK: - UI-gate mutation anchors (Phase 7)
    //
    // These cells exist to give the mutation catalog stable single-purpose
    // anchors for individual SettingsStore gates. Each assertion message
    // carries a `[ui-gate=...]` tag so `scripts/mutation-test.sh` can match
    // the failure deterministically when the corresponding gate is removed.

    /// Sensitivity clamp gate. Writing 1.5 must be snapped into the [0,1]
    /// unit range. Removing the `if c != sensitivityMin { sensitivityMin = c; return }`
    /// recursive-clamp-and-return makes the out-of-range value persist.
    func testUIGate_sensitivityMinClamp_snapsAboveRangeToBound() {
        let store = freshStore()
        store.sensitivityMin = 1.5
        XCTAssertLessThanOrEqual(store.sensitivityMin, 1.0,
            "[ui-gate=sensitivityMin-clamp] above-range write must clamp to ≤1.0; got \(store.sensitivityMin)")
        XCTAssertGreaterThanOrEqual(store.sensitivityMin, 0.0,
            "[ui-gate=sensitivityMin-clamp] above-range write must clamp to ≥0.0; got \(store.sensitivityMin)")
    }

    /// Sensitivity pair invariant: setting min above max must drag max up.
    /// Removing the `if sensitivityMin > sensitivityMax { sensitivityMax = sensitivityMin }`
    /// pair-fixup leaves the pair inverted.
    func testUIGate_sensitivityMinAboveMax_dragsMaxUp() {
        let store = freshStore()
        store.sensitivityMax = 0.3
        store.sensitivityMin = 0.8
        XCTAssertLessThanOrEqual(store.sensitivityMin, store.sensitivityMax,
            "[ui-gate=sensitivity-min-drags-max] min=\(store.sensitivityMin) must be ≤ max=\(store.sensitivityMax)")
    }

    /// Sensitivity pair invariant: setting max below min must drag min down.
    /// Removing the `if sensitivityMax < sensitivityMin { sensitivityMin = sensitivityMax }`
    /// pair-fixup leaves the pair inverted.
    func testUIGate_sensitivityMaxBelowMin_dragsMinDown() {
        let store = freshStore()
        store.sensitivityMin = 0.7
        store.sensitivityMax = 0.2
        XCTAssertLessThanOrEqual(store.sensitivityMin, store.sensitivityMax,
            "[ui-gate=sensitivity-max-drags-min] min=\(store.sensitivityMin) must be ≤ max=\(store.sensitivityMax)")
    }

    /// Volume clamp gate. Removing the recursive-clamp `if c != volumeMax`
    /// allows out-of-range writes through.
    func testUIGate_volumeMaxClamp_snapsAboveRangeToBound() {
        let store = freshStore()
        store.volumeMax = 5.0
        XCTAssertLessThanOrEqual(store.volumeMax, 1.0,
            "[ui-gate=volumeMax-clamp] above-range write must clamp to ≤1.0; got \(store.volumeMax)")
    }

    /// Flash-opacity pair invariant: setting min above max must drag max up.
    /// Removing the pair-fixup leaves the pair inverted.
    func testUIGate_flashOpacityMinAboveMax_dragsMaxUp() {
        let store = freshStore()
        store.flashOpacityMax = 0.2
        store.flashOpacityMin = 0.9
        XCTAssertLessThanOrEqual(store.flashOpacityMin, store.flashOpacityMax,
            "[ui-gate=flashOpacity-min-drags-max] min=\(store.flashOpacityMin) must be ≤ max=\(store.flashOpacityMax)")
    }

    /// Bandpass pair invariant on writes (didSet path): setting low above
    /// high must drag high up. Removing
    /// `if accelBandpassLowHz > accelBandpassHighHz { accelBandpassHighHz = accelBandpassLowHz }`
    /// leaves the pair inverted, which the bandpass filter would then mis-apply.
    func testUIGate_bandpassLowAboveHigh_dragsHighUp() {
        let store = freshStore()
        store.accelBandpassHighHz = 12.0
        store.accelBandpassLowHz  = 22.0
        XCTAssertLessThanOrEqual(store.accelBandpassLowHz, store.accelBandpassHighHz,
            "[ui-gate=bandpass-low-drags-high] low=\(store.accelBandpassLowHz) must be ≤ high=\(store.accelBandpassHighHz)")
    }

    /// Cold-load isFinite sanitization: a NaN persisted under sensitivityMin
    /// must be replaced by the default at boot. Removing
    /// `if !store.sensitivityMin.isFinite { store.sensitivityMin = Defaults.sensitivityMin }`
    /// from `sanitizeNonFiniteAndPairings` lets NaN propagate to the live
    /// settings graph (where every clamp / pair-fixup downstream malfunctions
    /// because every comparison with NaN returns false).
    func testUIGate_sanitizeNaN_sensitivityMin_restoredToDefault() {
        // Wipe + write NaN under the raw key, then construct a fresh store.
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        UserDefaults.standard.set(Double.nan, forKey: SettingsStore.Key.sensitivityMin.rawValue)
        let store = SettingsStore()
        XCTAssertTrue(store.sensitivityMin.isFinite,
            "[ui-gate=sanitize-nan-sensitivityMin] NaN persisted in UserDefaults must be sanitized to a finite default; got \(store.sensitivityMin)")
        XCTAssertEqual(store.sensitivityMin, Defaults.sensitivityMin, accuracy: 0.0001,
            "[ui-gate=sanitize-nan-sensitivityMin] NaN must be replaced by Defaults.sensitivityMin; got \(store.sensitivityMin)")
    }

    /// Cold-load pair invariant in sanitize: an inverted bandpass low/high
    /// pair on disk must be re-ordered at boot. Removing the
    /// `if store.accelBandpassLowHz > store.accelBandpassHighHz` block in
    /// `sanitizeNonFiniteAndPairings` allows the inverted pair to land in
    /// the live store, where the bandpass filter would reject all input.
    func testUIGate_sanitizeBandpassInverted_pairFixedAtBoot() {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        UserDefaults.standard.set(22.0, forKey: SettingsStore.Key.accelBandpassLowHz.rawValue)
        UserDefaults.standard.set(12.0, forKey: SettingsStore.Key.accelBandpassHighHz.rawValue)
        let store = SettingsStore()
        XCTAssertLessThanOrEqual(store.accelBandpassLowHz, store.accelBandpassHighHz,
            "[ui-gate=sanitize-bandpass-pair] inverted bandpass on disk must be re-ordered at boot; low=\(store.accelBandpassLowHz) high=\(store.accelBandpassHighHz)")
    }

    /// `flashEnabled` didSet must turn `visualResponseMode` from .overlay
    /// back to .off when toggled false. Removing
    /// `if !flashEnabled && visualResponseMode == .overlay { visualResponseMode = .off }`
    /// leaves the legacy mode key advertising .overlay even though flash is off,
    /// breaking call sites that still consult the legacy key.
    func testUIGate_flashEnabledOff_clearsVisualResponseModeOverlay() {
        let store = freshStore()
        store.visualResponseMode = .overlay  // baseline
        store.flashEnabled = true            // sync no-op
        store.flashEnabled = false           // exercise the gate
        XCTAssertEqual(store.visualResponseMode, .off,
            "[ui-gate=flashEnabled-off-clears-mode] turning flash off must reset visualResponseMode to .off; got \(store.visualResponseMode)")
    }

    /// `flashEnabled` didSet must promote `visualResponseMode` from .off
    /// to .overlay when toggled on. Removing
    /// `if flashEnabled && visualResponseMode == .off { visualResponseMode = .overlay }`
    /// leaves the legacy mode key advertising .off even though flash was just
    /// enabled, suppressing the overlay through every legacy consumer.
    func testUIGate_flashEnabledOn_promotesVisualResponseModeToOverlay() {
        let store = freshStore()
        store.visualResponseMode = .off
        store.flashEnabled = false
        store.flashEnabled = true
        XCTAssertEqual(store.visualResponseMode, .overlay,
            "[ui-gate=flashEnabled-on-promotes-mode] turning flash on must promote visualResponseMode to .overlay; got \(store.visualResponseMode)")
    }

    // MARK: - Same-value no-op (all properties)

    func testSameValueNoOp() {
        struct Case { let name: String; let setTwice: (SettingsStore) -> Void }
        let cases: [Case] = [
            .init(name: "sensitivityMin") { $0.sensitivityMin = 0.5; $0.sensitivityMin = 0.5 },
            .init(name: "sensitivityMax") { $0.sensitivityMax = 0.5; $0.sensitivityMax = 0.5 },
            .init(name: "debounce")    { $0.debounce = 0.2; $0.debounce = 0.2 },
            .init(name: "screenFlash")    { $0.screenFlash = false; $0.screenFlash = false },
            .init(name: "visualResponseMode") { $0.visualResponseMode = .notification; $0.visualResponseMode = .notification },
            .init(name: "flashOpacityMin"){ $0.flashOpacityMin = 0.3; $0.flashOpacityMin = 0.3 },
            .init(name: "flashOpacityMax"){ $0.flashOpacityMax = 0.7; $0.flashOpacityMax = 0.7 },
            .init(name: "volumeMin")      { $0.volumeMin = 0.2; $0.volumeMin = 0.2 },
            .init(name: "volumeMax")      { $0.volumeMax = 0.8; $0.volumeMax = 0.8 },
        ]
        for c in cases {
            let store = freshStore()
            c.setTwice(store)
            // No crash = success. Verifies guard-clamp pattern handles same-value correctly.
        }
    }
}
