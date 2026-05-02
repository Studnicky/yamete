import XCTest
@testable import YameteCore
@testable import ResponseKit
@testable import YameteApp

/// Settings → Config translation matrix.
///
/// Every `xConfig()` factory on `SettingsStore` translates one or more
/// `SettingsStore` fields into the corresponding output config struct. A
/// "binding alias" bug occurs when a factory wires the wrong field — e.g.
/// `volumeMin` ends up in `volumeMax`, or a settings update doesn't
/// propagate at all.
///
/// Strategy per cell: assign each settings field a unique sentinel value,
/// call the factory, assert the matching config field equals the sentinel.
/// Then mutate the setting to a second sentinel, re-call the factory, assert
/// the config field updated and that no neighboring fields changed.
@MainActor
final class MatrixSettingsToConfig_Tests: XCTestCase {

    // MARK: - Fresh store fixture

    private func freshStore() -> SettingsStore {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        return SettingsStore()
    }

    // MARK: - Cell descriptors

    /// One sentinel mapping for a Float-valued field on AudioOutputConfig.
    /// Stays as a struct (a "TestCase" record), not a free factory function,
    /// per the "domain-owned methods, no free helpers" rule.
    private struct FloatCell {
        let label: String
        let setA: @MainActor (SettingsStore) -> Void
        let readConfig: @MainActor (SettingsStore) -> Float
        let expectedA: Float
        let setB: @MainActor (SettingsStore) -> Void
        let expectedB: Float
    }

    private struct DoubleCell {
        let label: String
        let setA: @MainActor (SettingsStore) -> Void
        let readConfig: @MainActor (SettingsStore) -> Double
        let expectedA: Double
        let setB: @MainActor (SettingsStore) -> Void
        let expectedB: Double
    }

    private struct BoolCell {
        let label: String
        let setA: @MainActor (SettingsStore) -> Void
        let readConfig: @MainActor (SettingsStore) -> Bool
        let expectedA: Bool
        let setB: @MainActor (SettingsStore) -> Void
        let expectedB: Bool
    }

    // MARK: - Audio config

    func testAudioConfigFieldRoundTrip() {
        // volumeMax must precede volumeMin so the min/max ordering invariant
        // doesn't collapse during step A.
        let cells: [FloatCell] = [
            .init(label: "audio.volumeMax",
                  setA: { $0.volumeMax = 0.91 },
                  readConfig: { $0.audioConfig().volumeMax },
                  expectedA: 0.91,
                  setB: { $0.volumeMax = 0.77 },
                  expectedB: 0.77),
            .init(label: "audio.volumeMin",
                  setA: { $0.volumeMin = 0.13 },
                  readConfig: { $0.audioConfig().volumeMin },
                  expectedA: 0.13,
                  setB: { $0.volumeMin = 0.42 },
                  expectedB: 0.42),
        ]
        runFloatCells(cells)

        // Bool: enabled ↔ soundEnabled
        let boolCells: [BoolCell] = [
            .init(label: "audio.enabled",
                  setA: { $0.soundEnabled = false },
                  readConfig: { $0.audioConfig().enabled },
                  expectedA: false,
                  setB: { $0.soundEnabled = true },
                  expectedB: true),
        ]
        runBoolCells(boolCells)
    }

    /// Prove the binding direction is correct: setting `volumeMin` only
    /// changes `audioConfig().volumeMin`, not `volumeMax`. This catches a
    /// swapped-binding mutation.
    func testAudioConfigVolumeMinIsolation() {
        let store = freshStore()
        store.volumeMin = 0.10
        store.volumeMax = 0.95
        var config = store.audioConfig()
        XCTAssertEqual(config.volumeMin, 0.10, accuracy: 0.001,
            "[audio.volumeMin baseline] expected 0.10, got \(config.volumeMin)")
        XCTAssertEqual(config.volumeMax, 0.95, accuracy: 0.001,
            "[audio.volumeMax baseline] expected 0.95, got \(config.volumeMax)")

        store.volumeMin = 0.50
        config = store.audioConfig()
        XCTAssertEqual(config.volumeMin, 0.50, accuracy: 0.001,
            "[audio.volumeMin update] expected 0.50, got \(config.volumeMin)")
        XCTAssertEqual(config.volumeMax, 0.95, accuracy: 0.001,
            "[audio.volumeMax non-aliased] expected 0.95, got \(config.volumeMax)")
    }

    // MARK: - Flash config

