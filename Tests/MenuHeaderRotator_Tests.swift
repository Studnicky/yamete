import XCTest
@testable import YameteApp
@testable import YameteCore

/// Pure-functional tests for `MenuHeaderRotator`. Verifies page-cycle
/// invariants without exercising the wall-clock timer (`start()` is not
/// called; tests drive the cursor via the `internal` `advance()` seam).
@MainActor
final class MenuHeaderRotator_Tests: XCTestCase {

    /// Single-page rotator: `advance()` is a no-op, the cursor never
    /// goes out of bounds.
    func testSinglePage_advanceIsNoop() {
        let rotator = MenuHeaderRotator(pages: ["only-body"])
        XCTAssertEqual(rotator.current, "only-body")
        rotator.advance()
        XCTAssertEqual(rotator.current, "only-body", "Single-page advance must be a no-op")
    }

    /// Multi-page advance wraps modulo the page count.
    func testMultiPage_advanceWrapsModulo() {
        let rotator = MenuHeaderRotator(pages: ["A", "B", "C"])
        XCTAssertEqual(rotator.current, "A")
        rotator.advance(); XCTAssertEqual(rotator.current, "B")
        rotator.advance(); XCTAssertEqual(rotator.current, "C")
        rotator.advance(); XCTAssertEqual(rotator.current, "A", "Wraps to page 0")
    }

    /// `setPages(_:)` resets the cursor to page 0.
    func testSetPages_resetsCursor() {
        let rotator = MenuHeaderRotator(pages: ["A", "B"])
        rotator.advance() // current = B
        rotator.setPages(["X"])
        XCTAssertEqual(rotator.current, "X")
    }

    /// `setPages(_:)` with an equal page list is a no-op (idempotent).
    /// Important: equal re-sets must not flicker the visible page during
    /// onChange-driven rebuilds.
    func testSetPages_equalIsIdempotent() {
        let pages = ["A", "B"]
        let rotator = MenuHeaderRotator(pages: pages)
        rotator.advance() // current = B
        rotator.setPages(pages)
        XCTAssertEqual(rotator.current, "B",
                       "Equal-page set must NOT reset the cursor (would cause flicker)")
    }

    /// `setPages(_:)` with empty input is rejected (would orphan the cursor).
    func testSetPages_emptyRejected() {
        let rotator = MenuHeaderRotator(pages: ["A"])
        rotator.setPages([])
        XCTAssertEqual(rotator.current, "A", "Empty input must be ignored")
    }

    /// Init clamps interval into a sane band so a misconfigured caller
    /// can't queue transitions before the cross-fade animation finishes.
    func testInit_intervalClamped() {
        // No public accessor — interval is private. We just verify the
        // initialiser does not crash at the band boundaries.
        _ = MenuHeaderRotator(pages: ["A"], interval: 0.5)
        _ = MenuHeaderRotator(pages: ["A"], interval: 300)
        _ = MenuHeaderRotator(pages: ["A"], interval: 8)
    }

    /// `buildBodies(...)` always emits the app tagline first, even when
    /// the enabledKinds list is empty.
    func testBuildBodies_taglineFirst() {
        let bodies = MenuHeaderRotator.buildBodies(
            appTagline: "your laptop yells when smacked",
            enabledKinds: [],
            locale: "en"
        )
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first, "your laptop yells when smacked")
    }

    /// `buildBodies(...)` returns deduped body variants — duplicate
    /// strings across pools are collapsed so the rotator doesn't show
    /// the same body twice in a single cycle.
    func testBuildBodies_dedupes() {
        let bodies = MenuHeaderRotator.buildBodies(
            appTagline: "tag",
            enabledKinds: ReactionKind.allCases.filter { $0 != .impact },
            locale: "en"
        )
        XCTAssertEqual(Set(bodies).count, bodies.count, "Bodies must be deduped")
    }

    /// `buildBodies(...)` skips empty body strings so an empty pool
    /// entry never lands as a blank page.
    func testBuildBodies_skipsEmpty() {
        let bodies = MenuHeaderRotator.buildBodies(
            appTagline: "tag",
            enabledKinds: [.impact],   // .impact has no event body pool
            locale: "en"
        )
        XCTAssertFalse(bodies.contains(""), "Empty bodies must be filtered out")
    }
}
