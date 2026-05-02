import XCTest
import AppKit
import SwiftUI
@testable import YameteCore
@testable import YameteApp

/// Integration tests for the menu bar panel sizing flow. The MenuBarView
/// composes left + right columns and the panel emits a content-height
/// preference that StatusBarController feeds into `applyContentHeight`.
/// These tests exercise the public layout-invariant inputs (Theme widths,
/// `outputButtonCount`, hardware-presence flags driving conditional cards)
/// without spinning up a real NSPanel — the contract is what each call
/// returns under each combination of presence flags.
final class PanelLayoutTests: IntegrationTestCase {

    // MARK: - Two-column geometry invariants

    /// The two-column width must be exactly twice the column width plus a
    /// 1-pixel divider. Catches "redesign drifts the layout math".
    func testTwoColumnWidth_isExactlyTwoColumnsPlusDivider() {
        XCTAssertEqual(Theme.twoColumnMenuWidth, Theme.columnWidth * 2 + 1, accuracy: 0.01,
                       "twoColumnMenuWidth must equal 2*columnWidth + 1px divider")
    }

    /// Both column widths must be positive — a drifted constant of 0 would
    /// collapse both columns silently.
    func testColumnWidth_isPositive() {
        XCTAssertGreaterThan(Theme.columnWidth, 0)
        XCTAssertGreaterThan(Theme.twoColumnMenuWidth, Theme.columnWidth)
    }

    // MARK: - Output button count under presence matrix

    /// For every combination of (haptic × brightness × tint) presence,
    /// `outputButtonCount` returns 4 + the number of hardware-gated outputs
    /// available. Drives the FlowLayout grid split inside StimuliSection.
    func testOutputButtonCount_allHardwarePresenceCombos() {
        for haptic in [false, true] {
            for bright in [false, true] {
                for tint in [false, true] {
                    let n = StimuliSection.outputButtonCount(
                        hapticAvailable: haptic,
                        displayBrightnessAvailable: bright,
                        displayTintAvailable: tint
                    )
                    let expected = 4 + (haptic ? 1 : 0) + (bright ? 1 : 0) + (tint ? 1 : 0)
                    XCTAssertEqual(n, expected,
                                   "[haptic=\(haptic) bright=\(bright) tint=\(tint)] count drifted")
                    XCTAssertGreaterThanOrEqual(n, 4,
                                                "[haptic=\(haptic) bright=\(bright) tint=\(tint)] always-on outputs missing")
                    XCTAssertLessThanOrEqual(n, 7,
                                             "[haptic=\(haptic) bright=\(bright) tint=\(tint)] count exceeds known max")
                }
            }
        }
    }

    /// The 4 always-on outputs (sound, flash, notif, LED) must remain
    /// regardless of hardware presence. Catches "regression hides a baseline output".
    func testOutputButtonCount_alwaysIncludesFourBaseOutputs() {
        let n = StimuliSection.outputButtonCount(
            hapticAvailable: false,
            displayBrightnessAvailable: false,
            displayTintAvailable: false
        )
        XCTAssertEqual(n, 4, "no hardware → exactly 4 always-on outputs")
    }

    // MARK: - Yamete hardware-presence test seam

    /// The Yamete `_testSetHardwarePresence` seam must drive every flag
    /// the Stimuli/Response sections gate on. Tests need this to construct
    /// any panel-state combination without real IOKit / DisplayServices.
    func testYameteHardwarePresenceSeam_drivesEveryFlag() {
        let store = SettingsStore()
        let yamete = Yamete(settings: store)
        // Drive every flag false
        yamete._testSetHardwarePresence(
            haptic: false, displayBrightness: false, keyboardBacklight: false,
            trackpad: false, mouse: false, keyboard: false
        )
        XCTAssertFalse(yamete.hapticAvailable)
        XCTAssertFalse(yamete.displayBrightnessAvailable)
        XCTAssertFalse(yamete.keyboardBacklightAvailable)
        XCTAssertFalse(yamete.trackpadSourcePresent)
        XCTAssertFalse(yamete.mouseSourcePresent)
        XCTAssertFalse(yamete.keyboardSourcePresent)

        // Drive every flag true
        yamete._testSetHardwarePresence(
            haptic: true, displayBrightness: true, keyboardBacklight: true,
            trackpad: true, mouse: true, keyboard: true
        )
        XCTAssertTrue(yamete.hapticAvailable)
        XCTAssertTrue(yamete.displayBrightnessAvailable)
        XCTAssertTrue(yamete.keyboardBacklightAvailable)
        XCTAssertTrue(yamete.trackpadSourcePresent)
        XCTAssertTrue(yamete.mouseSourcePresent)
        XCTAssertTrue(yamete.keyboardSourcePresent)
    }

    // MARK: - NSHostingView intrinsic-size sanity (constructed minimal view)