    func testFlashConfigFieldRoundTrip() {
        let floatCells: [FloatCell] = [
            .init(label: "flash.opacityMax",
                  setA: { $0.flashOpacityMax = 0.88 },
                  readConfig: { $0.flashConfig().opacityMax },
                  expectedA: 0.88,
                  setB: { $0.flashOpacityMax = 0.66 },
                  expectedB: 0.66),
            .init(label: "flash.opacityMin",
                  setA: { $0.flashOpacityMin = 0.20 },
                  readConfig: { $0.flashConfig().opacityMin },
                  expectedA: 0.20,
                  setB: { $0.flashOpacityMin = 0.45 },
                  expectedB: 0.45),
        ]
        runFloatCells(floatCells)

        let boolCells: [BoolCell] = [
            .init(label: "flash.enabled",
                  setA: { $0.flashEnabled = false },
                  readConfig: { $0.flashConfig().enabled },
                  expectedA: false,
                  setB: { $0.flashEnabled = true },
                  expectedB: true),
            .init(label: "flash.activeDisplayOnly",
                  setA: { $0.flashActiveDisplayOnly = true },
                  readConfig: { $0.flashConfig().activeDisplayOnly },
                  expectedA: true,
                  setB: { $0.flashActiveDisplayOnly = false },
                  expectedB: false),
        ]
        runBoolCells(boolCells)

        // dismissAfter ← debounce
        let doubleCells: [DoubleCell] = [
            .init(label: "flash.dismissAfter",
                  setA: { $0.debounce = 0.75 },
                  readConfig: { $0.flashConfig().dismissAfter },
                  expectedA: 0.75,
                  setB: { $0.debounce = 1.5 },
                  expectedB: 1.5),
        ]
        runDoubleCells(doubleCells)
    }

    // MARK: - LED config

    func testLEDConfigFieldRoundTrip() {
        let floatCells: [FloatCell] = [
            .init(label: "led.brightnessMax",
                  setA: { $0.ledBrightnessMax = 0.94 },
                  readConfig: { $0.ledConfig().brightnessMax },
                  expectedA: 0.94,
                  setB: { $0.ledBrightnessMax = 0.71 },
                  expectedB: 0.71),
            .init(label: "led.brightnessMin",
                  setA: { $0.ledBrightnessMin = 0.21 },
                  readConfig: { $0.ledConfig().brightnessMin },
                  expectedA: 0.21,
                  setB: { $0.ledBrightnessMin = 0.49 },
                  expectedB: 0.49),
        ]
        runFloatCells(floatCells)

        let boolCells: [BoolCell] = [
            .init(label: "led.enabled",
                  setA: { $0.ledEnabled = true },
                  readConfig: { $0.ledConfig().enabled },
                  expectedA: true,
                  setB: { $0.ledEnabled = false },
                  expectedB: false),
            .init(label: "led.keyboardBrightnessEnabled",
                  setA: { $0.keyboardBrightnessEnabled = true },
                  readConfig: { $0.ledConfig().keyboardBrightnessEnabled },
                  expectedA: true,
                  setB: { $0.keyboardBrightnessEnabled = false },
                  expectedB: false),
        ]
        runBoolCells(boolCells)
    }

    // MARK: - Notification config

    func testNotificationConfigFieldRoundTrip() {
        // Note: setting `notificationsEnabled = true` invokes
        // `NotificationResponder.requestAuthorizationIfNeeded()` via the didSet
        // side-effect, which spawns a detached Task that touches
        // UNUserNotificationCenter. In the SPM xctest harness, the user-
        // notifications center cannot resolve a bundle and asynchronously
        // crashes. We therefore drive the `enabled` binding through
        // UserDefaults + a freshly re-instantiated store, which bypasses the
        // didSet side-effect (init reads `d.bool(forKey:)` directly).
        UserDefaults.standard.set(true, forKey: SettingsStore.Key.notificationsEnabled.rawValue)
        let storeOn = SettingsStore()
        XCTAssertEqual(storeOn.notificationConfig().enabled, true,
            "[notification.enabled=true] expected true, got \(storeOn.notificationConfig().enabled)")

        UserDefaults.standard.set(false, forKey: SettingsStore.Key.notificationsEnabled.rawValue)
        let storeOff = SettingsStore()
        XCTAssertEqual(storeOff.notificationConfig().enabled, false,
            "[notification.enabled=false] expected false, got \(storeOff.notificationConfig().enabled)")

        let store = freshStore()
        // dismissAfter ← max(0.5, debounce)
        store.debounce = 1.25
        XCTAssertEqual(store.notificationConfig().dismissAfter, 1.25, accuracy: 0.001,
            "[notification.dismissAfter debounce=1.25] expected 1.25, got \(store.notificationConfig().dismissAfter)")
        store.debounce = 0.10  // below floor → clamp logic, but settingsStore.debounce range is wide
        let dismissAfter = store.notificationConfig().dismissAfter
        XCTAssertGreaterThanOrEqual(dismissAfter, 0.5,
            "[notification.dismissAfter debounce<0.5] expected ≥0.5, got \(dismissAfter)")

        // localeID — empty notificationLocale falls back to system locale.
        store.notificationLocale = "ja"
        XCTAssertEqual(store.notificationConfig().localeID, "ja",
            "[notification.localeID=ja] expected ja, got \(store.notificationConfig().localeID)")
        store.notificationLocale = ""
        XCTAssertFalse(store.notificationConfig().localeID.isEmpty,
            "[notification.localeID empty→system fallback] expected non-empty fallback, got '\(store.notificationConfig().localeID)'")
    }

