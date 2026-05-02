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

    /// Cell A — balanced row count formula. 5 buttons must split 2+3 with
    /// the smaller row on top so column rails stay aligned. Mutating the
    /// distribution flips the order or collapses the rows.
    func testUIGate_flowLayout_balancedRowCounts() {
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 0, cap: 4), [],
            "[ui-gate=flowLayout-balanced-rowcounts] empty input → empty output")
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 1, cap: 4), [1])
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 4, cap: 4), [4],
            "[ui-gate=flowLayout-balanced-rowcounts] 4 → [4] (single row)")
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 5, cap: 4), [2, 3],
            "[ui-gate=flowLayout-balanced-rowcounts] 5 → [2, 3] (smaller on top)")
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 6, cap: 4), [3, 3])
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 7, cap: 4), [3, 4])
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 8, cap: 4), [4, 4])
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 9, cap: 4), [3, 3, 3])
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 10, cap: 4), [3, 3, 4])
    }

    /// Cell B — row count is ceil(total / cap). Floor-division would
    /// orphan an item (5 buttons → 1 row) or with cap=3 produce 4 buttons
    /// in a single row when 2 rows are required.
    func testUIGate_flowLayout_rowCountCeiling() {
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 5, cap: 4).count, 2,
            "[ui-gate=flowLayout-row-count-ceiling] 5 / 4 = 2 rows")
        XCTAssertEqual(FlowLayout.balancedRowCounts(total: 13, cap: 4).count, 4,
            "[ui-gate=flowLayout-row-count-ceiling] 13 / 4 = 4 rows")
    }

    /// Cell C — total height accumulator includes inter-row spacing.
    /// 5 children of 30pt each in 2 rows with 20pt spacing should report
    /// 30 + 20 + 30 = 80pt of height; dropping the spacing term collapses
    /// to 60pt.
    func testUIGate_flowLayout_totalHeightAccumulator() {
        let s = flowSize(width: 200, childSize: CGSize(width: 30, height: 30),
                         count: 5, spacing: 20)
        XCTAssertGreaterThanOrEqual(s.height, 70,
            "[ui-gate=flowLayout-total-height-accumulator] 2-row layout " +
            "must include inter-row spacing; got \(s.height)")
    }

    /// Cell D — uniform row height. Both rows render at the GLOBAL max
    /// intrinsic height of any subview, not the per-row max. Mixed 30pt
    /// and 60pt children → both rows at 60pt.
    func testUIGate_flowLayout_uniformRowHeightAcrossRows() {
        let s = intrinsicSize(
            FlowLayout(spacing: 4) {
                ForEach(0..<4, id: \.self) { _ in
                    Color.red.frame(width: 30, height: 30)
                }
                Color.blue.frame(width: 30, height: 60)
            }
            .frame(width: 400)
            .fixedSize(horizontal: false, vertical: true)
        )
        XCTAssertGreaterThanOrEqual(s.height, 100,
            "[ui-gate=flowLayout-uniform-row-height] both rows render at " +
            "60pt (global max); expected ≥100pt got \(s.height)")
    }

    /// Cell E — per-row even subdivision respects the proposal width
    /// exactly (the container fills bounds.width). 5 children in a 200pt
    /// frame split 2+3 with uniform 30pt row height → 64pt total.
    func testUIGate_flowLayout_perRowEvenSubdivision() {
        let s = flowSize(width: 200, childSize: CGSize(width: 100, height: 30),
                         count: 5, spacing: 4)
        XCTAssertEqual(s.width, 200, accuracy: 1.0,
            "[ui-gate=flowLayout-per-row-subdivision] width matches proposal")
        XCTAssertEqual(s.height, 64, accuracy: 2.0,
            "[ui-gate=flowLayout-per-row-subdivision] 5 items in 200pt → 64pt total; got \(s.height)")
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

    // MARK: - Phase 7c — production seam closures
    //
    // These cells drive the helpers extracted in Phase 7c directly,
    // bypassing the SwiftUI gesture / render path. Each pins one of the
    // gates that Phase 7b documented as un-pinnable without a production
    // refactor.

    // MARK: RangeSlider clamp / pair-swap

    /// Cell I — `RangeSlider.clamp(position:half:usable:)` clamps an
    /// overshoot-left x-coordinate up to `half`. Mutating the lower bound
    /// (e.g. dropping the `max(half, …)`) lets the position run negative
    /// and downstream value math goes below `bounds.lowerBound`.
    func testUIGate_rangeSlider_clampLowerBound() {
        let clamped = RangeSlider.clamp(position: -50, half: 10, usable: 100)
        XCTAssertEqual(clamped, 10, accuracy: 0.0001,
            "[ui-gate=rangeSlider-clamp-lower-bound] expected x clamped " +
            "up to half=10 for overshoot-left; got \(clamped) — production " +
            "`max(half, x)` clamp likely removed")
    }

    /// Cell J — `RangeSlider.clamp(position:half:usable:)` clamps an
    /// overshoot-right x-coordinate down to `half + usable`. Mutating the
    /// upper bound (e.g. dropping the `min(…, half+usable)`) lets the
    /// position run past the track and downstream value math exceeds
    /// `bounds.upperBound`.
    func testUIGate_rangeSlider_clampUpperBound() {
        let clamped = RangeSlider.clamp(position: 999, half: 10, usable: 100)
        XCTAssertEqual(clamped, 110, accuracy: 0.0001,
            "[ui-gate=rangeSlider-clamp-upper-bound] expected x clamped " +
            "down to half+usable=110 for overshoot-right; got \(clamped) " +
            "— production `min(x, half+usable)` clamp likely removed")
    }

    /// Cell K — `RangeSlider.applyDrag` low→high swap. Dragging the low
    /// thumb past the high thumb must hand control to .high and place
    /// the new value into `high`, not `low`. Mutating the swap branch
    /// (e.g. removing the `value > high` check) leaves low > high — an
    /// invalid invariant.
    func testUIGate_rangeSlider_applyDrag_lowOvershootSwapsToHigh() {
        // Track: half=10, usable=100. User has already grabbed the low
        // thumb (active=.low) and continues dragging right past the
        // high thumb. x=110 → value=1.0 > high=0.5 → swap.
        let result = RangeSlider.applyDrag(
            locationX: 110,
            lowX: 30,    // low at x=30 (~0.2)
            highX: 60,   // high at x=60 (~0.5)
            translationWidth: 80,
            half: 10,
            usable: 100,
            bounds: 0.0...1.0,
            low: 0.2,
            high: 0.5,
            active: .low
        )
        XCTAssertEqual(result.low, 0.5, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-low-overshoot-swap] expected " +
            "low=0.5 (the previous high) after low overshoots; got " +
            "\(result.low) — pair-swap branch likely removed")
        XCTAssertEqual(result.high, 1.0, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-low-overshoot-swap] expected " +
            "high=1.0 (the dragged value); got \(result.high)")
        XCTAssertEqual(result.active, .high,
            "[ui-gate=rangeSlider-applyDrag-low-overshoot-swap] expected " +
            "active to flip to .high after swap; got \(result.active)")
    }

    /// Cell L — `RangeSlider.applyDrag` high→low swap. Dragging the high
    /// thumb past the low thumb must hand control to .low and place the
    /// new value into `low`, not `high`. The mirror of cell K.
    func testUIGate_rangeSlider_applyDrag_highOvershootSwapsToLow() {
        // User has already grabbed the high thumb (active=.high) and
        // continues dragging left past the low thumb. x=10 → value=0.0
        // < low=0.4 → swap.
        let result = RangeSlider.applyDrag(
            locationX: 10,
            lowX: 50,    // low at x=50 (~0.4)
            highX: 90,   // high at x=90 (~0.8)
            translationWidth: -80,
            half: 10,
            usable: 100,
            bounds: 0.0...1.0,
            low: 0.4,
            high: 0.8,
            active: .high
        )
        XCTAssertEqual(result.low, 0.0, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-high-overshoot-swap] expected " +
            "low=0.0 (the dragged value); got \(result.low)")
        XCTAssertEqual(result.high, 0.4, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-high-overshoot-swap] expected " +
            "high=0.4 (the previous low) after high overshoots; got " +
            "\(result.high) — pair-swap branch likely removed")
        XCTAssertEqual(result.active, .low,
            "[ui-gate=rangeSlider-applyDrag-high-overshoot-swap] expected " +
            "active to flip to .low after swap; got \(result.active)")
    }

    /// Cell M — `RangeSlider.applyDrag` overlap-disambiguation: when both
    /// thumb x-positions sit within 2pt of each other, the gesture uses
    /// the drag translation sign to pick which thumb to move. Positive
    /// translation → grab `.high`; negative → grab `.low`. Mutating the
    /// sign comparator flips the behaviour and the wrong thumb takes the
    /// lead.
    ///
    /// Cell decouples the THUMB positions (passed equal at x=60) from the
    /// VALUE pair (low=0.3, high=0.7) so the post-disambiguation switch
    /// arms produce different (low, high) outputs depending on which
    /// thumb the disambiguation picked. If the disambiguation is correct
    /// (.high under positive translation), the .high arm runs and only
    /// `result.high` changes. Under the mutation (.low picked), the .low
    /// arm runs and only `result.low` changes — fully observable in the
    /// returned tuple regardless of any subsequent overshoot-swap.
    func testUIGate_rangeSlider_applyDrag_overlapPicksByTranslation() {
        // Thumb x-positions overlap (lowX == highX == 60), values spread
        // (low=0.3, high=0.7). Drag location x=70 → value=0.6, which
        // sits BETWEEN low and high so neither switch arm fires its
        // overshoot-swap branch — the disambiguation choice survives
        // intact in the returned (low, high) tuple.
        let resultPositive = RangeSlider.applyDrag(
            locationX: 70,
            lowX: 60,
            highX: 60,
            translationWidth: 10,
            half: 10,
            usable: 100,
            bounds: 0.0...1.0,
            low: 0.3,
            high: 0.7,
            active: .none
        )
        // Original: disambiguation picks .high → switch .high → no
        // overshoot (value=0.6 not < low=0.3) → result.high updates
        // to 0.6, result.low stays 0.3.
        XCTAssertEqual(resultPositive.low, 0.3, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-overlap-translation] expected " +
            "result.low=0.3 (unchanged) under positive translation; got " +
            "\(resultPositive.low) — disambiguation picked the wrong thumb")
        XCTAssertEqual(resultPositive.high, 0.6, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-overlap-translation] expected " +
            "result.high=0.6 (updated) under positive translation; got " +
            "\(resultPositive.high) — disambiguation picked the wrong thumb")

        // Mirror with negative translation: original picks .low →
        // switch .low → no overshoot (value=0.4 not > high=0.7) →
        // result.low updates to 0.4, result.high stays 0.7.
        let resultNegative = RangeSlider.applyDrag(
            locationX: 50,
            lowX: 60,
            highX: 60,
            translationWidth: -10,
            half: 10,
            usable: 100,
            bounds: 0.0...1.0,
            low: 0.3,
            high: 0.7,
            active: .none
        )
        XCTAssertEqual(resultNegative.low, 0.4, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-overlap-translation] expected " +
            "result.low=0.4 (updated) under negative translation; got " +
            "\(resultNegative.low) — disambiguation picked the wrong thumb")
        XCTAssertEqual(resultNegative.high, 0.7, accuracy: 0.0001,
            "[ui-gate=rangeSlider-applyDrag-overlap-translation] expected " +
            "result.high=0.7 (unchanged) under negative translation; got " +
            "\(resultNegative.high) — disambiguation picked the wrong thumb")
    }

    // MARK: SensitivityRuler ticks + position

    /// Cell N — `SensitivityRuler.ticks` array length and ordering. The
    /// menu-bar ruler is built around exactly five tier marks; mutating
    /// the array (dropping a tier, reordering, breaking the unit-interval
    /// progression) breaks the visual alignment with the
    /// SettingsStore tier thresholds.
    func testUIGate_sensitivityRuler_ticksArrayShape() {
        let ticks = SensitivityRuler.ticks
        XCTAssertEqual(ticks.count, 5,
            "[ui-gate=sensitivityRuler-ticks-count] expected 5 tier ticks " +
            "(Hard / Firm / Medium / Light / Tap); got \(ticks.count)")
        let positions = ticks.map(\.position)
        XCTAssertEqual(positions, [0.0, 0.25, 0.5, 0.75, 1.0],
            "[ui-gate=sensitivityRuler-ticks-positions] expected " +
            "[0.0, 0.25, 0.5, 0.75, 1.0] (uniform unit-interval " +
            "progression); got \(positions)")
        // First and last must hit the rail bounds exactly so the ruler
        // visually aligns with the slider track endpoints.
        XCTAssertEqual(ticks.first?.position, 0.0,
            "[ui-gate=sensitivityRuler-ticks-positions] first tick must " +
            "anchor at 0.0")
        XCTAssertEqual(ticks.last?.position, 1.0,
            "[ui-gate=sensitivityRuler-ticks-positions] last tick must " +
            "anchor at 1.0")
        // Every position must lie in [0, 1].
        for tick in ticks {
            XCTAssertTrue((0.0...1.0).contains(tick.position),
                "[ui-gate=sensitivityRuler-ticks-positions] tick at " +
                "\(tick.position) outside [0, 1]")
            XCTAssertFalse(tick.label.isEmpty,
                "[ui-gate=sensitivityRuler-ticks-labels] tick at " +
                "\(tick.position) has an empty label")
        }
    }

    /// Cell O — `SensitivityRuler.position(for:in:)` per-tick placement.
    /// Pins the multiplication formula `tick.position * width`. Mutating
    /// to a division or a constant zero collapses every tick to one x.
    func testUIGate_sensitivityRuler_positionFormula() {
        let width = 200.0
        let leftmost = SensitivityRuler.position(
            for: SensitivityRuler.Tick(position: 0.0, label: "L"),
            in: width)
        let middle = SensitivityRuler.position(
            for: SensitivityRuler.Tick(position: 0.5, label: "M"),
            in: width)
        let rightmost = SensitivityRuler.position(
            for: SensitivityRuler.Tick(position: 1.0, label: "R"),
            in: width)
        XCTAssertEqual(leftmost, 0.0, accuracy: 0.0001,
            "[ui-gate=sensitivityRuler-position-formula] expected 0.0 for " +
            "leftmost tick at 0.0×200; got \(leftmost)")
        XCTAssertEqual(middle, 100.0, accuracy: 0.0001,
            "[ui-gate=sensitivityRuler-position-formula] expected 100.0 " +
            "for middle tick at 0.5×200; got \(middle) — production " +
            "`tick.position * w` likely mutated")
        XCTAssertEqual(rightmost, 200.0, accuracy: 0.0001,
            "[ui-gate=sensitivityRuler-position-formula] expected 200.0 " +
            "for rightmost tick at 1.0×200; got \(rightmost)")
    }

    // MARK: Updater — version fallback (App Store + Direct branches)

    /// Cell P — `Updater.currentVersion(bundle:)` fallback string. When
    /// the supplied bundle's `infoDictionary` is nil (the on-disk
    /// scenario where `CFBundleShortVersionString` is missing), the
    /// helper must return the literal "1.0.0". Mutating the literal
    /// silently changes the version string the menu-bar footer renders
    /// in degraded environments.
    func testUIGate_updater_currentVersion_fallbackWhenInfoDictionaryNil() {
        let stub = NilInfoBundle()
        let resolved = Updater.currentVersion(bundle: stub)
        XCTAssertEqual(resolved, "1.0.0",
            "[ui-gate=updater-currentVersion-fallback] expected " +
            "\"1.0.0\" when bundle.infoDictionary is nil; got " +
            "\"\(resolved)\" — production fallback literal likely mutated")
    }
}

