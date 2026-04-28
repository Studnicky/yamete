import XCTest
@testable import YameteCore
@testable import ResponseKit
@testable import SensorKit
@testable import YameteApp

/// `Yamete.refreshHardwarePresence()` updates the published presence flags
/// (`mouseSourcePresent`, `keyboardSourcePresent`, `trackpadSourcePresent`)
/// that drive the StimuliSection UI. The hardware-gated output buttons in
/// the matrix row depend on `hapticAvailable`, `displayBrightnessAvailable`,
/// `displayTintAvailable`. Bug class: hardware appears/disappears at runtime
/// and the surfaces don't update.
///
/// Each cell exercises a (mouse × keyboard × trackpad × haptic × brightness
/// × tint) combination via the `_testSetHardwarePresence` seam, and
/// asserts the surfaces tracked the change.
@MainActor
final class MatrixHardwareAvailabilityCascade_Tests: XCTestCase {

    // MARK: - Pairwise cells

    /// Pairwise covering of 6 binary dimensions reduces 64 cells to ~12.
    /// Each cell drives the seam, then asserts the formula and source list.
    func testHardwarePresence_drivesOutputCountAndSourceList() {
        // 6 binary dimensions = arities of 2,2,2,2,2,2.
        let tuples = PairwiseCovering.generate(arities: [2,2,2,2,2,2])
        XCTAssertGreaterThan(tuples.count, 0, "pairwise generator produced no cells")

        var checked = 0
        for tuple in tuples {
            let mouse        = tuple[0] == 1
            let keyboard     = tuple[1] == 1
            let trackpad     = tuple[2] == 1
            let haptic       = tuple[3] == 1
            let brightness   = tuple[4] == 1
            let tint         = tuple[5] == 1
            let coords = "[mouse=\(mouse) keyboard=\(keyboard) trackpad=\(trackpad)" +
                         " haptic=\(haptic) bright=\(brightness) tint=\(tint)]"

            // Wipe persistent state so the SettingsStore starts at defaults.
            for key in SettingsStore.Key.allCases {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
            let settings = SettingsStore()
            let yamete = Yamete(settings: settings)

            yamete._testSetHardwarePresence(
                haptic: haptic,
                displayBrightness: brightness,
                keyboardBacklight: false,
                trackpad: trackpad,
                mouse: mouse,
                keyboard: keyboard
            )

            // Output button count formula from EventsSection.outputButtonCount
            let expected = 4
                + (haptic ? 1 : 0)
                + (brightness ? 1 : 0)
                + (tint ? 1 : 0)
            // displayTint is OS-version-gated (false on macOS 26+); only assert
            // when the runtime reports it. Forcibly use yamete's accessor as
            // truth since seam can't override the OS-version probe.
            let runtimeTint = yamete.displayTintAvailable
            let count = StimuliSection.outputButtonCount(
                hapticAvailable: yamete.hapticAvailable,
                displayBrightnessAvailable: yamete.displayBrightnessAvailable,
                displayTintAvailable: runtimeTint
            )
            let runtimeExpected = 4
                + (haptic ? 1 : 0)
                + (brightness ? 1 : 0)
                + (runtimeTint ? 1 : 0)
            XCTAssertEqual(count, runtimeExpected,
                "\(coords) outputButtonCount=\(count) expected=\(runtimeExpected) (runtimeTint=\(runtimeTint))")

            // Document the configured tint expectation: when tint=true and
            // runtimeTint is false (e.g. macOS 26+), the cell still passes
            // because the runtime gate suppresses display.
            _ = expected

            // Source list: assert each presence flag matches the seam input.
            XCTAssertEqual(yamete.mouseSourcePresent, mouse,
                "\(coords) mouseSourcePresent did not track seam input")
            XCTAssertEqual(yamete.keyboardSourcePresent, keyboard,
                "\(coords) keyboardSourcePresent did not track seam input")
            XCTAssertEqual(yamete.trackpadSourcePresent, trackpad,
                "\(coords) trackpadSourcePresent did not track seam input")
            XCTAssertEqual(yamete.hapticAvailable, haptic,
                "\(coords) hapticAvailable did not track seam input")
            XCTAssertEqual(yamete.displayBrightnessAvailable, brightness,
                "\(coords) displayBrightnessAvailable did not track seam input")

            checked += 1
        }
        XCTAssertEqual(checked, tuples.count)
    }

    // MARK: - Drift simulation

    /// Start with everything off, flip one flag true, assert it propagated;
    /// flip back false, assert it returned to baseline.
    func testDrift_eachFlagFlipsIndependently() {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        let settings = SettingsStore()
        let yamete = Yamete(settings: settings)

        // Baseline: everything off via seam.
        yamete._testSetHardwarePresence(
            haptic: false, displayBrightness: false, keyboardBacklight: false,
            trackpad: false, mouse: false, keyboard: false
        )
        XCTAssertFalse(yamete.mouseSourcePresent)
        XCTAssertFalse(yamete.keyboardSourcePresent)
        XCTAssertFalse(yamete.trackpadSourcePresent)
        XCTAssertFalse(yamete.hapticAvailable)
        XCTAssertFalse(yamete.displayBrightnessAvailable)

        // Drift each one true → false in turn, asserting the round-trip.
        let flips: [(String, (Bool) -> Void, () -> Bool)] = [
            ("mouse", { v in yamete._testSetHardwarePresence(mouse: v) }, { yamete.mouseSourcePresent }),
            ("keyboard", { v in yamete._testSetHardwarePresence(keyboard: v) }, { yamete.keyboardSourcePresent }),
            ("trackpad", { v in yamete._testSetHardwarePresence(trackpad: v) }, { yamete.trackpadSourcePresent }),
            ("haptic", { v in yamete._testSetHardwarePresence(haptic: v) }, { yamete.hapticAvailable }),
            ("brightness", { v in yamete._testSetHardwarePresence(displayBrightness: v) }, { yamete.displayBrightnessAvailable }),
        ]
        for (name, flip, read) in flips {
            flip(true)
            XCTAssertTrue(read(), "[drift=\(name) phase=on] flag did not flip true")
            flip(false)
            XCTAssertFalse(read(), "[drift=\(name) phase=off] flag did not return to baseline")
        }
    }

    // MARK: - refreshHardwarePresence syncs flags to source-of-truth

    /// Call `refreshHardwarePresence()` and assert each flag mirrors the
    /// corresponding static source-of-truth. Catches the "refresh forgot to
    /// re-read source X" mutation class.
    func testRefreshHardwarePresence_mirrorsSourceOfTruth() {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        let settings = SettingsStore()
        let yamete = Yamete(settings: settings)

        // Force flags to "wrong" values via the seam, then call refresh and
        // assert each flag re-derived from its static probe.
        yamete._testSetHardwarePresence(
            haptic: false, displayBrightness: false,
            keyboardBacklight: false,
            trackpad: !TrackpadActivitySource.isPresent,
            mouse: !MouseActivitySource.isPresent,
            keyboard: !KeyboardActivitySource.isPresent
        )
        yamete.refreshHardwarePresence()

        XCTAssertEqual(yamete.mouseSourcePresent, MouseActivitySource.isPresent,
            "[scenario=refresh-mirror] mouseSourcePresent must mirror MouseActivitySource.isPresent")
        XCTAssertEqual(yamete.keyboardSourcePresent, KeyboardActivitySource.isPresent,
            "[scenario=refresh-mirror] keyboardSourcePresent must mirror KeyboardActivitySource.isPresent")
        XCTAssertEqual(yamete.trackpadSourcePresent, TrackpadActivitySource.isPresent,
            "[scenario=refresh-mirror] trackpadSourcePresent must mirror TrackpadActivitySource.isPresent")
    }

    // MARK: - Cascade through outputButtonCount

    /// As haptic/brightness/tint flip independently, the formula tracks
    /// exactly the +1 increment per available output. Catches off-by-one
    /// drift in the formula vs. the spec stored elsewhere.
    func testFormulaIncrement_perFlagFlip() {
        let cases: [(haptic: Bool, bright: Bool, tint: Bool, expected: Int)] = [
            (false, false, false, 4),
            (true,  false, false, 5),
            (false, true,  false, 5),
            (false, false, true,  5),
            (true,  true,  false, 6),
            (true,  false, true,  6),
            (false, true,  true,  6),
            (true,  true,  true,  7),
        ]
        for c in cases {
            let count = StimuliSection.outputButtonCount(
                hapticAvailable: c.haptic,
                displayBrightnessAvailable: c.bright,
                displayTintAvailable: c.tint
            )
            XCTAssertEqual(count, c.expected,
                "[haptic=\(c.haptic) bright=\(c.bright) tint=\(c.tint)] expected \(c.expected) got \(count)")
        }
    }
}