    // MARK: - Haptic config

    func testHapticConfigFieldRoundTrip() {
        let boolCells: [BoolCell] = [
            .init(label: "haptic.enabled",
                  setA: { $0.hapticEnabled = true },
                  readConfig: { $0.hapticConfig().enabled },
                  expectedA: true,
                  setB: { $0.hapticEnabled = false },
                  expectedB: false),
        ]
        runBoolCells(boolCells)

        let doubleCells: [DoubleCell] = [
            .init(label: "haptic.intensity",
                  setA: { $0.hapticIntensity = 1.5 },
                  readConfig: { $0.hapticConfig().intensity },
                  expectedA: 1.5,
                  setB: { $0.hapticIntensity = 2.5 },
                  expectedB: 2.5),
        ]
        runDoubleCells(doubleCells)
    }

    // MARK: - DisplayBrightness config

    func testDisplayBrightnessConfigFieldRoundTrip() {
        let boolCells: [BoolCell] = [
            .init(label: "displayBrightness.enabled",
                  setA: { $0.displayBrightnessEnabled = true },
                  readConfig: { $0.displayBrightnessConfig().enabled },
                  expectedA: true,
                  setB: { $0.displayBrightnessEnabled = false },
                  expectedB: false),
        ]
        runBoolCells(boolCells)

        let doubleCells: [DoubleCell] = [
            .init(label: "displayBrightness.boost",
                  setA: { $0.displayBrightnessBoost = 0.30 },
                  readConfig: { $0.displayBrightnessConfig().boost },
                  expectedA: 0.30,
                  setB: { $0.displayBrightnessBoost = 0.85 },
                  expectedB: 0.85),
            .init(label: "displayBrightness.threshold",
                  setA: { $0.displayBrightnessThreshold = 0.20 },
                  readConfig: { $0.displayBrightnessConfig().threshold },
                  expectedA: 0.20,
                  setB: { $0.displayBrightnessThreshold = 0.55 },
                  expectedB: 0.55),
        ]
        runDoubleCells(doubleCells)
    }

    // MARK: - DisplayTint config

    func testDisplayTintConfigFieldRoundTrip() {
        let boolCells: [BoolCell] = [
            .init(label: "displayTint.enabled",
                  setA: { $0.displayTintEnabled = true },
                  readConfig: { $0.displayTintConfig().enabled },
                  expectedA: true,
                  setB: { $0.displayTintEnabled = false },
                  expectedB: false),
        ]
        runBoolCells(boolCells)

        let doubleCells: [DoubleCell] = [
            .init(label: "displayTint.intensity",
                  setA: { $0.displayTintIntensity = 0.20 },
                  readConfig: { $0.displayTintConfig().intensity },
                  expectedA: 0.20,
                  setB: { $0.displayTintIntensity = 0.65 },
                  expectedB: 0.65),
        ]
        runDoubleCells(doubleCells)
    }

    // MARK: - VolumeSpike config

    func testVolumeSpikeConfigFieldRoundTrip() {
        let boolCells: [BoolCell] = [
            .init(label: "volumeSpike.enabled",
                  setA: { $0.volumeSpikeEnabled = true },
                  readConfig: { $0.volumeSpikeConfig().enabled },
                  expectedA: true,
                  setB: { $0.volumeSpikeEnabled = false },
                  expectedB: false),
        ]
        runBoolCells(boolCells)

        let doubleCells: [DoubleCell] = [
            .init(label: "volumeSpike.targetVolume",
                  setA: { $0.volumeSpikeTarget = 0.65 },
                  readConfig: { $0.volumeSpikeConfig().targetVolume },
                  expectedA: 0.65,
                  setB: { $0.volumeSpikeTarget = 0.95 },
                  expectedB: 0.95),
            .init(label: "volumeSpike.threshold",
                  setA: { $0.volumeSpikeThreshold = 0.25 },
                  readConfig: { $0.volumeSpikeConfig().threshold },
                  expectedA: 0.25,
                  setB: { $0.volumeSpikeThreshold = 0.80 },
                  expectedB: 0.80),
        ]
        runDoubleCells(doubleCells)
    }

    // MARK: - Trackpad source config