/// Test stub: a `Bundle` subclass whose `infoDictionary` returns nil so
/// the Updater fallback path engages. Real `Bundle.main` under the SPM
/// `xctest` runner always supplies a non-nil version.
private final class NilInfoBundle: Bundle, @unchecked Sendable {
    override var infoDictionary: [String: Any]? { nil }
}

#if DIRECT_BUILD
/// Phase 7c Direct-only cells — exercise `Updater.isNewer(remote:local:)`,
/// which is `internal static` inside the `#if DIRECT_BUILD` branch.
/// Compiled only when SPM is invoked with `-Xswiftc -DDIRECT_BUILD`.
@MainActor
final class UIGatesPhase7C_DirectOnly_Tests: XCTestCase {

    /// Cell Q — equal versions are NOT newer. `isNewer` returns false
    /// when remote and local are identical.
    func testUIGate_updater_isNewer_equalReturnsFalse() {
        XCTAssertFalse(Updater.isNewer(remote: "1.2.3", local: "1.2.3"),
            "[ui-gate=updater-isNewer-equal] expected isNewer=false for " +
            "equal versions; production comparator likely flipped")
    }

    /// Cell R — remote-newer cases (major / minor / patch) all return
    /// true. Mutating the comparator (e.g. `rv > lv` → `rv < lv`) would
    /// flip every available-update detection to false.
    func testUIGate_updater_isNewer_remoteNewerReturnsTrue() {
        XCTAssertTrue(Updater.isNewer(remote: "2.0.0", local: "1.9.9"),
            "[ui-gate=updater-isNewer-remote-newer] major bump must " +
            "register as newer")
        XCTAssertTrue(Updater.isNewer(remote: "1.3.0", local: "1.2.9"),
            "[ui-gate=updater-isNewer-remote-newer] minor bump must " +
            "register as newer")
        XCTAssertTrue(Updater.isNewer(remote: "1.2.4", local: "1.2.3"),
            "[ui-gate=updater-isNewer-remote-newer] patch bump must " +
            "register as newer")
    }

