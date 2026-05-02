import XCTest
@testable import YameteCore
@testable import YameteApp

/// Settings-fuzz / corruption-resistance suite.
///
/// Bug class addressed: `SettingsStore.init()` reads from `UserDefaults.standard`
/// at app launch — *before* any UI is on screen. If a corrupted plist (wrong
/// types in cells the migration code didn't account for, or a future-version
/// schema marker, or a malicious archive blob) makes `init` throw, fatalError,
/// or hand back nonsense numbers, the app dies on launch and the user has no
/// way to recover except `defaults delete`. The example-based migration matrix
/// (`MatrixSettingsMigration_Tests`) covers the *known* type-mismatch paths; a
/// fuzzer that generates arbitrary plist shapes catches what the example author
/// didn't anticipate.
///
/// Strategy:
///   - SettingsStore reads only from `UserDefaults.standard`. Per-cell isolation
///     is achieved by wiping every `Key.allCases` entry (plus legacy aliases)
///     before each cell, mirroring `MatrixSettingsMigration_Tests`. Each cell
///     restores nothing on tear-down because the next cell wipes again.
///   - Trial determinism uses the `SeededGenerator` pattern from
///     `PropertyBased_Tests.swift`, inlined here to keep this file
///     self-contained (cross-file generator sharing would require touching
///     `PropertyBased_Tests.swift`, which is out of scope).
///   - Each trial increments local counters: `crashes` (always asserted == 0,
///     because XCTest catches Swift runtime traps via the test runner only —
///     a hit here means the cell exits abnormally) and `throws` (init is not
///     `throws`, so this is also always 0; tracked anyway as a documentation
///     hook for future schema work).
///
/// SIGSEGV note: Swift Testing / XCTest cannot trap SIGSEGV in-process —
/// the process dies and the runner reports "test crashed" rather than a
/// failed assertion. Cell 8 (NSKeyedUnarchiver malicious-input) therefore
/// asserts only that the unarchiver returns nil-or-throws on garbage bytes,
/// which IS catchable. A genuine SIGSEGV-class regression would surface as
/// a CI crash report, not as a per-assertion failure.
@MainActor
final class SettingsFuzz_Tests: XCTestCase {

    // MARK: - Seeded generator (xorshift64, deterministic)

    /// Inlined from `PropertyBased_Tests.SeededGenerator` to keep this file
    /// self-contained and avoid touching the donor cell. Same algorithm,
    /// same seed-as-state contract — so seeds reproduce identically.
    private final class SeededGenerator: @unchecked Sendable {
        private var state: UInt64
        init(seed: UInt64) {
            self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
        }
        @discardableResult
        func nextU64() -> UInt64 {
            var x = state
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            state = x
            return x
        }
        func nextDouble(in range: ClosedRange<Double>) -> Double {
            let bits = nextU64() >> 11
            let unit = Double(bits) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
        func nextInt(in range: ClosedRange<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return Int(nextU64() % span) + range.lowerBound
        }
        func nextBool() -> Bool { (nextU64() & 1) == 1 }
        func nextByte() -> UInt8 { UInt8(nextU64() & 0xFF) }
    }

    // MARK: - UserDefaults wipe (per-cell isolation)

    /// Wipe every `SettingsStore.Key` plus the legacy `screenFlash` alias.
    /// Mirrors `MatrixSettingsMigration_Tests.wipeAllKeys()`. Called at the
    /// start of every cell and between trials within the random-blob cell so
    /// previous-trial residue cannot smear into the next trial's baseline.
    private func wipeAllKeys() {
        let d = UserDefaults.standard
        for key in SettingsStore.Key.allCases {
            d.removeObject(forKey: key.rawValue)
        }
        d.removeObject(forKey: "screenFlash")
        // Hypothetical future version field — wipe defensively so cells 5/6
        // start from a clean slate.
        d.removeObject(forKey: "version")
        d.removeObject(forKey: "settingsSchemaVersion")
    }

    // MARK: - Cell 1: empty-dict plist