    func testTrackpadSourceConfigFieldRoundTrip() {
        let doubleCells: [DoubleCell] = [
            .init(label: "trackpad.windowDuration",
                  setA: { $0.trackpadWindowDuration = 2.0 },
                  readConfig: { $0.trackpadSourceConfig().windowDuration },
                  expectedA: 2.0,
                  setB: { $0.trackpadWindowDuration = 3.5 },
                  expectedB: 3.5),
            .init(label: "trackpad.scrollMin",
                  setA: { $0.trackpadScrollMin = 0.05 },
                  readConfig: { $0.trackpadSourceConfig().scrollMin },
                  expectedA: 0.05,
                  setB: { $0.trackpadScrollMin = 0.25 },
                  expectedB: 0.25),
            .init(label: "trackpad.scrollMax",
                  setA: { $0.trackpadScrollMax = 0.85 },
                  readConfig: { $0.trackpadSourceConfig().scrollMax },
                  expectedA: 0.85,
                  setB: { $0.trackpadScrollMax = 0.55 },
                  expectedB: 0.55),
            .init(label: "trackpad.contactMax",
                  setA: { $0.trackpadContactMax = 4.0 },
                  readConfig: { $0.trackpadSourceConfig().contactMax },
                  expectedA: 4.0,
                  setB: { $0.trackpadContactMax = 6.0 },
                  expectedB: 6.0),
            .init(label: "trackpad.contactMin",
                  setA: { $0.trackpadContactMin = 0.7 },
                  readConfig: { $0.trackpadSourceConfig().contactMin },
                  expectedA: 0.7,
                  setB: { $0.trackpadContactMin = 1.5 },
                  expectedB: 1.5),
            .init(label: "trackpad.tapMax",
                  setA: { $0.trackpadTapMax = 8.0 },
                  readConfig: { $0.trackpadSourceConfig().tapMax },
                  expectedA: 8.0,
                  setB: { $0.trackpadTapMax = 12.0 },
                  expectedB: 12.0),
            .init(label: "trackpad.tapMin",
                  setA: { $0.trackpadTapMin = 1.5 },
                  readConfig: { $0.trackpadSourceConfig().tapMin },
                  expectedA: 1.5,
                  setB: { $0.trackpadTapMin = 4.0 },
                  expectedB: 4.0),
        ]
        runDoubleCells(doubleCells)
    }

    // MARK: - Cross-isolation: setting volumeMin doesn't move opacityMin

    /// Cross-config isolation: a settings field used by ONE factory must not
    /// alter the output of any OTHER factory. Catches a misrouted didSet.
    func testCrossConfigIsolation() {
        let store = freshStore()
        let initialOpacityMin = store.flashConfig().opacityMin
        let initialBrightnessMin = store.ledConfig().brightnessMin
        store.volumeMin = 0.42
        XCTAssertEqual(store.flashConfig().opacityMin, initialOpacityMin, accuracy: 0.001,
            "[volumeMin↛flash.opacityMin] flash should not move when audio changes")
        XCTAssertEqual(store.ledConfig().brightnessMin, initialBrightnessMin, accuracy: 0.001,
            "[volumeMin↛led.brightnessMin] led should not move when audio changes")
    }

    // MARK: - Runners

    private func runFloatCells(_ cells: [FloatCell]) {
        for cell in cells {
            let store = freshStore()
            cell.setA(store)
            let actualA = cell.readConfig(store)
            XCTAssertEqual(actualA, cell.expectedA, accuracy: 0.001,
                "[\(cell.label) phase=A] expected \(cell.expectedA), got \(actualA)")

            cell.setB(store)
            let actualB = cell.readConfig(store)
            XCTAssertEqual(actualB, cell.expectedB, accuracy: 0.001,
                "[\(cell.label) phase=B] expected \(cell.expectedB), got \(actualB)")
        }
    }

    private func runDoubleCells(_ cells: [DoubleCell]) {
        for cell in cells {
            let store = freshStore()
            cell.setA(store)
            let actualA = cell.readConfig(store)
            XCTAssertEqual(actualA, cell.expectedA, accuracy: 0.001,
                "[\(cell.label) phase=A] expected \(cell.expectedA), got \(actualA)")

            cell.setB(store)
            let actualB = cell.readConfig(store)
            XCTAssertEqual(actualB, cell.expectedB, accuracy: 0.001,
                "[\(cell.label) phase=B] expected \(cell.expectedB), got \(actualB)")
        }
    }

    private func runBoolCells(_ cells: [BoolCell]) {
        for cell in cells {
            let store = freshStore()
            cell.setA(store)
            let actualA = cell.readConfig(store)
            XCTAssertEqual(actualA, cell.expectedA,
                "[\(cell.label) phase=A] expected \(cell.expectedA), got \(actualA)")

            cell.setB(store)
            let actualB = cell.readConfig(store)
            XCTAssertEqual(actualB, cell.expectedB,
                "[\(cell.label) phase=B] expected \(cell.expectedB), got \(actualB)")
        }
    }
}
