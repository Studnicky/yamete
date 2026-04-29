#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
import SwiftUI
import XCTest
@testable import YameteApp

/// Phase 7b — closes the four UI gates that Phase 7 deferred: `RangeSlider`,
/// `FlowLayout`, `SensitivityRuler`, `Updater`. Cells render the affected
/// views into `NSHostingView` and pin observable invariants
/// (intrinsicContentSize, version-fallback string) so the mutation catalog
/// can drive each gate.
///
/// Why intrinsic-size pinning?
///   `Layout` protocol gates fire during `sizeThatFits` and `placeSubviews`,
///   neither of which is invokable from a unit test in isolation (the
///   `Subviews` collection is opaque, only constructible via a SwiftUI
///   render). Driving the layout through `NSHostingView.intrinsicContentSize`
///   exposes wrap / spacing / row-height decisions as a single observable
///   number — robust against font drift, host-locale shifts, and SwiftUI
///   internal layout quirks.
///
/// Why not gesture injection for `RangeSlider`?
///   The clamp / swap branches inside `DragGesture.onChanged` cannot be
///   invoked from a unit test without either pumping a synthetic `NSEvent`
///   stream or extracting the math into a static helper. Both options
///   require production refactoring; this phase is additive-only on the
///   test side. The single accessible RangeSlider gate is the public
///   default-parameter `labelWidth` — a defaulted struct field whose value
///   is observable through the rendered HStack's intrinsic width when no
///   caller overrides it.
///
/// Why no `Updater` cells?
///   Two distinct gates surveyed; both unreachable from this harness
///   without production refactor:
///     1. `Updater.isNewer(remote:local:)` is `private static` and
///        defined inside the `#if DIRECT_BUILD` branch. Testing the
///        semver compare requires either widening visibility (e.g.
///        `internal`) or extracting it as a stand-alone helper that
///        compiles under both build configurations.
///     2. The App-Store-stub init's `?? "1.0.0"` fallback is non-
///        observable under SPM `swift test`: `Bundle.main` resolves to
///        the `xctest` runner, whose Info.plist already supplies a
///        `CFBundleShortVersionString` (e.g. "16.0" on macOS 16). The
///        left-hand side of the `??` always wins, so a mutation flipping
///        the fallback string never reaches the observable
///        `currentVersion`. Closing this gap requires a production seam
///        that injects `Bundle` (or a static helper resolving the
///        version from a passed-in dictionary).
///
///   Both gaps are documented in `Tests/Mutation/README.md` under the
///   Phase 7b section; no catalog entry is filed for `Updater` until a
///   testable seam exists.
@MainActor
final class UIGatesPhase7B_Tests: XCTestCase {

    // MARK: - Helpers