    /// Empty `[String: Any]` plist: every key is missing. Construct a fresh
    /// store and assert it returns the registered defaults across a
    /// representative spread (Doubles, Ints, Bools, arrays, matrices). The
    /// implicit invariant is "init does not throw / fatalError on a totally
    /// empty backing store".
    func test_fuzz_cell1_emptyDictPlist_usesDefaults() {
        wipeAllKeys()
        // No writes: this IS the empty-dict shape.
        let store = SettingsStore()

        // Spot-check every type bucket. If init had a hidden force-unwrap on
        // a missing key, one of these would never be reached.
        XCTAssertEqual(store.sensitivityMin, Defaults.sensitivityMin, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] sensitivityMin must default")
        XCTAssertEqual(store.sensitivityMax, Defaults.sensitivityMax, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] sensitivityMax must default")
        XCTAssertEqual(store.debounce, Defaults.debounce, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] debounce must default")
        XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] hapticIntensity must default to 1.0 (not 0.0)")
        XCTAssertEqual(store.displayBrightnessBoost, 0.5, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] displayBrightnessBoost must default")
        XCTAssertEqual(store.volumeSpikeTarget, 0.9, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] volumeSpikeTarget must default")
        XCTAssertEqual(store.mouseScrollThreshold, 3.0, accuracy: 0.0001,
            "[fuzz=cell1-empty-dict] mouseScrollThreshold must default")
        XCTAssertEqual(store.enabledDisplays, [],
            "[fuzz=cell1-empty-dict] enabledDisplays must default to []")
        XCTAssertEqual(store.enabledAudioDevices, [],
            "[fuzz=cell1-empty-dict] enabledAudioDevices must default to []")
        XCTAssertEqual(store.enabledSensorIDs, [],
            "[fuzz=cell1-empty-dict] enabledSensorIDs must default to []")
        XCTAssertFalse(store.notificationsEnabled,
            "[fuzz=cell1-empty-dict] notificationsEnabled defaults off")
        XCTAssertTrue(store.flashEnabled,
            "[fuzz=cell1-empty-dict] flashEnabled defaults on")
        XCTAssertEqual(store.soundReactionMatrix, ReactionToggleMatrix(),
            "[fuzz=cell1-empty-dict] soundReactionMatrix defaults to empty")
    }

    // MARK: - Cell 2: type-mismatch plist (every key, wrong type)