    /// Cell S — remote-older cases all return false. The dual of cell R.
    func testUIGate_updater_isNewer_remoteOlderReturnsFalse() {
        XCTAssertFalse(Updater.isNewer(remote: "1.0.0", local: "2.0.0"),
            "[ui-gate=updater-isNewer-remote-older] downgraded major " +
            "must NOT register as newer")
        XCTAssertFalse(Updater.isNewer(remote: "1.2.0", local: "1.3.0"),
            "[ui-gate=updater-isNewer-remote-older] downgraded minor " +
            "must NOT register as newer")
        XCTAssertFalse(Updater.isNewer(remote: "1.2.2", local: "1.2.3"),
            "[ui-gate=updater-isNewer-remote-older] downgraded patch " +
            "must NOT register as newer")
    }

    /// Cell T — short-vs-long version padding. A 2-segment "1.2" must
    /// compare as 1.2.0 against a 3-segment "1.2.0" (equal — neither
    /// newer). And "1.2.1" must register as newer than "1.2".
    /// Pins the `i < r.count ? r[i] : 0` zero-padding fallback.
    func testUIGate_updater_isNewer_segmentPadding() {
        XCTAssertFalse(Updater.isNewer(remote: "1.2", local: "1.2.0"),
            "[ui-gate=updater-isNewer-segment-padding] missing segment " +
            "must be treated as 0; \"1.2\" must NOT be newer than \"1.2.0\"")
        XCTAssertTrue(Updater.isNewer(remote: "1.2.1", local: "1.2"),
            "[ui-gate=updater-isNewer-segment-padding] \"1.2.1\" must be " +
            "newer than \"1.2\" via zero-pad of local")
    }

