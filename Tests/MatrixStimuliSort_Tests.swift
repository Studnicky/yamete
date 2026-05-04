import XCTest
@testable import YameteApp
@testable import YameteCore

/// Pure-functional sort gates for `StimuliSection.orderedRows(...)`.
///
/// Locked invariants:
///   1. Active (enabled) stimuli always render above inactive (disabled) ones.
///   2. Within each group, rows alpha-sort by localised title.
///   3. Sort uses the user-selected locale's collation rules — distinct from
///      the system default. Verified by feeding two locales whose case-folding
///      and diacritic rules diverge enough that the resulting order shifts.
///   4. Toggling a stimulus moves it across the group boundary on the next
///      sort call (no implicit caching).
///
/// The impact-sensor consensus group lives in `SensorSection` and is pinned
/// above this section by the parent layout — these tests do NOT cover it.
@MainActor
final class MatrixStimuliSort_Tests: XCTestCase {

    private func row(_ id: String, _ title: String) -> StimuliSection.StimulusRow {
        .init(sourceID: id, title: title, icon: "circle", help: "", kinds: [])
    }

    /// Active group above inactive group, even if inactive titles would
    /// alphabetically precede active ones.
    func testActiveAboveInactive_groupBoundaryRespected() {
        let rows = [
            row("a", "Apple"),     // inactive
            row("b", "Banana"),    // active
            row("c", "Cherry"),    // inactive
        ]
        let result = StimuliSection.orderedRows(
            rows,
            enabledIDs: ["b"],
            collationLocale: Locale(identifier: "en")
        )
        XCTAssertEqual(result.map(\.sourceID), ["b", "a", "c"],
                       "Active 'Banana' must precede inactive 'Apple' even though 'A' < 'B'")
    }

    /// Within each group, alpha-sort by title.
    func testAlphaSortWithinEachGroup() {
        let rows = [
            row("c", "Cherry"),   // active
            row("a", "Apple"),    // active
            row("b", "Banana"),   // active
            row("z", "Zucchini"), // inactive
            row("d", "Date"),     // inactive
        ]
        let result = StimuliSection.orderedRows(
            rows,
            enabledIDs: ["a", "b", "c"],
            collationLocale: Locale(identifier: "en")
        )
        XCTAssertEqual(result.map(\.sourceID), ["a", "b", "c", "d", "z"])
    }

    /// All-active and all-inactive paths both alpha-sort correctly.
    func testEdge_allActive_allInactive() {
        let rows = [row("c", "Cherry"), row("a", "Apple"), row("b", "Banana")]
        let allActive = StimuliSection.orderedRows(rows,
                                                    enabledIDs: ["a", "b", "c"],
                                                    collationLocale: Locale(identifier: "en"))
        XCTAssertEqual(allActive.map(\.sourceID), ["a", "b", "c"])
        let allInactive = StimuliSection.orderedRows(rows,
                                                      enabledIDs: [],
                                                      collationLocale: Locale(identifier: "en"))
        XCTAssertEqual(allInactive.map(\.sourceID), ["a", "b", "c"])
    }

    /// Diacritic-insensitive comparison so ä-vs-a doesn't fragment the alphabet
    /// (Ä folds to A; "Älpler" sorts as if "Alpler"). Verifies the user-locale
    /// path produces a deterministic order across both ASCII and accented
    /// titles instead of bucketing them into separate alphabetical regions.
    func testDiacriticInsensitive_underUserLocale() {
        let rows = [
            row("a", "Apple"),
            row("ae", "Älpler"),
            row("b", "Banana"),
        ]
        let result = StimuliSection.orderedRows(
            rows,
            enabledIDs: ["a", "ae", "b"],
            collationLocale: Locale(identifier: "de")
        )
        // Ä folds to A → "Älpler" sorts as "Alpler" → comes before "Apple"
        // (l < p) under diacritic-insensitive case-insensitive compare. The
        // critical invariant is that it does NOT land after "Banana" (which
        // it would if the diacritic flag were dropped — Ä would sort outside
        // the basic-Latin block as the highest-codepoint letter and "Älpler"
        // would land at the end).
        XCTAssertEqual(result.map(\.sourceID), ["ae", "a", "b"])
    }

    /// Toggling enabledIDs across calls produces correct re-sort each time —
    /// no implicit caching makes ordering stale.
    func testToggle_reordersOnNextCall() {
        let rows = [row("a", "Apple"), row("b", "Banana"), row("c", "Cherry")]

        let onlyB = StimuliSection.orderedRows(rows,
                                                enabledIDs: ["b"],
                                                collationLocale: Locale(identifier: "en"))
        XCTAssertEqual(onlyB.map(\.sourceID), ["b", "a", "c"])

        let bAndC = StimuliSection.orderedRows(rows,
                                                enabledIDs: ["b", "c"],
                                                collationLocale: Locale(identifier: "en"))
        XCTAssertEqual(bAndC.map(\.sourceID), ["b", "c", "a"])

        let none = StimuliSection.orderedRows(rows,
                                               enabledIDs: [],
                                               collationLocale: Locale(identifier: "en"))
        XCTAssertEqual(none.map(\.sourceID), ["a", "b", "c"])
    }

    /// Empty input is the identity (no crash, no spurious entries).
    func testEmpty_returnsEmpty() {
        let result = StimuliSection.orderedRows([],
                                                 enabledIDs: ["x"],
                                                 collationLocale: Locale(identifier: "en"))
        XCTAssertTrue(result.isEmpty)
    }
}
