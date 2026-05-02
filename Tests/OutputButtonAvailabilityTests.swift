import XCTest
@testable import YameteCore
@testable import ResponseKit
@testable import YameteApp

/// `outputButtonSpecs` builds the per-kind row of output toggles in the
/// menu bar. Always-on outputs (sound, flash, notification, LED) are
/// followed by hardware-gated outputs (haptic, brightness, tint) only when
/// available. A regression once rendered ALL buttons regardless of the
/// availability flags — users on Macs without Force Touch trackpads saw a
/// haptic button that did nothing. These assertions pin returned-count to
/// the input matrix across every combination.
@MainActor
final class OutputButtonAvailabilityTests: XCTestCase {

    /// Full 2×2×2 cross-product of the three hardware flags. 8 cells.
    func testCountMatchesAvailabilityMatrix() {
        struct Cell: Sendable {
            let haptic: Bool
            let brightness: Bool
            let tint: Bool
            var expected: Int {
                4 + (haptic ? 1 : 0) + (brightness ? 1 : 0) + (tint ? 1 : 0)
            }
        }
        var cells: [Cell] = []
        for h in [true, false] {
            for b in [true, false] {
                for t in [true, false] {
                    cells.append(Cell(haptic: h, brightness: b, tint: t))
                }
            }
        }
        XCTAssertEqual(cells.count, 8, "matrix must be exactly 2×2×2 = 8 combinations")
        for cell in cells {
            let count = StimuliSection.outputButtonCount(
                hapticAvailable: cell.haptic,
                displayBrightnessAvailable: cell.brightness,
                displayTintAvailable: cell.tint
            )
            XCTAssertEqual(count, cell.expected,
                           "haptic=\(cell.haptic) brightness=\(cell.brightness) tint=\(cell.tint): expected \(cell.expected) got \(count)")
        }
    }

    /// All-flags-off is the floor: exactly 4 always-on outputs (sound, flash,
    /// notification, LED). If anyone changes the always-on set, this is the
    /// canary that catches it.
    func testFloorIsFourAlwaysOnButtons() {
        let count = StimuliSection.outputButtonCount(
            hapticAvailable: false,
            displayBrightnessAvailable: false,
            displayTintAvailable: false
        )
        XCTAssertEqual(count, 4)
    }

    /// All-flags-on is the ceiling: 4 + 3 = 7 outputs. Catches a regression
    /// where one of the optional appends was deleted.
    func testCeilingIsSevenButtonsWhenAllAvailable() {
        let count = StimuliSection.outputButtonCount(
            hapticAvailable: true,
            displayBrightnessAvailable: true,
            displayTintAvailable: true
        )
        XCTAssertEqual(count, 7)
    }

    /// Each flag adds exactly one button — flipping flags individually must
    /// step the count by exactly 1. Catches a regression where one flag
    /// accidentally adds two buttons (or zero).
    func testEachFlagContributesExactlyOneButton() {
        let baseline = StimuliSection.outputButtonCount(
            hapticAvailable: false,
            displayBrightnessAvailable: false,
            displayTintAvailable: false
        )
        let withHaptic = StimuliSection.outputButtonCount(
            hapticAvailable: true,
            displayBrightnessAvailable: false,
            displayTintAvailable: false
        )
        let withBrightness = StimuliSection.outputButtonCount(
            hapticAvailable: false,
            displayBrightnessAvailable: true,
            displayTintAvailable: false
        )
        let withTint = StimuliSection.outputButtonCount(
            hapticAvailable: false,
            displayBrightnessAvailable: false,
            displayTintAvailable: true
        )
        XCTAssertEqual(withHaptic - baseline, 1, "haptic flag adds exactly 1 button")
        XCTAssertEqual(withBrightness - baseline, 1, "brightness flag adds exactly 1 button")
        XCTAssertEqual(withTint - baseline, 1, "tint flag adds exactly 1 button")
    }
}