    /// Cell U — release > pre-release with same core (SemVer 2.0 §11.3).
    /// A release version with no pre-release suffix is strictly NEWER
    /// than any pre-release sharing the same `(major, minor, patch)`
    /// core. Mutating the release-vs-pre-release branch (e.g. flipping
    /// the `(nil, _?) → true` case) regresses to the old "by-accident"
    /// answer and breaks SemVer ordering.
    func testUIGate_updater_isNewer_releaseBeatsPreRelease() {
        XCTAssertTrue(Updater.isNewer(remote: "1.2.3", local: "1.2.3-rc1"),
            "[ui-gate=updater-isNewer-release-beats-prerelease] release " +
            "\"1.2.3\" must register as newer than its own rc " +
            "\"1.2.3-rc1\" per SemVer 2.0 §11.3 — a release with no " +
            "pre-release suffix has higher precedence than any " +
            "pre-release sharing the same core")
        XCTAssertFalse(Updater.isNewer(remote: "1.2.3-rc1", local: "1.2.3"),
            "[ui-gate=updater-isNewer-release-beats-prerelease] rc " +
            "\"1.2.3-rc1\" must NOT register as newer than release " +
            "\"1.2.3\" (the dual)")
    }
}
#endif

/// Phase 7c — SemVer 2.0 ordering cells. Compiled under BOTH build
/// variants (the `Updater.isNewer(...)` extension lives outside the
/// `#if DIRECT_BUILD` block so the comparator is always available).
/// These cells are catalog-able under bare `swift test` because they
/// don't depend on the Direct-only `performCheck` plumbing.
@MainActor
final class UpdaterSemVerOrdering_Tests: XCTestCase {