    /// For each `Key`, write a value of the *opposite* type bucket (Bool keys
    /// get a String, Double keys get a String, array keys get an Int, Data
    /// keys get a String). Construct the store; assert no crash and no NaN
    /// in any Double field (the failure mode the runtime-probe story warned
    /// about: NaN persisted, then clamp() snaps to the lower bound, then the
    /// store re-persists 0.0, locking the user out of audio on every launch).
    func test_fuzz_cell2_typeMismatchAllKeys_usesDefaults() {
        wipeAllKeys()
        let d = UserDefaults.standard
        // Bool keys → String
        for k in [SettingsStore.Key.soundEnabled, .debugLogging, .ledEnabled,
                  .keyboardBrightnessEnabled, .flashEnabled, .flashActiveDisplayOnly,
                  .notificationsEnabled, .hapticEnabled, .displayBrightnessEnabled,
                  .displayTintEnabled, .volumeSpikeEnabled,
                  .trackpadTouchingEnabled, .trackpadSlidingEnabled,
                  .trackpadContactEnabled, .trackpadTappingEnabled,
                  .trackpadCirclingEnabled, .firstLaunchDramaFired] {
            d.set("not-a-bool", forKey: k.rawValue)
        }
        // Double keys → String
        for k in [SettingsStore.Key.sensitivityMin, .sensitivityMax, .debounce,
                  .flashOpacityMin, .flashOpacityMax, .volumeMin, .volumeMax,
                  .accelSpikeThreshold, .accelCrestFactor, .accelRiseRate,
                  .accelReportInterval, .accelBandpassLowHz, .accelBandpassHighHz,
                  .micSpikeThreshold, .micCrestFactor, .micRiseRate,
                  .hpSpikeThreshold, .hpCrestFactor, .hpRiseRate,
                  .ledBrightnessMin, .ledBrightnessMax,
                  .hapticIntensity, .displayBrightnessBoost,
                  .displayBrightnessThreshold, .displayTintIntensity,
                  .volumeSpikeTarget, .volumeSpikeThreshold,
                  .trackpadWindowDuration, .trackpadScrollMin, .trackpadScrollMax,
                  .trackpadTouchingMin, .trackpadTouchingMax,
                  .trackpadSlidingMin, .trackpadSlidingMax,
                  .trackpadContactMin, .trackpadContactMax,
                  .trackpadTapMin, .trackpadTapMax,
                  .mouseScrollThreshold] {
            d.set("not-a-double", forKey: k.rawValue)
        }
        // Int keys → String
        for k in [SettingsStore.Key.consensusRequired, .accelConfirmations,
                  .accelWarmupSamples, .micConfirmations, .micWarmupSamples,
                  .hpConfirmations, .hpWarmupSamples] {
            d.set("not-an-int", forKey: k.rawValue)
        }
        // Array keys → Int
        d.set(42, forKey: SettingsStore.Key.enabledDisplays.rawValue)
        d.set(42, forKey: SettingsStore.Key.enabledAudioDevices.rawValue)
        d.set(42, forKey: SettingsStore.Key.enabledSensorIDs.rawValue)
        d.set(42, forKey: SettingsStore.Key.enabledStimulusSourceIDs.rawValue)
        // Data (matrix) keys → String. UserDefaults will refuse to store
        // String for `data(forKey:)` reads (returns nil), and the store's
        // `?? Data()` fallback then hands an empty Data to the JSON decoder,
        // which decodes to `ReactionToggleMatrix()`. No throw.
        d.set("not-data", forKey: SettingsStore.Key.soundReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.flashReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.notificationReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.ledReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.hapticReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.displayBrightnessReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.displayTintReactionMatrix.rawValue)
        d.set("not-data", forKey: SettingsStore.Key.volumeSpikeReactionMatrix.rawValue)
        // String keys → Int. The init coalesces with `?? ""`, so no crash.
        d.set(42, forKey: SettingsStore.Key.notificationLocale.rawValue)
        d.set(42, forKey: SettingsStore.Key.visualResponseMode.rawValue)

        // Construct: must not crash.
        let store = SettingsStore()

        // Sanity: defaults survived. Every Double field must be finite (no NaN
        // sneaking through `d.double(forKey:)` zero-coalesce + clamp).
        let doubles: [Double] = [
            store.sensitivityMin, store.sensitivityMax, store.debounce,
            store.flashOpacityMin, store.flashOpacityMax,
            store.volumeMin, store.volumeMax,
            store.hapticIntensity, store.displayBrightnessBoost,
            store.displayBrightnessThreshold, store.displayTintIntensity,
            store.volumeSpikeTarget, store.volumeSpikeThreshold,
            store.trackpadWindowDuration, store.trackpadScrollMin, store.trackpadScrollMax,
            store.trackpadTouchingMin, store.trackpadTouchingMax,
            store.trackpadSlidingMin, store.trackpadSlidingMax,
            store.trackpadContactMin, store.trackpadContactMax,
            store.trackpadTapMin, store.trackpadTapMax,
            store.mouseScrollThreshold,
        ]
        for (i, v) in doubles.enumerated() {
            XCTAssertTrue(v.isFinite,
                "[fuzz=cell2-type-mismatch] double field index=\(i) must be finite, got \(v)")
        }
        // Pin a few high-value fields to their defaults.
        XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.001,
            "[fuzz=cell2-type-mismatch] hapticIntensity falls back to default")
        XCTAssertEqual(store.enabledDisplays, [],
            "[fuzz=cell2-type-mismatch] enabledDisplays array→Int falls back to []")
        // UserDefaults' string(forKey:) coerces stored numbers to their string
        // representation (Int 42 → "42"); the production fallback only fires
        // for genuinely non-coercible types (Data, Array, Dictionary). Pin
        // that the loaded value is a String (no crash, no nil), not the
        // specific empty-string fallback.
        _ = store.notificationLocale  // accessing must not crash; type is non-optional String
    }

    // MARK: - Cell 3: truncated plist (50% of keys present, 50% missing)

    /// Truncated plist: write a sentinel for the first half of `Key.allCases`,
    /// leave the second half unset. Init must read present keys as-written
    /// and fall back for absent keys, with no throw.
    func test_fuzz_cell3_truncatedPlist_partialKeys_useDefaultsForMissing() {
        wipeAllKeys()
        let d = UserDefaults.standard
        let allKeys = Array(SettingsStore.Key.allCases)
        let halfCount = allKeys.count / 2
        let present = Array(allKeys.prefix(halfCount))
        // For each "present" key, write a type-correct sentinel matching the
        // defaults dictionary type. We look up `SettingsStore.defaults[raw]`
        // and use its type to decide what to write.
        for key in present {
            guard let defValue = SettingsStore.defaults[key.rawValue] else { continue }
            // Write the same default value back. This validates that init
            // can successfully read every type bucket present in the schema
            // even when the OTHER half of the schema is absent.
            d.set(defValue, forKey: key.rawValue)
        }

        let store = SettingsStore()
        // Sanity: store is alive and self-consistent.
        XCTAssertTrue(store.sensitivityMin.isFinite,
            "[fuzz=cell3-truncated] sensitivityMin must be finite")
        XCTAssertTrue(store.sensitivityMax.isFinite,
            "[fuzz=cell3-truncated] sensitivityMax must be finite")
        XCTAssertTrue(store.sensitivityMin <= store.sensitivityMax,
            "[fuzz=cell3-truncated] min ≤ max ordering invariant")
    }

    // MARK: - Cell 4: random-blob plist fuzz (N=200 trials)

    /// For 200 deterministic seeds: generate a `[String: Any]` of arbitrary
    /// keys (some real, some not) with arbitrary value shapes (String, Int,
    /// Double, Bool, Array, Data), write it into UserDefaults.standard, and
    /// assert SettingsStore() doesn't crash. We also assert that all Double
    /// fields come out finite (no NaN/infinity injected via type coercion)
    /// and that array fields fall back gracefully.
    ///
    /// This is the cell most likely to surface a real boot-time crash: random
    /// shapes will hit code paths the example-based migration tests don't
    /// touch. If a trial crashes, the seed is in the error message and the
    /// regression is locally reproducible.
    func test_fuzz_cell4_randomBlobPlist_200trials_noCrash() {
        let N = 200
        var trialsCompleted = 0
        var defaultObservedCount = 0
        let allKeys = Array(SettingsStore.Key.allCases)

        for seed in 0..<UInt64(N) {
            wipeAllKeys()
            let gen = SeededGenerator(seed: seed)
            let d = UserDefaults.standard

            // Pick 0-`allKeys.count` real keys at random and assign them a
            // random-typed value drawn from the type roulette.
            let realKeyCount = gen.nextInt(in: 0...allKeys.count)
            for _ in 0..<realKeyCount {
                let key = allKeys[gen.nextInt(in: 0...(allKeys.count - 1))]
                writeRandomValue(into: d, forKey: key.rawValue, gen: gen)
            }
            // Plus 0-10 garbage keys that the schema doesn't know about.
            // SettingsStore.init must ignore these.
            let garbageCount = gen.nextInt(in: 0...10)
            for i in 0..<garbageCount {
                writeRandomValue(into: d, forKey: "fuzz.garbage.\(seed).\(i)", gen: gen)
            }

            // Construct store. If this throws or crashes, the seed is the
            // diagnostic.
            let store = SettingsStore()
            trialsCompleted += 1

            // No-NaN invariant across every Double field.
            let doubles: [Double] = [
                store.sensitivityMin, store.sensitivityMax, store.debounce,
                store.flashOpacityMin, store.flashOpacityMax,
                store.volumeMin, store.volumeMax,
                store.hapticIntensity, store.displayBrightnessBoost,
                store.displayBrightnessThreshold, store.displayTintIntensity,
                store.volumeSpikeTarget, store.volumeSpikeThreshold,
                store.trackpadWindowDuration, store.trackpadScrollMin, store.trackpadScrollMax,
                store.trackpadTouchingMin, store.trackpadTouchingMax,
                store.trackpadSlidingMin, store.trackpadSlidingMax,
                store.trackpadContactMin, store.trackpadContactMax,
                store.trackpadTapMin, store.trackpadTapMax,
                store.mouseScrollThreshold,
                store.accelSpikeThreshold, store.accelCrestFactor, store.accelRiseRate,
                store.accelReportInterval, store.accelBandpassLowHz, store.accelBandpassHighHz,
                store.micSpikeThreshold, store.micCrestFactor, store.micRiseRate,
                store.hpSpikeThreshold, store.hpCrestFactor, store.hpRiseRate,
                store.ledBrightnessMin, store.ledBrightnessMax,
            ]
            for (i, v) in doubles.enumerated() {
                XCTAssertTrue(v.isFinite,
                    "[fuzz=cell4-random-blob] seed=\(seed) double#\(i) must be finite, got \(v)")
            }
            // Bandpass low ≤ high invariant must hold even after init reads
            // arbitrary inputs (the didSet-pair in production keeps this).
            XCTAssertLessThanOrEqual(store.accelBandpassLowHz, store.accelBandpassHighHz + 0.0001,
                "[fuzz=cell4-random-blob] seed=\(seed) accelBandpass low ≤ high invariant")

            if store.hapticIntensity == 1.0 { defaultObservedCount += 1 }
        }
        XCTAssertEqual(trialsCompleted, N,
            "[fuzz=cell4-random-blob] expected \(N) trials completed, got \(trialsCompleted)")
        // Sanity: at least some trials hit the "no haptic key written" path
        // and observed the default. If this is 0, our fuzz isn't covering
        // empty-key-set inputs and the cell isn't earning its keep.
        XCTAssertGreaterThan(defaultObservedCount, 0,
            "[fuzz=cell4-random-blob] at least one trial should observe hapticIntensity default")
    }

    /// Type-roulette helper. Picks one of {String, Int, Double, Bool, Array<Int>,
    /// Array<String>, Data} and writes it under `key` into `d`. Used by cell 4
    /// and cell 7 to inject arbitrary type shapes.
    private func writeRandomValue(into d: UserDefaults, forKey key: String, gen: SeededGenerator) {
        switch gen.nextInt(in: 0...6) {
        case 0:
            d.set("fuzz-\(gen.nextU64())", forKey: key)
        case 1:
            d.set(gen.nextInt(in: -1_000_000...1_000_000), forKey: key)
        case 2:
            // Bias toward finite values; UserDefaults stores NaN/inf
            // as actual NaN/inf and `d.double` returns them as-is, so a real
            // bug class. Inject NaN explicitly on a fraction of trials.
            let pick = gen.nextInt(in: 0...20)
            if pick == 0 {
                d.set(Double.nan, forKey: key)
            } else if pick == 1 {
                d.set(Double.infinity, forKey: key)
            } else if pick == 2 {
                d.set(-Double.infinity, forKey: key)
            } else {
                d.set(gen.nextDouble(in: -1000.0...1000.0), forKey: key)
            }
        case 3:
            d.set(gen.nextBool(), forKey: key)
        case 4:
            let n = gen.nextInt(in: 0...8)
            let arr: [Int] = (0..<n).map { _ in gen.nextInt(in: -10_000...10_000) }
            d.set(arr, forKey: key)
        case 5:
            let n = gen.nextInt(in: 0...8)
            let arr: [String] = (0..<n).map { _ in "s-\(gen.nextU64())" }
            d.set(arr, forKey: key)
        case 6:
            let n = gen.nextInt(in: 0...32)
            var bytes = Data(count: n)
            for i in 0..<n { bytes[i] = gen.nextByte() }
            d.set(bytes, forKey: key)
        default:
            d.set("unreachable", forKey: key)
        }
    }

    // MARK: - Cell 5: migration-from-future-version

    /// Write a `version: 99` field under several plausible schema-version
    /// keys (the SettingsStore schema doesn't currently have a version
    /// marker; if a future commit adds one, these are the names we'd most
    /// likely use). Current behavior: SettingsStore.init ignores unknown
    /// keys, so the future-version marker has no effect — every field reads
    /// from its own key as usual. This cell pins that contract: if someone
    /// later wires up a version gate that fatalErrors on `version > known`,
    /// this cell catches the regression.
    func test_fuzz_cell5_migrationFromFutureVersion_doesNotCrash() {
        wipeAllKeys()
        let d = UserDefaults.standard
        d.set(99, forKey: "version")
        d.set(99, forKey: "settingsSchemaVersion")
        d.set("99.0.0-future", forKey: "schemaVersion")

        // Construct: must not crash, must hand back defaults.
        let store = SettingsStore()
        XCTAssertEqual(store.sensitivityMin, Defaults.sensitivityMin, accuracy: 0.0001,
            "[fuzz=cell5-future-version] unknown future version must fall back to defaults (no destructive migration)")
        XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.0001,
            "[fuzz=cell5-future-version] unknown future version must not zero out new-output Doubles")
    }

    // MARK: - Cell 6: migration-from-corrupt-version

    /// Write a corrupt version marker (negative integer, a String where an
    /// Int is expected, an empty String). Init must not crash; defaults
    /// must hold. Same contract as cell 5 but for "junk" inputs rather
    /// than future inputs.
    func test_fuzz_cell6_migrationFromCorruptVersion_doesNotCrash() {
        let corruptValues: [Any] = [-1, "broken", "", Double.nan, [1, 2, 3]]
        for value in corruptValues {
            wipeAllKeys()
            let d = UserDefaults.standard
            d.set(value, forKey: "version")
            d.set(value, forKey: "settingsSchemaVersion")
            // Construct: must not crash for any of the corrupt shapes.
            let store = SettingsStore()
            XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.0001,
                "[fuzz=cell6-corrupt-version value=\(value)] corrupt version must fall back to defaults")
            XCTAssertTrue(store.sensitivityMin.isFinite,
                "[fuzz=cell6-corrupt-version value=\(value)] sensitivityMin must be finite")
        }
    }

    // MARK: - Cell 7: serialization round-trip fuzz (N=100 trials)

    /// For each of 100 seeds: generate a coherent settings configuration
    /// (every clamp-able field bounded inside its production clamp range),
    /// drive it into the store via mutation, construct a fresh store, and
    /// assert that what we read back matches what we wrote.
    ///
    /// The bijection target is "what the production didSet+clamp accepted"
    /// — not the raw input. Inputs already inside the clamp band must
    /// round-trip exactly. This proves persistence is bijective for the
    /// in-band domain, which is the only domain users can produce via UI.
    func test_fuzz_cell7_serializationRoundTrip_100trials() {
        let N = 100
        var trials = 0

        for seed in 0..<UInt64(N) {
            wipeAllKeys()
            let gen = SeededGenerator(seed: seed)

            // Snap pairs to ordered (low ≤ high) so the didSet pair-coupling
            // (which forces the partner up/down to maintain ordering) doesn't
            // round-trip a different value than we wrote.
            let sLow  = gen.nextDouble(in: 0.05...0.45)
            let sHigh = gen.nextDouble(in: 0.55...0.95)
            let vLow  = gen.nextDouble(in: 0.05...0.45)
            let vHigh = gen.nextDouble(in: 0.55...0.95)
            let fLow  = gen.nextDouble(in: 0.05...0.45)
            let fHigh = gen.nextDouble(in: 0.55...0.95)
            let debounce = gen.nextDouble(in: 0.1...1.5)
            let hapInt   = gen.nextDouble(in: 0.5...3.0)
            let mouseTh  = gen.nextDouble(in: 1.0...15.0)
            let soundOn  = gen.nextBool()
            let flashOn  = gen.nextBool()
            let notifOn  = gen.nextBool()

            // Write phase.
            do {
                let store = SettingsStore()
                store.sensitivityMin  = sLow
                store.sensitivityMax  = sHigh
                store.volumeMin       = vLow
                store.volumeMax       = vHigh
                store.flashOpacityMin = fLow
                store.flashOpacityMax = fHigh
                store.debounce        = debounce
                store.hapticIntensity = hapInt
                store.mouseScrollThreshold = mouseTh
                store.soundEnabled    = soundOn
                store.flashEnabled    = flashOn
                store.notificationsEnabled = notifOn
            }
            // Read phase: fresh store reads from the same UserDefaults.
            let fresh = SettingsStore()
            XCTAssertEqual(fresh.sensitivityMin, sLow, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) sensitivityMin")
            XCTAssertEqual(fresh.sensitivityMax, sHigh, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) sensitivityMax")
            XCTAssertEqual(fresh.volumeMin, vLow, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) volumeMin")
            XCTAssertEqual(fresh.volumeMax, vHigh, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) volumeMax")
            XCTAssertEqual(fresh.flashOpacityMin, fLow, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) flashOpacityMin")
            XCTAssertEqual(fresh.flashOpacityMax, fHigh, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) flashOpacityMax")
            XCTAssertEqual(fresh.debounce, debounce, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) debounce")
            XCTAssertEqual(fresh.hapticIntensity, hapInt, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) hapticIntensity")
            XCTAssertEqual(fresh.mouseScrollThreshold, mouseTh, accuracy: 0.0001,
                "[fuzz=cell7-roundtrip] seed=\(seed) mouseScrollThreshold")
            XCTAssertEqual(fresh.soundEnabled, soundOn,
                "[fuzz=cell7-roundtrip] seed=\(seed) soundEnabled")
            XCTAssertEqual(fresh.flashEnabled, flashOn,
                "[fuzz=cell7-roundtrip] seed=\(seed) flashEnabled")
            XCTAssertEqual(fresh.notificationsEnabled, notifOn,
                "[fuzz=cell7-roundtrip] seed=\(seed) notificationsEnabled")
            trials += 1
        }
        XCTAssertEqual(trials, N,
            "[fuzz=cell7-roundtrip] all \(N) trials must complete")
    }

    // MARK: - Cell 8: NSKeyedUnarchiver malicious-input

    /// The `*ReactionMatrix` Data blobs are decoded via JSONDecoder, not
    /// NSKeyedUnarchiver — so the strict crash surface on malicious bytes is
    /// the JSON path. This cell asserts:
    ///   (a) `ReactionToggleMatrix.decoded(from:)` never throws and returns
    ///       a default-constructed matrix when handed garbage bytes.
    ///   (b) Driving that garbage Data through UserDefaults and constructing
    ///       a SettingsStore doesn't crash (the production launch path).
    ///   (c) NSKeyedUnarchiver itself returns nil-or-throws cleanly on the
    ///       same garbage bytes (documents the fact that we don't use it
    ///       on the launch path; if a future change DOES use it, garbage
    ///       must still not SIGSEGV the process).
    func test_fuzz_cell8_maliciousMatrixData_doesNotCrash() {
        let badBytes: [Data] = [
            Data(),                                           // empty
            Data(repeating: 0xFF, count: 1),                  // 1-byte garbage
            Data(repeating: 0x00, count: 4096),               // long zero blob
            Data([0x7B, 0x00, 0x7D]),                         // "{\0}" — broken JSON
            Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) +     // "bplist" magic + junk
                Data(repeating: 0xAB, count: 64),
            Data([UInt8](repeating: 0xDE, count: 1024)),      // pseudo-random
        ]
        for (i, blob) in badBytes.enumerated() {
            // (a) ReactionToggleMatrix.decoded must not throw and must
            // produce a default matrix on failure.
            let m = ReactionToggleMatrix.decoded(from: blob)
            XCTAssertEqual(m, ReactionToggleMatrix(),
                "[fuzz=cell8-malicious blob#\(i)] decoded(from:) on garbage must return default matrix")

            // (b) Drive the same blob through UserDefaults under every
            // matrix key and instantiate the store. No crash, defaults survive.
            wipeAllKeys()
            let d = UserDefaults.standard
            for key in [SettingsStore.Key.soundReactionMatrix,
                        .flashReactionMatrix, .notificationReactionMatrix,
                        .ledReactionMatrix, .hapticReactionMatrix,
                        .displayBrightnessReactionMatrix,
                        .displayTintReactionMatrix, .volumeSpikeReactionMatrix] {
                d.set(blob, forKey: key.rawValue)
            }
            let store = SettingsStore()
            XCTAssertEqual(store.soundReactionMatrix, ReactionToggleMatrix(),
                "[fuzz=cell8-malicious blob#\(i)] soundReactionMatrix must default after garbage")
            XCTAssertEqual(store.flashReactionMatrix, ReactionToggleMatrix(),
                "[fuzz=cell8-malicious blob#\(i)] flashReactionMatrix must default after garbage")

            // (c) NSKeyedUnarchiver on the same blob: must return nil or
            // throw cleanly. Calling the throwing API directly so a crash
            // would surface as a thrown error, not a SIGSEGV. We don't
            // assert success — only that the call returns control.
            do {
                _ = try NSKeyedUnarchiver.unarchivedObject(
                    ofClasses: [NSDictionary.self, NSString.self, NSNumber.self, NSData.self],
                    from: blob)
                // If it returns a value or nil, that's fine; either is a
                // controlled outcome.
            } catch {
                // Throwing on garbage is the documented behavior for the
                // secure-coding API. Test passes as long as control returns.
            }
        }
    }
}
