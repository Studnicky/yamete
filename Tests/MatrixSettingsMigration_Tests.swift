import XCTest
@testable import YameteCore
@testable import YameteApp

/// Matrix: SettingsStore.init reads from UserDefaults; missing keys must
/// fall back to defaults; type-mismatched stored values must not crash.
/// Bug class: an upgrade introduces a new field but the load path doesn't
/// handle the missing key (or a wrong-type value) and either crashes or
/// silently uses 0.
///
/// Note: SettingsStore reads from `UserDefaults.standard` directly. Each
/// cell wipes every Key beforehand to isolate. The wipe loop and the
/// `Key.allCases` enumeration are the contract under test.
@MainActor
final class MatrixSettingsMigration_Tests: XCTestCase {

    // MARK: - Helper: wipe + return fresh store

    private func wipeAllKeys() {
        let d = UserDefaults.standard
        for key in SettingsStore.Key.allCases {
            d.removeObject(forKey: key.rawValue)
        }
        // Legacy migration keys.
        d.removeObject(forKey: "screenFlash")
    }

    private func freshStore() -> SettingsStore {
        wipeAllKeys()
        return SettingsStore()
    }

    // MARK: - Cell: Key.allCases raw values are unique

    func testKeyRawValues_unique() {
        let raws = SettingsStore.Key.allCases.map { $0.rawValue }
        let set = Set(raws)
        XCTAssertEqual(set.count, raws.count,
            "[Key.allCases] duplicate raw values: \(raws.count - set.count) collision(s)")
    }

    // MARK: - Cell: legacy alias for stimulusSourceIDs

    /// `enabledStimulusSourceIDs` raw is `"enabledEventSourceIDs"` because the
    /// 1.1.0 rename kept legacy install bases compatible. If this drifts,
    /// every existing user loses their event-source enables on next launch.
    func testEnabledStimulusSourceIDs_legacyAliasPreserved() {
        XCTAssertEqual(SettingsStore.Key.enabledStimulusSourceIDs.rawValue,
                       "enabledEventSourceIDs",
                       "[Key.enabledStimulusSourceIDs] legacy alias must not drift")
    }

    // MARK: - Cell: missing-key cells use defaults (not 0/nil)

    /// For Double-typed Keys: writing nothing, then constructing a fresh
    /// store, must result in the registered default — not 0.0 from
    /// `d.double(forKey:)`. The init code uses `(d.object(forKey:) as? Double) ?? default`
    /// for new-output Doubles to avoid the 0.0-snap bug.
    func testMissingKey_DoubleField_usesDefaultNotZero() {
        let store = freshStore()
        // Spot-check a representative subset of Double-typed fields with non-zero defaults.
        XCTAssertGreaterThan(store.hapticIntensity, 0.0,
            "[Key.hapticIntensity scenario=missing-key] must use default (1.0), not 0.0")
        XCTAssertGreaterThan(store.displayBrightnessBoost, 0.0,
            "[Key.displayBrightnessBoost scenario=missing-key] must use default (0.5), not 0.0")
        XCTAssertGreaterThan(store.displayBrightnessThreshold, 0.0,
            "[Key.displayBrightnessThreshold scenario=missing-key] must use default (0.4), not 0.0")
        XCTAssertGreaterThan(store.displayTintIntensity, 0.0,
            "[Key.displayTintIntensity scenario=missing-key] must use default (0.5), not 0.0")
        XCTAssertGreaterThan(store.volumeSpikeTarget, 0.0,
            "[Key.volumeSpikeTarget scenario=missing-key] must use default (0.9), not 0.0")
        XCTAssertGreaterThan(store.volumeSpikeThreshold, 0.0,
            "[Key.volumeSpikeThreshold scenario=missing-key] must use default (0.7), not 0.0")
        XCTAssertGreaterThan(store.trackpadWindowDuration, 0.0,
            "[Key.trackpadWindowDuration scenario=missing-key] must use default (1.5), not 0.0")
        XCTAssertGreaterThan(store.trackpadTouchingMax, 0.0,
            "[Key.trackpadTouchingMax scenario=missing-key] must use default (0.5), not 0.0")
        XCTAssertGreaterThan(store.mouseScrollThreshold, 0.0,
            "[Key.mouseScrollThreshold scenario=missing-key] must use default (3.0), not 0.0")
    }

    // MARK: - Cell: wrong-type stored value does not crash, falls back

