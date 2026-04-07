import XCTest
@testable import YameteCore

// MARK: - Localization end-to-end tests
//
// Validates that localization resources are loadable, keys resolve to non-empty strings,
// and plural forms via .stringsdict work correctly.
//
// The app bundle resources live in Bundle/Contents/Resources/*.lproj.
// In the test environment, Bundle.main points to the test runner, not the app bundle.
// These tests load the resources bundle directly from the project layout.

final class LocalizationE2ETests: XCTestCase {

    /// Locates the app's resource bundle from the project directory structure.
    /// Returns nil if running in an environment where the bundle path is not accessible.
    private func resourceBundle() -> Bundle? {
        // Walk up from the test binary to find the project root.
        // In SPM test runs, the binary is deep inside .build/. We use an environment
        // variable or fall back to known relative paths.

        // Strategy 1: Direct path from working directory (CI and local swift test)
        let candidates = [
            // From repo root (swift test runs from repo root)
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Bundle/Contents/Resources"),
            // Worktree variant
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // project root
                .appendingPathComponent("Bundle/Contents/Resources"),
        ]

        for candidate in candidates {
            let enPath = candidate.appendingPathComponent("en.lproj/Localizable.strings")
            if FileManager.default.fileExists(atPath: enPath.path) {
                return Bundle(path: candidate.path)
            }
        }
        return nil
    }