    /// Cell V — release version is strictly newer than its own
    /// pre-release with the same core. Pins SemVer 2.0 §11.3.
    func testUIGate_updater_semver_releaseBeatsPreRelease() {
        XCTAssertTrue(Updater.isNewer(remote: "1.2.3", local: "1.2.3-rc1"),
            "[ui-gate=updater-semver-release-beats-prerelease] " +
            "release \"1.2.3\" must rank ABOVE pre-release \"1.2.3-rc1\" " +
            "per SemVer 2.0 §11.3")
        XCTAssertFalse(Updater.isNewer(remote: "1.2.3-rc1", local: "1.2.3"),
            "[ui-gate=updater-semver-release-beats-prerelease] " +
            "pre-release \"1.2.3-rc1\" must NOT rank above release " +
            "\"1.2.3\"")
    }

    /// Cell W — alphanumeric pre-release identifiers compare by ASCII
    /// lex order. `rc2` > `rc1` (final char '2' > '1'). Pins SemVer 2.0
    /// §11.4.2 (alphanumeric vs alphanumeric).
    func testUIGate_updater_semver_alphanumericPreReleaseOrdering() {
        XCTAssertTrue(Updater.isNewer(remote: "1.2.3-rc2", local: "1.2.3-rc1"),
            "[ui-gate=updater-semver-prerelease-alphanumeric] " +
            "alphanumeric pre-release \"rc2\" must rank above \"rc1\" " +
            "by ASCII lex per SemVer 2.0 §11.4.2")
        XCTAssertFalse(Updater.isNewer(remote: "1.2.3-rc1", local: "1.2.3-rc2"),
            "[ui-gate=updater-semver-prerelease-alphanumeric] dual: " +
            "\"rc1\" must NOT rank above \"rc2\"")
        // 'r' (0x72) > 'a' (0x61) ASCII, so "rc1" > "alpha1".
        XCTAssertTrue(Updater.isNewer(remote: "1.2.3-rc1", local: "1.2.3-alpha1"),
            "[ui-gate=updater-semver-prerelease-alphanumeric] " +
            "\"rc1\" must rank above \"alpha1\" by ASCII lex " +
            "('r' > 'a')")
    }

    /// Cell X — numeric pre-release identifiers compare by INTEGER
    /// value, not lexicographically. `rc.10` > `rc.2` (10 > 2 as int,
    /// even though "10" < "2" as string). Pins SemVer 2.0 §11.4.1
    /// (numeric identifier comparison).
    func testUIGate_updater_semver_numericPreReleaseOrdering() {
        XCTAssertTrue(Updater.isNewer(remote: "1.2.3-rc.10", local: "1.2.3-rc.2"),
            "[ui-gate=updater-semver-prerelease-numeric] numeric " +
            "identifier \"10\" must rank above \"2\" as integer per " +
            "SemVer 2.0 §11.4.1 — string lex would (incorrectly) give " +
            "\"10\" < \"2\"")
        XCTAssertFalse(Updater.isNewer(remote: "1.2.3-rc.2", local: "1.2.3-rc.10"),
            "[ui-gate=updater-semver-prerelease-numeric] dual: " +
            "\"rc.2\" must NOT rank above \"rc.10\"")
    }
}

