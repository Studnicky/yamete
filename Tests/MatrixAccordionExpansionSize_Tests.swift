import XCTest
import SwiftUI
import AppKit
@testable import YameteCore
@testable import ResponseKit
@testable import YameteApp

/// Accordion expansion size matrix. Bug class: `SensorAccordionCard` adds
/// pixels to the menu bar height even when collapsed (e.g. `if isExpanded`
/// gate is removed); enable-flag toggle erroneously affects height; nested
/// accordions stack non-additively.
///
/// Strategy: render `SensorAccordionCard` instances into an offscreen
/// `NSHostingView`, capture `intrinsicContentSize.height` across cells.
/// Each cell pins (isEnabled, isExpanded) and asserts a contract on the
/// observed height delta. The numeric thresholds tolerate ±5pt jitter from
/// platform-specific font rendering.
@MainActor
final class MatrixAccordionExpansionSize_Tests: XCTestCase {

    // MARK: - Fixture helpers

    /// Renders a SensorAccordionCard at the menu width and returns the
    /// reported intrinsic height after layout.
    private func cardHeight(isEnabled: Bool, isExpanded: Bool, contentRows: Int) -> CGFloat {
        let enabledBinding  = Binding<Bool>.constant(isEnabled)
        let expandedBinding = Binding<Bool>.constant(isExpanded)
        let card = SensorAccordionCard(
            title: "Test",
            icon: "cable.connector",
            isEnabled: enabledBinding,
            isExpanded: expandedBinding,
            help: "Test help"
        ) {
            VStack(spacing: 4) {
                ForEach(0..<contentRows, id: \.self) { idx in
                    Text("row \(idx)").font(.caption)
                }
            }
        }
        let host = NSHostingView(rootView:
            card.frame(width: Theme.columnWidth)
                .fixedSize(horizontal: false, vertical: true)
        )
        host.layoutSubtreeIfNeeded()
        return host.intrinsicContentSize.height
    }

    // MARK: - Cell A: collapsed accordion height bound

    /// A collapsed card must NOT include the body's content height. With
    /// `contentRows = 0` vs `contentRows = 50`, the collapsed cell heights
    /// must be identical — production renders content only `if isExpanded`.
    func testCollapsedHeightIsIndependentOfContentSize() {
        let collapsedSmall = cardHeight(isEnabled: true,  isExpanded: false, contentRows: 0)
        let collapsedLarge = cardHeight(isEnabled: true,  isExpanded: false, contentRows: 50)
        XCTAssertEqual(collapsedSmall, collapsedLarge, accuracy: 1.0,
            "[scenario=collapsed cell=content-rows-changed] " +
            "collapsed accordion height drifted with hidden content; " +
            "small=\(collapsedSmall) large=\(collapsedLarge) — production gate `if isExpanded` likely removed")
    }

    // MARK: - Cell B: expanded grows with content

    /// An expanded card must reflect content height: more rows → taller.
    func testExpandedHeightGrowsWithContent() {
        let expandedSmall = cardHeight(isEnabled: true, isExpanded: true, contentRows: 1)
        let expandedLarge = cardHeight(isEnabled: true, isExpanded: true, contentRows: 8)
        XCTAssertGreaterThan(expandedLarge, expandedSmall,
            "[scenario=expanded cell=content-rows-grew] " +
            "expected expanded height to grow with content; small=\(expandedSmall) large=\(expandedLarge)")
        // Sanity: each extra row adds at least a few points.
        let delta = expandedLarge - expandedSmall
        XCTAssertGreaterThan(delta, 30,
            "[scenario=expanded cell=delta] expected ≥30pt delta for 7 extra rows, got \(delta)")
    }

    // MARK: - Cell C: enable-flag toggle does not change height

    /// Toggling `isEnabled` only changes color/opacity — height must be
    /// identical at both flag values for both collapsed and expanded states.
    func testEnableFlagDoesNotAffectHeight() {
        for isExpanded in [false, true] {
            let onH  = cardHeight(isEnabled: true,  isExpanded: isExpanded, contentRows: 3)
            let offH = cardHeight(isEnabled: false, isExpanded: isExpanded, contentRows: 3)
            XCTAssertEqual(onH, offH, accuracy: 1.0,
                "[scenario=enable-toggle cell=expanded=\(isExpanded)] " +
                "enable flag must not change height; on=\(onH) off=\(offH)")
        }
    }

    // MARK: - Cell D: expand toggle adds content height

    /// Expanding from collapsed to expanded MUST grow the height by
    /// approximately the body's natural height, not a constant or zero.
    func testExpandToggleGrowsHeightByBodySize() {
        let rows = 4
        let collapsed = cardHeight(isEnabled: true, isExpanded: false, contentRows: rows)
        let expanded  = cardHeight(isEnabled: true, isExpanded: true,  contentRows: rows)
        let delta = expanded - collapsed
        XCTAssertGreaterThan(delta, 30,
            "[scenario=expand-toggle cell=rows=\(rows)] expected expanded > collapsed by ≥30pt, got delta=\(delta)")
    }

    // MARK: - Cell E: stacked accordions are additive

    /// Two SensorAccordionCards in a VStack must total approximately the sum
    /// of their individual heights (within stack spacing tolerance).
    func testStackedAccordionsAreAdditive() {
        let one = cardHeight(isEnabled: true, isExpanded: true, contentRows: 3)

        // Render two cards in a stack and capture combined height.
        let stack = VStack(spacing: 0) {
            SensorAccordionCard(
                title: "A", icon: "cable.connector",
                isEnabled: .constant(true), isExpanded: .constant(true),
                help: ""
            ) {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in Text("row \(i)").font(.caption) }
                }
            }
            SensorAccordionCard(
                title: "B", icon: "cable.connector",
                isEnabled: .constant(true), isExpanded: .constant(true),
                help: ""
            ) {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in Text("row \(i)").font(.caption) }
                }
            }
        }
        let host = NSHostingView(rootView:
            stack.frame(width: Theme.columnWidth)
                .fixedSize(horizontal: false, vertical: true)
        )
        host.layoutSubtreeIfNeeded()
        let stacked = host.intrinsicContentSize.height
        // 2× single-card height ± reasonable padding/divider tolerance.
        XCTAssertEqual(stacked, 2 * one, accuracy: 24.0,
            "[scenario=stacked cell=count=2] expected stacked ≈ 2×single (\(2*one)), got \(stacked)")
    }
}