    /// Loads the English .lproj bundle for string lookups.
    private func englishBundle() -> Bundle? {
        guard let resources = resourceBundle() else { return nil }
        // The resource bundle itself should have en.lproj available
        if let enPath = resources.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") {
            return Bundle(path: URL(fileURLWithPath: enPath).deletingLastPathComponent().path)
        }
        // Fallback: construct path directly
        let enLprojPath = resources.bundlePath + "/en.lproj"
        if FileManager.default.fileExists(atPath: enLprojPath + "/Localizable.strings") {
            return Bundle(path: enLprojPath)
        }
        return nil
    }

    // MARK: - Bundle discovery

    func testResourceBundleDiscoverable() {
        let bundle = resourceBundle()
        XCTAssertNotNil(bundle, "Should find the app resource bundle at Bundle/Contents/Resources")
    }

    func testEnglishLocalizationExists() {
        guard let bundle = resourceBundle() else {
            XCTFail("Resource bundle not found -- skipping")
            return
        }
        let enStrings = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en")
        XCTAssertNotNil(enStrings, "en.lproj/Localizable.strings should exist")
    }

    // MARK: - Key sample returns non-empty strings

    func testLocalizedStringsAreNonEmpty() {
        guard let enBundle = englishBundle() else {
            XCTFail("English bundle not found -- skipping")
            return
        }

        // Sample of localization keys from the app
        let keys = [
            "setting_reactivity",
            "setting_volume",
            "setting_flash_opacity",
            "setting_cooldown",
            "setting_frequency_band",
            "setting_spike_threshold",
            "setting_crest_factor",
            "setting_rise_rate",
            "setting_confirmations",
            "setting_warmup",
            "setting_report_interval",
            "setting_consensus",
            "section_sensitivity_sensors",
            "section_devices",
            "section_accel_tuning",
            "label_launch_at_login",
            "label_debug_logging",
            "button_quit",
            "status_paused",
            "tier_tap",
            "tier_light",
            "tier_medium",
            "tier_firm",
            "tier_hard",
            "tier_tap_full",
            "tier_light_full",
            "tier_medium_full",
            "tier_firm_full",
            "tier_hard_full",
        ]

        for key in keys {
            let value = NSLocalizedString(key, tableName: "Localizable", bundle: enBundle, comment: "")
            XCTAssertFalse(value.isEmpty, "Key '\(key)' should resolve to a non-empty string")
            XCTAssertNotEqual(value, key, "Key '\(key)' should not return the key itself (missing translation)")
        }
    }

    func testHelpTextKeysAreNonEmpty() {
        guard let enBundle = englishBundle() else {
            XCTFail("English bundle not found -- skipping")
            return
        }

        let helpKeys = [
            "help_reactivity",
            "help_volume",
            "help_flash_opacity",
            "help_cooldown",
            "help_frequency_band",
            "help_spike_threshold",
            "help_crest_factor",
            "help_rise_rate",
            "help_confirmations",
            "help_warmup",
            "help_report_interval",
            "help_consensus",
            "help_flash_displays",
            "help_audio_output",
        ]

        for key in helpKeys {
            let value = NSLocalizedString(key, tableName: "Localizable", bundle: enBundle, comment: "")
            XCTAssertFalse(value.isEmpty, "Help key '\(key)' should resolve to non-empty")
            XCTAssertNotEqual(value, key, "Help key '\(key)' should not return key itself")
        }
    }

    func testUnitFormatKeysAreNonEmpty() {
        guard let enBundle = englishBundle() else {
            XCTFail("English bundle not found -- skipping")
            return
        }

        let unitKeys = [
            "unit_percent",
            "unit_hz",
            "unit_gforce",
            "unit_multiplier",
            "unit_seconds",
            "unit_milliseconds",
        ]

        for key in unitKeys {
            let value = NSLocalizedString(key, tableName: "Localizable", bundle: enBundle, comment: "")
            XCTAssertFalse(value.isEmpty, "Unit key '\(key)' should have a value")
            XCTAssertNotEqual(value, key, "Unit key '\(key)' should not return key itself")
        }
    }

    // MARK: - Plural forms via .stringsdict

    func testPluralFormImpactsToday() {
        guard let enBundle = englishBundle() else {
            XCTFail("English bundle not found -- skipping")
            return
        }

        // Singular
        let singular = String(format: NSLocalizedString("impacts_today", tableName: "Localizable", bundle: enBundle, comment: ""), 1)
        XCTAssertTrue(singular.contains("1"), "Singular should contain the count")
        XCTAssertTrue(singular.lowercased().contains("impact"), "Singular should contain 'impact'")

        // Plural
        let plural = String(format: NSLocalizedString("impacts_today", tableName: "Localizable", bundle: enBundle, comment: ""), 5)
        XCTAssertTrue(plural.contains("5"), "Plural should contain the count")
        XCTAssertTrue(plural.lowercased().contains("impact"), "Plural should contain 'impact'")
    }

    func testPluralFormConsensus() {
        guard let enBundle = englishBundle() else {
            XCTFail("English bundle not found -- skipping")
            return
        }

        let singular = String(format: NSLocalizedString("consensus_format", tableName: "Localizable", bundle: enBundle, comment: ""), 1)
        XCTAssertTrue(singular.contains("1"), "Consensus singular should contain count")
        XCTAssertTrue(singular.lowercased().contains("sensor"), "Consensus singular should contain 'sensor'")

        let plural = String(format: NSLocalizedString("consensus_format", tableName: "Localizable", bundle: enBundle, comment: ""), 3)
        XCTAssertTrue(plural.contains("3"), "Consensus plural should contain count")
        XCTAssertTrue(plural.lowercased().contains("sensor"), "Consensus plural should contain 'sensor'")
    }

    func testPluralFormConfirmations() {
        guard let enBundle = englishBundle() else {
            XCTFail("English bundle not found -- skipping")
            return
        }

        let singular = String(format: NSLocalizedString("confirmations_format", tableName: "Localizable", bundle: enBundle, comment: ""), 1)
        XCTAssertTrue(singular.contains("1"), "Confirmations singular should contain count")
        XCTAssertTrue(singular.lowercased().contains("hit"), "Confirmations singular should contain 'hit'")

        let plural = String(format: NSLocalizedString("confirmations_format", tableName: "Localizable", bundle: enBundle, comment: ""), 5)
        XCTAssertTrue(plural.contains("5"), "Confirmations plural should contain count")
        XCTAssertTrue(plural.lowercased().contains("hit"), "Confirmations plural should contain 'hit'")
    }

    // MARK: - Multiple locale .lproj directories exist

    func testMultipleLocalizationsExist() {
        guard let bundle = resourceBundle() else {
            XCTFail("Resource bundle not found -- skipping")
            return
        }

        // A sample of expected localization directories
        let expectedLocales = ["en", "ja", "de", "fr", "es", "ko", "ru", "it"]

        for locale in expectedLocales {
            let lprojPath = bundle.bundlePath + "/\(locale).lproj"
            XCTAssertTrue(FileManager.default.fileExists(atPath: lprojPath),
                "\(locale).lproj directory should exist")

            let stringsPath = lprojPath + "/Localizable.strings"
            XCTAssertTrue(FileManager.default.fileExists(atPath: stringsPath),
                "\(locale).lproj/Localizable.strings should exist")
        }
    }

    func testNonEnglishLocalizationHasContent() {
        guard let bundle = resourceBundle() else {
            XCTFail("Resource bundle not found -- skipping")
            return
        }

        // Verify Japanese localization has actual translated content
        let jaPath = bundle.bundlePath + "/ja.lproj"
        guard FileManager.default.fileExists(atPath: jaPath) else {
            XCTFail("ja.lproj not found")
            return
        }

        guard let jaBundle = Bundle(path: jaPath) else {
            XCTFail("Could not load ja.lproj bundle")
            return
        }

        let key = "setting_reactivity"
        let jaValue = NSLocalizedString(key, tableName: "Localizable", bundle: jaBundle, comment: "")
        XCTAssertFalse(jaValue.isEmpty, "Japanese translation for '\(key)' should not be empty")
        XCTAssertNotEqual(jaValue, key, "Japanese translation should not return the key itself")
    }
}