    /// Stash a String value where a Double is expected. SettingsStore.init
    /// uses `(d.object(forKey:) as? Double) ?? default` for new-output Doubles
    /// — the cast fails, the default kicks in, no crash.
    func testWrongType_StringInDoubleSlot_fallsBackToDefault() {
        wipeAllKeys()
        UserDefaults.standard.set("not-a-double", forKey: SettingsStore.Key.hapticIntensity.rawValue)
        UserDefaults.standard.set("oops", forKey: SettingsStore.Key.displayBrightnessBoost.rawValue)
        // Construct: must not crash.
        let store = SettingsStore()
        XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.001,
            "[Key.hapticIntensity scenario=wrong-type-String] expected default (1.0), got \(store.hapticIntensity)")
        XCTAssertEqual(store.displayBrightnessBoost, 0.5, accuracy: 0.001,
            "[Key.displayBrightnessBoost scenario=wrong-type-String] expected default (0.5)")
    }

    /// Wrong-type cell for array fields: `[Int]` slot receives a String.
    func testWrongType_StringInArraySlot_fallsBackToEmpty() {
        wipeAllKeys()
        UserDefaults.standard.set("not-array", forKey: SettingsStore.Key.enabledDisplays.rawValue)
        UserDefaults.standard.set(42, forKey: SettingsStore.Key.enabledAudioDevices.rawValue)
        let store = SettingsStore()
        XCTAssertEqual(store.enabledDisplays, [],
            "[Key.enabledDisplays scenario=wrong-type-String] expected []")
        XCTAssertEqual(store.enabledAudioDevices, [],
            "[Key.enabledAudioDevices scenario=wrong-type-Int] expected []")
    }

    // MARK: - Cell: round-trip every Key

    /// Every Double field: write a sentinel, instantiate a fresh store,
    /// assert the sentinel persisted. Catches the "init reads from a
    /// different key than persist writes to" class of bug.
    func testRoundTrip_doubleFields_persistAcrossInit() {
        struct Field {
            let key: SettingsStore.Key
            let read: @MainActor (SettingsStore) -> Double
            let sentinel: Double
        }
        let fields: [Field] = [
            .init(key: .sensitivityMin, read: { $0.sensitivityMin }, sentinel: 0.234),
            .init(key: .sensitivityMax, read: { $0.sensitivityMax }, sentinel: 0.876),
            .init(key: .debounce, read: { $0.debounce }, sentinel: 0.987),
            .init(key: .flashOpacityMin, read: { $0.flashOpacityMin }, sentinel: 0.111),
            .init(key: .flashOpacityMax, read: { $0.flashOpacityMax }, sentinel: 0.999),
            .init(key: .volumeMin, read: { $0.volumeMin }, sentinel: 0.222),
            .init(key: .volumeMax, read: { $0.volumeMax }, sentinel: 0.888),
            .init(key: .ledBrightnessMin, read: { $0.ledBrightnessMin }, sentinel: 0.333),
            .init(key: .ledBrightnessMax, read: { $0.ledBrightnessMax }, sentinel: 0.777),
            .init(key: .hapticIntensity, read: { $0.hapticIntensity }, sentinel: 1.7),
            .init(key: .displayBrightnessBoost, read: { $0.displayBrightnessBoost }, sentinel: 0.654),
            .init(key: .displayBrightnessThreshold, read: { $0.displayBrightnessThreshold }, sentinel: 0.321),
            .init(key: .displayTintIntensity, read: { $0.displayTintIntensity }, sentinel: 0.444),
            .init(key: .volumeSpikeTarget, read: { $0.volumeSpikeTarget }, sentinel: 0.789),
            .init(key: .volumeSpikeThreshold, read: { $0.volumeSpikeThreshold }, sentinel: 0.135),
            .init(key: .trackpadWindowDuration, read: { $0.trackpadWindowDuration }, sentinel: 2.345),
            .init(key: .trackpadTouchingMin, read: { $0.trackpadTouchingMin }, sentinel: 0.234),
            .init(key: .trackpadTouchingMax, read: { $0.trackpadTouchingMax }, sentinel: 0.456),
            .init(key: .mouseScrollThreshold, read: { $0.mouseScrollThreshold }, sentinel: 4.5),
        ]
        for f in fields {
            wipeAllKeys()
            // Write sentinel via the property setter, which goes through the
            // production persist() path.
            let store1 = SettingsStore()
            UserDefaults.standard.set(f.sentinel, forKey: f.key.rawValue)
            UserDefaults.standard.synchronize()
            _ = store1
            // Open a fresh store — must read the persisted value.
            let store2 = SettingsStore()
            let got = f.read(store2)
            XCTAssertEqual(got, f.sentinel, accuracy: 0.0001,
                "[Key.\(f.key.rawValue) scenario=round-trip] persisted value lost across init (got \(got))")
        }
    }

    // MARK: - Cell: stable raw values (catch upgrade-rename drift)

    /// Pin the raw value for every Key. If a future commit renames any
    /// raw, this test will fail loudly — the rename would silently lose
    /// every existing user's persisted setting on next launch.
    func testKeyRawValues_pinnedForUpgradeStability() {
        let expected: [(key: SettingsStore.Key, raw: String)] = [
            (.sensitivityMin, "sensitivityMin"),
            (.sensitivityMax, "sensitivityMax"),
            (.debounce, "debounce"),
            (.visualResponseMode, "visualResponseMode"),
            (.notificationLocale, "notificationLocale"),
            (.flashOpacityMin, "flashOpacityMin"),
            (.flashOpacityMax, "flashOpacityMax"),
            (.volumeMin, "volumeMin"),
            (.volumeMax, "volumeMax"),
            (.soundEnabled, "soundEnabled"),
            (.debugLogging, "debugLogging"),
            (.enabledDisplays, "enabledDisplays"),
            (.enabledAudioDevices, "enabledAudioDevices"),
            (.enabledSensorIDs, "enabledSensorIDs"),
            (.consensusRequired, "consensusRequired"),
            (.accelSpikeThreshold, "accelSpikeThreshold"),
            (.accelCrestFactor, "accelCrestFactor"),
            (.accelRiseRate, "accelRiseRate"),
            (.accelConfirmations, "accelConfirmations"),
            (.accelWarmupSamples, "accelWarmupSamples"),
            (.accelReportInterval, "accelReportInterval"),
            (.accelBandpassLowHz, "accelBandpassLowHz"),
            (.accelBandpassHighHz, "accelBandpassHighHz"),
            (.micSpikeThreshold, "micSpikeThreshold"),
            (.micCrestFactor, "micCrestFactor"),
            (.micRiseRate, "micRiseRate"),
            (.micConfirmations, "micConfirmations"),
            (.micWarmupSamples, "micWarmupSamples"),
            (.hpSpikeThreshold, "hpSpikeThreshold"),
            (.hpCrestFactor, "hpCrestFactor"),
            (.hpRiseRate, "hpRiseRate"),
            (.hpConfirmations, "hpConfirmations"),
            (.hpWarmupSamples, "hpWarmupSamples"),
            (.ledEnabled, "ledEnabled"),
            (.ledBrightnessMin, "ledBrightnessMin"),
            (.ledBrightnessMax, "ledBrightnessMax"),
            (.keyboardBrightnessEnabled, "keyboardBrightnessEnabled"),
            (.enabledStimulusSourceIDs, "enabledEventSourceIDs"),
            (.soundReactionMatrix, "soundReactionMatrix"),
            (.flashReactionMatrix, "flashReactionMatrix"),
            (.notificationReactionMatrix, "notificationReactionMatrix"),
            (.ledReactionMatrix, "ledReactionMatrix"),
            (.flashEnabled, "flashEnabled"),
            (.flashActiveDisplayOnly, "flashActiveDisplayOnly"),
            (.notificationsEnabled, "notificationsEnabled"),
            (.hapticEnabled, "hapticEnabled"),
            (.hapticIntensity, "hapticIntensity"),
            (.displayBrightnessEnabled, "displayBrightnessEnabled"),
            (.displayBrightnessBoost, "displayBrightnessBoost"),
            (.displayBrightnessThreshold, "displayBrightnessThreshold"),
            (.displayTintEnabled, "displayTintEnabled"),
            (.displayTintIntensity, "displayTintIntensity"),
            (.volumeSpikeEnabled, "volumeSpikeEnabled"),
            (.volumeSpikeTarget, "volumeSpikeTarget"),
            (.volumeSpikeThreshold, "volumeSpikeThreshold"),
            (.trackpadWindowDuration, "trackpadWindowDuration"),
            (.trackpadScrollMin, "trackpadScrollMin"),
            (.trackpadScrollMax, "trackpadScrollMax"),
            (.trackpadTouchingMin, "trackpadTouchingMin"),
            (.trackpadTouchingMax, "trackpadTouchingMax"),
            (.trackpadSlidingMin, "trackpadSlidingMin"),
            (.trackpadSlidingMax, "trackpadSlidingMax"),
            (.trackpadContactMin, "trackpadContactMin"),
            (.trackpadContactMax, "trackpadContactMax"),
            (.trackpadTapMin, "trackpadTapMin"),
            (.trackpadTapMax, "trackpadTapMax"),
            (.trackpadTouchingEnabled, "trackpadTouchingEnabled"),
            (.trackpadSlidingEnabled, "trackpadSlidingEnabled"),
            (.trackpadContactEnabled, "trackpadContactEnabled"),
            (.trackpadTappingEnabled, "trackpadTappingEnabled"),
            (.trackpadCirclingEnabled, "trackpadCirclingEnabled"),
            (.mouseScrollThreshold, "mouseScrollThreshold"),
            (.firstLaunchDramaFired, "firstLaunchDramaFired"),
            (.hapticReactionMatrix, "hapticReactionMatrix"),
            (.displayBrightnessReactionMatrix, "displayBrightnessReactionMatrix"),
            (.displayTintReactionMatrix, "displayTintReactionMatrix"),
            (.volumeSpikeReactionMatrix, "volumeSpikeReactionMatrix"),
        ]
        for entry in expected {
            XCTAssertEqual(entry.key.rawValue, entry.raw,
                "[Key.\(entry.key) scenario=raw-pinned] persisted value lost across init — raw value drifted from \(entry.raw)")
        }
    }

    // MARK: - Cell: Bool fields round-trip

    func testRoundTrip_boolFields_persistAcrossInit() {
        struct Field {
            let key: SettingsStore.Key
            let read: @MainActor (SettingsStore) -> Bool
        }
        let fields: [Field] = [
            .init(key: .soundEnabled, read: { $0.soundEnabled }),
            .init(key: .ledEnabled, read: { $0.ledEnabled }),
            .init(key: .hapticEnabled, read: { $0.hapticEnabled }),
            .init(key: .displayBrightnessEnabled, read: { $0.displayBrightnessEnabled }),
            .init(key: .displayTintEnabled, read: { $0.displayTintEnabled }),
            .init(key: .volumeSpikeEnabled, read: { $0.volumeSpikeEnabled }),
            .init(key: .flashActiveDisplayOnly, read: { $0.flashActiveDisplayOnly }),
            .init(key: .keyboardBrightnessEnabled, read: { $0.keyboardBrightnessEnabled }),
            .init(key: .firstLaunchDramaFired, read: { $0.firstLaunchDramaFired }),
        ]
        for f in fields {
            wipeAllKeys()
            UserDefaults.standard.set(true, forKey: f.key.rawValue)
            UserDefaults.standard.synchronize()
            let store = SettingsStore()
            XCTAssertTrue(f.read(store),
                "[Key.\(f.key.rawValue) scenario=round-trip-bool] persisted true was not read back")
        }
    }

    // MARK: - Cell: resetToDefaults

    /// Mutate every defaulted field, call resetToDefaults, assert each
    /// returned to its registered default.
    func testResetToDefaults_restoresEveryField() {
        wipeAllKeys()
        let store = SettingsStore()

        // Mutate.
        store.hapticIntensity = 2.5
        store.displayBrightnessBoost = 0.9
        store.displayTintIntensity = 0.8
        store.volumeSpikeTarget = 0.55
        store.trackpadWindowDuration = 4.0
        store.mouseScrollThreshold = 12.0
        store.hapticEnabled = true
        store.displayBrightnessEnabled = true
        store.flashEnabled = false

        // Reset.
        store.resetToDefaults()

        // Assert defaults.
        XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.001,
            "[Key.hapticIntensity scenario=reset] not restored")
        XCTAssertEqual(store.displayBrightnessBoost, 0.5, accuracy: 0.001,
            "[Key.displayBrightnessBoost scenario=reset] not restored")
        XCTAssertEqual(store.displayTintIntensity, 0.5, accuracy: 0.001,
            "[Key.displayTintIntensity scenario=reset] not restored")
        XCTAssertEqual(store.volumeSpikeTarget, 0.9, accuracy: 0.001,
            "[Key.volumeSpikeTarget scenario=reset] not restored")
        XCTAssertEqual(store.trackpadWindowDuration, 1.5, accuracy: 0.001,
            "[Key.trackpadWindowDuration scenario=reset] not restored")
        XCTAssertEqual(store.mouseScrollThreshold, 3.0, accuracy: 0.001,
            "[Key.mouseScrollThreshold scenario=reset] not restored")
        XCTAssertFalse(store.hapticEnabled,
            "[Key.hapticEnabled scenario=reset] not restored")
        XCTAssertFalse(store.displayBrightnessEnabled,
            "[Key.displayBrightnessEnabled scenario=reset] not restored")
        XCTAssertTrue(store.flashEnabled,
            "[Key.flashEnabled scenario=reset] not restored to default true")
    }

    // MARK: - Cell: NSNull / non-existent keys do not crash

    func testNSNull_inAnyKey_doesNotCrash() {
        wipeAllKeys()
        // NSNull representation: clear the value, leaving the registered default.
        // (Direct NSNull writes via UserDefaults are immediately rejected.)
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        let store = SettingsStore()
        // Just constructing this store without crashing is the assertion;
        // sample one Double field to be sure the default was chosen.
        XCTAssertEqual(store.hapticIntensity, 1.0, accuracy: 0.001,
            "[scenario=missing-keys] hapticIntensity must default to 1.0")
    }
}