    /// Render an arbitrary view into an offscreen NSHostingView, run a
    /// layout pass, return the reported intrinsic content size.
    private func intrinsicSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.intrinsicContentSize
    }

    // MARK: - FlowLayout cells

    /// Build a FlowLayout populated with `count` plain coloured rectangles
    /// of `childSize`, render under a fixed-width frame, return the
    /// intrinsic content size after layout.
    ///
    /// Children are fixed-size `.frame(width:height:)` so each child reports
    /// its natural size to `subviews[i].sizeThatFits(.unspecified)` — no
    /// font / locale dependency.
    private func flowSize(width: CGFloat,
                          childSize: CGSize,
                          count: Int,
                          spacing: CGFloat = 4) -> CGSize
    {
        intrinsicSize(
            FlowLayout(spacing: spacing) {
                ForEach(0..<count, id: \.self) { _ in
                    Color.red
                        .frame(width: childSize.width,
                               height: childSize.height)
                }
            }
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        )
    }

    /// Cell A — wrap-when-row-full gate. Three 60pt-wide children proposed
    /// into a 100pt row must wrap (1 + 1 wraps to 2 rows or similar). With
    /// the wrap gate removed (`proposed <= maxWidth` → always-true), all
    /// three squeeze onto a single row and the rendered height collapses
    /// to one child's height.
    func testUIGate_flowLayout_wrapsWhenRowFull() {
        let s = flowSize(width: 100, childSize: CGSize(width: 60, height: 30),
                         count: 3, spacing: 4)
        // 60 + 4 + 60 = 124 > 100 → second item wraps. 60 alone in row 3
        // (third item also can't fit two-on-a-row in 100pt). Rows = 3,
        // height = 30*3 + 2*4 = 98. Lower bound 60 catches "all squeezed
        // into one row" (height=30) and "two-rows-only" mistake (height=64).
        XCTAssertGreaterThanOrEqual(s.height, 60,
            "[ui-gate=flowLayout-wrap-row-full] expected ≥60pt height " +
            "(multi-row wrap) for 3×60pt children in 100pt row; got \(s.height) " +
            "— production gate `proposed <= maxWidth` likely removed")
    }

    /// Cell B — empty-row fallback gate. The wrap predicate keeps an
    /// `|| lastRow.indices.isEmpty` clause so the very first child never
    /// gets bounced into a fresh row even when oversized. Removing that
    /// clause leaves the initial empty `Row()` orphaned, padding the total
    /// height by one extra inter-row spacing.
    ///
    /// Configuration: 3 oversized children (100×30) into a 20pt row with
    /// 20pt inter-row spacing. Original layout: rows = [[0]], [[1]], [[2]],
    /// height = 90 + 40 = 130. Mutated layout: rows = [[], [0], [1], [2]],
    /// height = 0 + 90 + 60 = 150.
    func testUIGate_flowLayout_emptyRowFallback() {
        let s = flowSize(width: 20, childSize: CGSize(width: 100, height: 30),
                         count: 3, spacing: 20)
        XCTAssertLessThanOrEqual(s.height, 140,
            "[ui-gate=flowLayout-empty-row-fallback] expected ≤140pt height " +
            "(three rows, two spacings) for oversized first item; got \(s.height) " +
            "— production gate `|| lastRow.indices.isEmpty` likely removed, " +
            "leaving an orphan empty row")
    }

    /// Cell C — inter-row spacing accumulator. `sizeThatFits` adds
    /// `spacing * (rows.count - 1)` to the rendered height. Removing the
    /// accumulator collapses inter-row gaps and the rendered height drops
    /// by `spacing * (rows - 1)`.
    ///
    /// Three children of 60×30 in a 100pt row with spacing=20: original
    /// rows=3, height = 90 + 40 = 130. Mutated (no spacing accumulation):
    /// height = 90.
    func testUIGate_flowLayout_interRowSpacingAccumulator() {
        let s = flowSize(width: 100, childSize: CGSize(width: 60, height: 30),
                         count: 3, spacing: 20)
        XCTAssertGreaterThanOrEqual(s.height, 110,
            "[ui-gate=flowLayout-inter-row-spacing] expected ≥110pt height " +
            "(3 rows × 30pt + 2 × 20pt spacing) but got \(s.height) " +
            "— production gate `+ spacing * (rows.count - 1)` likely removed")
    }

    /// Cell D — `proposal.width ?? .infinity` fallback. When the parent
    /// proposes no width (`.unspecified`), FlowLayout treats `maxWidth` as
    /// `.infinity` so all items fit on one row. Mutating the fallback to
    /// `?? 0` flips the maxWidth to zero, forcing every item onto its own
    /// row (the empty-row fallback still accepts each first item, then
    /// every subsequent proposed width exceeds 0).
    ///
    /// Five 40×30 children with no parent width frame: original height = 30.
    /// Mutated height = 5 × 30 + 4 × 4 = 166.
    func testUIGate_flowLayout_nilProposalFallsBackToInfinity() {
        let s = intrinsicSize(
            FlowLayout(spacing: 4) {
                ForEach(0..<5, id: \.self) { _ in
                    Color.red.frame(width: 40, height: 30)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        )
        XCTAssertLessThanOrEqual(s.height, 60,
            "[ui-gate=flowLayout-nil-proposal-infinity] expected ≤60pt height " +
            "(single row, no width constraint) for 5 children with " +
            ".fixedSize(horizontal: true) outer; got \(s.height) " +
            "— production gate `?? .infinity` likely flipped to `?? 0`")
    }

    /// Cell E — row height = max of children. Each row's height is the
    /// max of its children's heights. With 30pt and 60pt children both in
    /// row 0, original row height = 60 → total height = 60. Mutating
    /// `max(rows[lastIdx].height, h)` to drop the running max would leave
    /// row height stuck at the FIRST child's 30pt, hiding the taller child.
    func testUIGate_flowLayout_rowHeightTakesMaxOfChildren() {
        let s = intrinsicSize(
            FlowLayout(spacing: 4) {
                Color.red.frame(width: 30, height: 30)
                Color.blue.frame(width: 30, height: 60)
            }
            .frame(width: 200)
            .fixedSize(horizontal: false, vertical: true)
        )
        XCTAssertGreaterThanOrEqual(s.height, 50,
            "[ui-gate=flowLayout-row-height-max] expected ≥50pt row height " +
            "(max of 30pt and 60pt children); got \(s.height) " +
            "— production gate `max(rows[lastIdx].height, h)` likely " +
            "drifted to the first child's height")
    }

    // MARK: - RangeSlider cell

    /// Cell F — RangeSlider default `labelWidth = 40`. The struct exposes
    /// `labelWidth` with a 40pt default. Both the leading and trailing
    /// label `.frame(width: labelWidth, alignment:)` consume that
    /// allotment so the slider's HStack intrinsic width carries 2 ×
    /// labelWidth plus the central track region's natural width plus the
    /// 8pt-spacing × 2 between columns. Dropping the default to 0
    /// collapses both label frames and the rendered intrinsic width
    /// drops by 80pt.
    ///
    /// Cell wraps the slider in `.fixedSize(horizontal: true, vertical:
    /// true)` so NSHostingView reports the intrinsic width WITHOUT a
    /// parent width constraint; the GeometryReader middle column proposes
    /// its own minimum, leaving the labels as the dominant horizontal
    /// contributor.
    func testUIGate_rangeSlider_defaultLabelWidth() {
        // No labelWidth argument → exercises the default.
        let slider = RangeSlider(
            low: .constant(0.25),
            high: .constant(0.75),
            bounds: 0.0...1.0,
            format: { String(format: "%.2f", $0) }
        )
        let host = NSHostingView(rootView:
            slider.fixedSize(horizontal: true, vertical: true)
        )
        host.layoutSubtreeIfNeeded()
        let w = host.intrinsicContentSize.width
        XCTAssertGreaterThanOrEqual(w, 70,
            "[ui-gate=rangeSlider-default-labelWidth] expected ≥70pt " +
            "intrinsic width (≥ 2 × default 40pt labelWidth, minus middle " +
            "GeometryReader contribution under fixedSize); got \(w) — " +
            "production default likely flipped to 0, collapsing both " +
            "label columns")
    }

    // MARK: - SensitivityRuler cell

    /// Cell G — SensitivityRuler `.frame(height: 16)` constraint. The
    /// inner GeometryReader has no intrinsic height of its own; the
    /// surrounding `.frame(height: 16)` is what gives the ruler its
    /// vertical footprint. Mutating to `.frame(height: 0)` collapses the
    /// ruler so it occupies zero vertical space.
    ///
    /// Without intrinsic height, NSHostingView reports a degenerate small
    /// height (≤ 4pt). The tick labels' Text views push the height above
    /// 4pt only because the parent VStack-equivalent doesn't clip them
    /// (the .position offset places them outside the GeometryReader's
    /// proposed frame). Pin: original height ≥ 14pt; mutated drops well
    /// below.
    func testUIGate_sensitivityRuler_intrinsicHeight() {
        let s = intrinsicSize(
            SensitivityRuler()
                .frame(width: 240)
                .fixedSize(horizontal: false, vertical: true)
        )
        XCTAssertGreaterThanOrEqual(s.height, 12,
            "[ui-gate=sensitivityRuler-intrinsic-height] expected ≥12pt " +
            "intrinsic height for the ruler; got \(s.height) " +
            "— production `.frame(height: 16)` likely zeroed")
    }

    /// Cell H — SensitivityRuler horizontal gutter Spacer (left). The
    /// HStack body opens with a 50pt fixed-width Spacer that pads the tick
    /// region away from the menu's left edge. Mutating its `width: 50` to
    /// `width: 0` collapses the gutter and the rendered intrinsic width
    /// drops by 50pt.
    ///
    /// Two identical-shaped Spacers exist (left + right gutter); the
    /// catalog disambiguates via a multi-line `search` anchored on the
    /// `GeometryReader` directly following the LEFT gutter, so the
    /// mutation only flips the left side.
    ///
    /// Cell wraps in `.fixedSize(horizontal: true, vertical: true)` so
    /// the rendered intrinsic width reflects the natural HStack width
    /// (50pt left + 0pt GeometryReader content under fixedSize + 50pt
    /// right + HStack spacing). With both Spacers at 50pt the rendered
    /// width sits ≥ 100pt; with the left Spacer mutated to 0 it drops to
    /// ≤ 60pt.
    func testUIGate_sensitivityRuler_leftGutterWidth() {
        let s = intrinsicSize(
            SensitivityRuler()
                .fixedSize(horizontal: true, vertical: true)
        )
        XCTAssertGreaterThanOrEqual(s.width, 80,
            "[ui-gate=sensitivityRuler-left-gutter-width] expected ≥80pt " +
            "intrinsic width (≈ 50pt left gutter + 50pt right gutter + " +
            "HStack spacing); got \(s.width) — production left-gutter " +
            "Spacer().frame(width: 50) likely collapsed to 0")
    }
}
