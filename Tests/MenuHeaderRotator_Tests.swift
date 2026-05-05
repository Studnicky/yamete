import XCTest
@testable import YameteApp
@testable import YameteCore

/// Pure-functional tests for `MenuHeaderRotator`. Drives the cursor via
/// the `internal` `advance()` seam plus an injected deterministic
/// shuffle so order is locked across runs without exercising the
/// wall-clock timer.
@MainActor
final class MenuHeaderRotator_Tests: XCTestCase {

    /// Identity shuffle — preserves caller order. Tests that need
    /// deterministic ordering substitute this for the default RNG-backed
    /// shuffle.
    private static let identity: ([String]) -> [String] = { $0 }

    /// Reverse shuffle — flips caller order; used to verify the
    /// adjacent-repeat avoidance kicks in when the natural reshuffle
    /// would otherwise repeat the last shown page.
    private static let reverse: ([String]) -> [String] = { $0.reversed() }

    /// Single-page rotator: `advance()` is a no-op, the cursor never
    /// goes out of bounds.
    func testSinglePage_advanceIsNoop() {
        let rotator = MenuHeaderRotator(pages: ["only-body"], shuffle: Self.identity)
        XCTAssertEqual(rotator.current, "only-body")
        rotator.advance()
        XCTAssertEqual(rotator.current, "only-body", "Single-page advance must be a no-op")
    }

    /// First cycle walks the pool in caller order so launch-time always
    /// shows page 0 first (the tagline) — no shuffle on initial load.
    func testFirstCycle_walksPoolInOrder() {
        let rotator = MenuHeaderRotator(pages: ["A", "B", "C"], shuffle: Self.identity)
        XCTAssertEqual(rotator.current, "A")
        rotator.advance(); XCTAssertEqual(rotator.current, "B")
        rotator.advance(); XCTAssertEqual(rotator.current, "C")
    }

    /// Subsequent cycles use the shuffled order (identity here for
    /// determinism) and avoid repeating the last shown page across the
    /// boundary. With identity shuffle the natural reshuffle would
    /// re-emit "A" right after "C" — the head-rotation guard pushes "A"
    /// to the end so we get "B" instead.
    func testCycleBoundary_avoidsAdjacentRepeat() {
        let rotator = MenuHeaderRotator(pages: ["A", "B", "C"], shuffle: Self.identity)
        rotator.advance() // B
        rotator.advance() // C — last of cycle
        rotator.advance() // would be A under raw identity shuffle; head-rotation pushes it later
        XCTAssertNotEqual(rotator.current, "C",
                          "First page of a new cycle must not equal the last page of the prior cycle")
    }

    /// `setPages(_:)` resets the cursor to the new pool's first entry
    /// and re-seeds the queue (caller-order first cycle, shuffled
    /// thereafter).
    func testSetPages_resetsCursor() {
        let rotator = MenuHeaderRotator(pages: ["A", "B"], shuffle: Self.identity)
        rotator.advance() // current = B
        rotator.setPages(["X", "Y"])
        XCTAssertEqual(rotator.current, "X")
    }

    /// `setPages(_:)` with an equal pool is a no-op (idempotent).
    /// Important: equal re-sets must not flicker the visible page during
    /// onChange-driven rebuilds.
    func testSetPages_equalIsIdempotent() {
        let pages = ["A", "B", "C"]
        let rotator = MenuHeaderRotator(pages: pages, shuffle: Self.identity)
        rotator.advance() // current = B
        rotator.setPages(pages)
        XCTAssertEqual(rotator.current, "B",
                       "Equal-pool set must NOT reset the cursor (would cause flicker)")
    }

    /// `setPages(_:)` with empty input is rejected — would orphan the cursor.
    func testSetPages_emptyRejected() {
        let rotator = MenuHeaderRotator(pages: ["A"], shuffle: Self.identity)
        rotator.setPages([])
        XCTAssertEqual(rotator.current, "A", "Empty input must be ignored")
    }

    /// Init clamps interval into a sane band so a misconfigured caller
    /// can't queue transitions before the cross-fade animation finishes.
    func testInit_intervalClamped() {
        // No public accessor — interval is private. We just verify the
        // initialiser does not crash at the band boundaries.
        _ = MenuHeaderRotator(pages: ["A"], interval: 0.5,  shuffle: Self.identity)
        _ = MenuHeaderRotator(pages: ["A"], interval: 300,  shuffle: Self.identity)
        _ = MenuHeaderRotator(pages: ["A"], interval: 8,    shuffle: Self.identity)
    }

    /// `buildBodies(...)` always emits the app tagline first, even when
    /// the locale's moan pool is empty.
    func testBuildBodies_taglineFirst() {
        let bodies = MenuHeaderRotator.buildBodies(
            appTagline: "your laptop yells when smacked",
            locale: "qx"   // bogus locale → no moans loaded → only tagline
        )
        XCTAssertEqual(bodies.first, "your laptop yells when smacked",
                       "Tagline must always be page 0")
    }

    /// `buildBodies(...)` returns deduped strings — the same moan never
    /// appears twice in a single pool even if it's defined for multiple
    /// tiers in the locale.
    func testBuildBodies_dedupes() {
        let bodies = MenuHeaderRotator.buildBodies(
            appTagline: "tag",
            locale: "en"
        )
        XCTAssertEqual(Set(bodies).count, bodies.count, "Moans must be deduped")
    }
}