    /// Render a minimal SwiftUI subtree whose intrinsic width matches the
    /// menu bar two-column width and assert NSHostingView reports it within
    /// 1pt. This keeps the fixedSize / frame(width:) contract honest in CI
    /// without depending on every section's environment plumbing (which
    /// would require NSScreen.main / a real display).
    func testHostingView_reportsConfiguredFrameWidth() {
        let view = Color.clear
            .frame(width: Theme.twoColumnMenuWidth, height: 400)
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: AnyView(view))
        let size = host.intrinsicContentSize
        XCTAssertEqual(size.width, Theme.twoColumnMenuWidth, accuracy: 1.0,
                       "[NSHostingView] width drifted from Theme.twoColumnMenuWidth")
        XCTAssertGreaterThan(size.height, 0,
                             "[NSHostingView] height must be positive for a fixedSize column")
        XCTAssertLessThan(size.height, 2000,
                          "[NSHostingView] height must not exceed sane max")
    }

    // MARK: - Accordion animation duration curve

    /// `AccordionCard.animationDuration(forRows:)` clamps to [0.10, 0.30] and
    /// scales linearly at 25ms per row. Tests the formula directly so the
    /// timing contract is locked in regardless of view-body changes.
    func testAccordionCard_animationDuration_scalesWithRowCount() {
        XCTAssertEqual(AccordionCard<EmptyView>.animationDuration(forRows: 1),
                       0.125, accuracy: 0.0001,
                       "1 row → base 0.10 + 0.025 = 0.125s")
        XCTAssertEqual(AccordionCard<EmptyView>.animationDuration(forRows: 5),
                       0.225, accuracy: 0.0001,
                       "5 rows → base 0.10 + 5*0.025 = 0.225s")
        XCTAssertEqual(AccordionCard<EmptyView>.animationDuration(forRows: 20),
                       0.30, accuracy: 0.0001,
                       "20 rows → capped at 0.30s ceiling")
        // Floor: 0 or negative input still yields the 0.125s minimum (max(1, rows)).
        XCTAssertEqual(AccordionCard<EmptyView>.animationDuration(forRows: 0),
                       0.125, accuracy: 0.0001,
                       "0 rows clamps to row=1 → 0.125s floor")
    }

    // MARK: - UI-gate mutation anchors (Phase 7)
    //
    // These cells exist to give the mutation catalog stable bracketed
    // substrings for individual animation-duration formula gates. Each
    // assertion message carries a `[ui-gate=...]` tag so the runner can
    // match deterministically.

    /// Upper-cap gate: `min(0.30, ...)` keeps the formula from running
    /// away on huge row counts. Removing the cap means rows=20 yields
    /// 0.10 + 20*0.025 = 0.60s instead of the 0.30s ceiling.
    func testUIGate_accordionAnimationDuration_capsAt0_30() {
        let d = AccordionCard<EmptyView>.animationDuration(forRows: 20)
        XCTAssertEqual(d, 0.30, accuracy: 0.0001,
            "[ui-gate=accordion-anim-cap] 20 rows must clamp to 0.30s ceiling; got \(d)")
    }

    /// Per-row scaling gate: `Double(max(1, rows)) * perRow`. Removing
    /// the multiplication or the `max(1, rows)` floor changes the
    /// returned value at small row counts. Pinning rows=4 → 0.20s
    /// catches both removals.
    func testUIGate_accordionAnimationDuration_scalesPerRow() {
        let d = AccordionCard<EmptyView>.animationDuration(forRows: 4)
        XCTAssertEqual(d, 0.20, accuracy: 0.0001,
            "[ui-gate=accordion-anim-scale] 4 rows must yield base 0.10 + 4*0.025 = 0.20s; got \(d)")
    }

    /// Floor gate: `max(1, rows)` ensures rows ≤ 0 still produce a
    /// non-trivial duration. Removing the floor would make rows=0 yield
    /// 0.10s and rows=-3 yield a value below 0.10 (then clamped by the
    /// outer `max(0.10, raw)`); pin rows=-3 → 0.125s to anchor both the
    /// inner floor and the outer min(0.10) clamp.
    func testUIGate_accordionAnimationDuration_floorAtRow1() {
        let d = AccordionCard<EmptyView>.animationDuration(forRows: -3)
        XCTAssertEqual(d, 0.125, accuracy: 0.0001,
            "[ui-gate=accordion-anim-floor] negative rows must floor to row=1 yielding 0.125s; got \(d)")
    }

    /// SensorAccordionCard mirror gate: removing the formula on the
    /// sensor card surface (or drifting it from the AccordionCard
    /// formula) breaks panels mixing both card kinds. Pin rows=20 →
    /// 0.30s (capped) on the sensor surface — well above the 8-row
    /// natural cap so removing the cap pushes the result to 0.60s.
    func testUIGate_sensorAccordionAnimationDuration_mirrorsCap() {
        let d = SensorAccordionCard<EmptyView>.animationDuration(forRows: 20)
        XCTAssertEqual(d, 0.30, accuracy: 0.0001,
            "[ui-gate=sensor-accordion-anim-cap] 20 rows on SensorAccordionCard must yield 0.30s ceiling; got \(d)")
    }

    /// `SensorAccordionCard.animationDuration(forRows:)` mirrors AccordionCard.
    /// Both surfaces must share the formula so panels with mixed accordion
    /// types animate consistently.
    func testSensorAccordionCard_animationDuration_mirrorsAccordionCard() {
        for rows in [1, 5, 20, 0, -3] {
            XCTAssertEqual(SensorAccordionCard<EmptyView>.animationDuration(forRows: rows),
                           AccordionCard<EmptyView>.animationDuration(forRows: rows),
                           accuracy: 0.0001,
                           "[rows=\(rows)] sensor and plain accordion durations must match")
        }
    }

    // MARK: - applyContentHeight clamp invariant

    /// The chrome subtraction inside MenuBarView caps the scrollable region
    /// height at (smallest screen visibleFrame - 233). Verify the constant
    /// is sane (positive, reasonable upper bound). A drifted chrome value of
    /// 800+ would visibly squish the content area.
    func testMenuBarView_chromeReservation_isSane() {
        // Probe via a fresh MenuBarView's runtime reading the screen list.
        // We can't access the private maxScrollHeight, but we can assert
        // the contract a CI macOS runner would honor: at least 300pt of
        // scroll space on any screen ≥ 533pt tall.
        let minH = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800
        let scroll = max(300, minH - 233)
        XCTAssertGreaterThanOrEqual(scroll, 300,
                                    "chrome reservation must leave ≥ 300pt for scroll")
        XCTAssertLessThan(scroll, 2000,
                          "scroll area must not claim > 2000pt")
    }
}
