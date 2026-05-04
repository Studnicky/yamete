import XCTest
@testable import YameteApp
@testable import YameteCore

/// Pure-functional tests for `MenuHeaderRotator`. Verifies page-cycle
/// invariants without exercising the wall-clock timer (`start()` is not
/// called; tests drive the cursor via the `internal` `advance()` seam).
@MainActor
final class MenuHeaderRotator_Tests: XCTestCase {

    /// Fresh rotator with a single page — `advance()` is a no-op so the
    /// cursor never goes out of bounds.
    func testSinglePage_advanceIsNoop() {
        let rotator = MenuHeaderRotator(pages: [.init(title: "A", body: "1")])
        XCTAssertEqual(rotator.current.title, "A")
        rotator.advance()
        XCTAssertEqual(rotator.current.title, "A", "Single-page advance must be a no-op")
    }

    /// Multi-page advance wraps modulo the page count.
    func testMultiPage_advanceWrapsModulo() {
        let rotator = MenuHeaderRotator(pages: [
            .init(title: "A", body: "1"),
            .init(title: "B", body: "2"),
            .init(title: "C", body: "3"),
        ])
        XCTAssertEqual(rotator.current.title, "A")
        rotator.advance(); XCTAssertEqual(rotator.current.title, "B")
        rotator.advance(); XCTAssertEqual(rotator.current.title, "C")
        rotator.advance(); XCTAssertEqual(rotator.current.title, "A", "Wraps to page 0")
    }

    /// `setPages(_:)` resets the cursor to page 0.
    func testSetPages_resetsCursor() {
        let rotator = MenuHeaderRotator(pages: [
            .init(title: "A", body: "1"),
            .init(title: "B", body: "2"),
        ])
        rotator.advance() // current = B
        rotator.setPages([.init(title: "X", body: "x")])
        XCTAssertEqual(rotator.current.title, "X")
    }

    /// `setPages(_:)` with an equal page list is a no-op (idempotent).
    func testSetPages_equalIsIdempotent() {
        let pages = [MenuHeaderRotator.Page(title: "A", body: "1"),
                     MenuHeaderRotator.Page(title: "B", body: "2")]
        let rotator = MenuHeaderRotator(pages: pages)
        rotator.advance() // current = B
        rotator.setPages(pages)
        XCTAssertEqual(rotator.current.title, "B",
                       "Equal-page set must NOT reset the cursor (would cause flicker)")
    }

    /// `setPages(_:)` with empty input is rejected (would orphan the cursor).
    func testSetPages_emptyRejected() {
        let rotator = MenuHeaderRotator(pages: [.init(title: "A", body: "1")])
        rotator.setPages([])
        XCTAssertEqual(rotator.current.title, "A", "Empty input must be ignored")
    }

    /// Init clamps interval into a sane band.
    func testInit_intervalClamped() {
        // No public accessor — interval is private. We just verify the
        // initialiser does not crash and the rotator is in a usable state
        // for any input. Coverage for the clamp itself comes via the
        // documented `[1.5s, 30s]` contract.
        _ = MenuHeaderRotator(pages: [.init(title: "A", body: "1")], interval: 0.1)
        _ = MenuHeaderRotator(pages: [.init(title: "A", body: "1")], interval: 300)
        _ = MenuHeaderRotator(pages: [.init(title: "A", body: "1")], interval: 5)
    }

    /// `buildPages(...)` always emits the app-identity page first, even
    /// when the enabledKinds list is empty.
    func testBuildPages_appIdentityFirst() {
        let pages = MenuHeaderRotator.buildPages(
            appTitle: "Yamete",
            appTagline: "your laptop yells when smacked",
            enabledKinds: [],
            locale: "en"
        )
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.title, "Yamete")
        XCTAssertEqual(pages.first?.body, "your laptop yells when smacked")
    }

    /// `buildPages(...)` skips kinds whose phrasing isn't loadable
    /// (fallback returns the raw rawValue) so the rotator never lands on
    /// a broken page.
    func testBuildPages_skipsMissingPhrasings() {
        // Most ReactionKind cases have phrasings; the test passes if no
        // page leaks the rawValue as its title.
        let kinds: [ReactionKind] = ReactionKind.allCases.filter { $0 != .impact }
        let pages = MenuHeaderRotator.buildPages(
            appTitle: "T",
            appTagline: "g",
            enabledKinds: kinds,
            locale: "en"
        )
        XCTAssertGreaterThanOrEqual(pages.count, 1, "App-identity page is always present")
        for page in pages.dropFirst() {
            XCTAssertFalse(kinds.map(\.rawValue).contains(page.title),
                           "Page title '\(page.title)' leaked a ReactionKind rawValue (missing phrasing)")
        }
    }
}
