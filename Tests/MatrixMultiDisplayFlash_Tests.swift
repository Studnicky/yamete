import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Multi-display flash matrix: screen count × `flashActiveDisplayOnly` ×
/// main-screen position. Bug class: with multiple displays the wrong subset
/// is flashed (only one renders, or when active-only is on the wrong screen
/// is targeted, or NSScreen state is read past a config change).
///
/// Strategy: ScreenFlash exposes a pure `selectScreenIDs(...)` helper that
/// mirrors the production branching (production lookups go through
/// `NSScreen.screens` / `NSScreen.main`; the helper takes those values as
/// inputs so we don't have to synthesize NSScreen). Cells assert exact
/// returned IDs and order against every screen-count × flag combination.
@MainActor
final class MatrixMultiDisplayFlash_Tests: XCTestCase {

    // MARK: - 1-screen cells

    func testOneScreen() {
        // (allScreens, mainID, enabledIDs, activeOnly) → expected
        struct Cell { let activeOnly: Bool; let enabled: [Int]; let expected: [Int] }
        let cells: [Cell] = [
            .init(activeOnly: false, enabled: [10],  expected: [10]),
            .init(activeOnly: true,  enabled: [10],  expected: [10]),
            // active-only path ignores enabledIDs entirely
            .init(activeOnly: true,  enabled: [],    expected: [10]),
            // not-active-only, empty enabled set → empty (production filter pattern)
            .init(activeOnly: false, enabled: [],    expected: []),
        ]
        for cell in cells {
            let result = ScreenFlash.selectScreenIDs(
                allScreenIDs: [10], mainScreenID: 10,
                enabledIDs: cell.enabled, activeDisplayOnly: cell.activeOnly
            )
            XCTAssertEqual(result, cell.expected,
                "[screens=1 active=\(cell.activeOnly) enabled=\(cell.enabled)] " +
                "expected \(cell.expected), got \(result)")
        }
    }

    // MARK: - 2-screen cells

    func testTwoScreens() {
        // [10, 20] with main = 10 by default
        struct Cell { let activeOnly: Bool; let enabled: [Int]; let mainID: Int?; let expected: [Int] }
        let cells: [Cell] = [
            .init(activeOnly: false, enabled: [10, 20], mainID: 10, expected: [10, 20]),
            .init(activeOnly: false, enabled: [20],     mainID: 10, expected: [20]),
            .init(activeOnly: false, enabled: [10],     mainID: 10, expected: [10]),
            .init(activeOnly: true,  enabled: [10, 20], mainID: 10, expected: [10]),
            .init(activeOnly: true,  enabled: [10, 20], mainID: 20, expected: [20]),
            // active-only with no main screen → empty (degenerate)
            .init(activeOnly: true,  enabled: [10, 20], mainID: nil, expected: []),
        ]
        for cell in cells {
            let result = ScreenFlash.selectScreenIDs(
                allScreenIDs: [10, 20], mainScreenID: cell.mainID,
                enabledIDs: cell.enabled, activeDisplayOnly: cell.activeOnly
            )
            XCTAssertEqual(result, cell.expected,
                "[screens=2 active=\(cell.activeOnly) enabled=\(cell.enabled) main=\(String(describing: cell.mainID))] " +
                "expected \(cell.expected), got \(result)")
        }
    }

    // MARK: - 3-screen cells × main position

    func testThreeScreensMainPosition() {
        let allIDs = [10, 20, 30]
        for mainIdx in 0..<3 {
            let mainID = allIDs[mainIdx]
            // active-only must yield exactly the main screen regardless of enable list
            let activeResult = ScreenFlash.selectScreenIDs(
                allScreenIDs: allIDs, mainScreenID: mainID,
                enabledIDs: allIDs, activeDisplayOnly: true
            )
            XCTAssertEqual(activeResult, [mainID],
                "[screens=3 mainIdx=\(mainIdx) active=true] expected [\(mainID)], got \(activeResult)")
            // not-active path returns the intersection of all+enabled, in
            // allScreens order. A reordered enabled list does NOT reorder
            // output — production preserves NSScreen.screens ordering.
            let notActiveResult = ScreenFlash.selectScreenIDs(
                allScreenIDs: allIDs, mainScreenID: mainID,
                enabledIDs: [30, 10, 20], activeDisplayOnly: false
            )
            XCTAssertEqual(notActiveResult, allIDs,
                "[screens=3 mainIdx=\(mainIdx) active=false] expected ordering preserved [10,20,30], got \(notActiveResult)")
        }
    }

    // MARK: - Degenerate cells

    func testZeroScreens() {
        // No NSScreens connected at all (e.g. headless server). Both branches
        // produce empty arrays — production guard returns early without crashing.
        let resultAll = ScreenFlash.selectScreenIDs(
            allScreenIDs: [], mainScreenID: nil,
            enabledIDs: [10, 20], activeDisplayOnly: false
        )
        let resultActive = ScreenFlash.selectScreenIDs(
            allScreenIDs: [], mainScreenID: nil,
            enabledIDs: [10, 20], activeDisplayOnly: true
        )
        XCTAssertEqual(resultAll, [],
            "[screens=0 active=false] expected empty, got \(resultAll)")
        XCTAssertEqual(resultActive, [],
            "[screens=0 active=true] expected empty, got \(resultActive)")
    }

    // MARK: - Mid-action config change

    /// Two consecutive selections with different `activeDisplayOnly` flags —
    /// the second must reflect the new config independent of the first call.
    func testConfigChangeMidAction() {
        let allIDs = [10, 20]
        let firstResult = ScreenFlash.selectScreenIDs(
            allScreenIDs: allIDs, mainScreenID: 10,
            enabledIDs: allIDs, activeDisplayOnly: false
        )
        XCTAssertEqual(firstResult, [10, 20],
            "[scenario=config-change-1 active=false] expected both screens, got \(firstResult)")

        // Settings change — flashActiveDisplayOnly toggled true.
        let secondResult = ScreenFlash.selectScreenIDs(
            allScreenIDs: allIDs, mainScreenID: 10,
            enabledIDs: allIDs, activeDisplayOnly: true
        )
        XCTAssertEqual(secondResult, [10],
            "[scenario=config-change-2 active=true] expected main only, got \(secondResult)")
    }
}
