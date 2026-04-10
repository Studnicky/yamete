import XCTest
@testable import ResponseKit
@testable import YameteCore

/// Coverage for `NotificationPhrase` — the locale-aware phrase pool loader
/// used by `NotificationResponder` to resolve notification title and body.
///
/// These tests inject pools directly via `NotificationPhrase._testInject`
/// rather than relying on `Localizable.strings` files, because `.lproj`
/// resources are bundled into the `.app` by the Makefile (not the SPM test
/// runner). The real loader is exercised by smoke-testing the shipped app
/// bundle; these tests verify the resolution/selection *logic*.
@MainActor
final class NotificationResponderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NotificationPhrase._testClear()
    }

    override func tearDown() {
        NotificationPhrase._testClear()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A complete pool set — title + moan for every tier — for a fake locale.
    private func fullPools(prefix: String) -> [String: [String]] {
        [
            "title_tap":    ["\(prefix)-title-tap"],
            "title_light":  ["\(prefix)-title-light"],
            "title_medium": ["\(prefix)-title-medium"],
            "title_firm":   ["\(prefix)-title-firm"],
            "title_hard":   ["\(prefix)-title-hard"],
            "moan_tap":     ["\(prefix)-moan-tap"],
            "moan_light":   ["\(prefix)-moan-light"],
            "moan_medium":  ["\(prefix)-moan-medium"],
            "moan_firm":    ["\(prefix)-moan-firm"],
            "moan_hard":    ["\(prefix)-moan-hard"],
        ]
    }

    /// A partial pool set — moans only, no titles. Matches the pre-title
    /// state of Romance/Slavic/etc. locales written by earlier agents.
    private func moanOnlyPools(prefix: String) -> [String: [String]] {
        [
            "moan_tap":     ["\(prefix)-moan-tap"],
            "moan_light":   ["\(prefix)-moan-light"],
            "moan_medium":  ["\(prefix)-moan-medium"],
            "moan_firm":    ["\(prefix)-moan-firm"],
            "moan_hard":    ["\(prefix)-moan-hard"],
        ]
    }

    // MARK: - resolveLocale: full-pool locales resolve to themselves

    func testResolveLocaleWithFullPoolsReturnsSelf() {
        NotificationPhrase._testInject(pools: fullPools(prefix: "en"), for: "en")
        NotificationPhrase._testInject(pools: fullPools(prefix: "ja"), for: "ja")

        for tier in ImpactTier.allCases {
            XCTAssertEqual(NotificationPhrase.resolveLocale(preferred: "en", for: tier), "en")
            XCTAssertEqual(NotificationPhrase.resolveLocale(preferred: "ja", for: tier), "ja")
        }
    }

    // MARK: - resolveLocale: unified fallback

    /// Regression for the "English title + French body" bug. A locale with
    /// moans but no titles must fall back to en for the WHOLE notification,
    /// not half-and-half.
    func testResolveLocaleWithMoanOnlyPoolsFallsBackToEn() {
        NotificationPhrase._testInject(pools: fullPools(prefix: "en"), for: "en")
        NotificationPhrase._testInject(pools: moanOnlyPools(prefix: "fr"), for: "fr")

        for tier in ImpactTier.allCases {
            XCTAssertEqual(
                NotificationPhrase.resolveLocale(preferred: "fr", for: tier),
                "en",
                "fr has moans but no titles for \(tier) — must fall back to en")
        }
    }

    /// Unknown locales fall back to en.
    func testResolveLocaleUnknownFallsBackToEn() {
        NotificationPhrase._testInject(pools: fullPools(prefix: "en"), for: "en")

        for tier in ImpactTier.allCases {
            XCTAssertEqual(
                NotificationPhrase.resolveLocale(preferred: "xx_ZZ", for: tier),
                "en")
        }
    }

    /// A locale with empty arrays (pool present but zero entries) also
    /// falls back — the check is `!isEmpty`, not just `!= nil`.
    func testResolveLocaleWithEmptyArraysFallsBack() {
        NotificationPhrase._testInject(pools: fullPools(prefix: "en"), for: "en")
        NotificationPhrase._testInject(
            pools: ["title_tap": [], "moan_tap": []],
            for: "de")

        XCTAssertEqual(
            NotificationPhrase.resolveLocale(preferred: "de", for: .tap),
            "en",
            "empty pool arrays should fall back the same as missing pools")
    }

    // MARK: - title / moan selection

    /// `title(for:localeID:)` pulls from the expected per-tier pool.
    func testTitleSelectsFromCorrectPool() {
        NotificationPhrase._testInject(pools: fullPools(prefix: "en"), for: "en")

        XCTAssertEqual(NotificationPhrase.title(for: .tap, localeID: "en"), "en-title-tap")
        XCTAssertEqual(NotificationPhrase.title(for: .hard, localeID: "en"), "en-title-hard")
    }

    /// `moan(for:localeID:)` pulls from the expected per-tier pool.
    func testMoanSelectsFromCorrectPool() {
        NotificationPhrase._testInject(pools: fullPools(prefix: "en"), for: "en")

        XCTAssertEqual(NotificationPhrase.moan(for: .tap, localeID: "en"), "en-moan-tap")
        XCTAssertEqual(NotificationPhrase.moan(for: .hard, localeID: "en"), "en-moan-hard")
    }

    /// When the requested pool is empty/missing, `title` and `moan` return
    /// empty strings. The single-source-of-truth resolution in
    /// `postNotification` prevents this from shipping user-visible, but the
    /// contract for the primitive lookup is still "empty string on miss".
    func testTitleReturnsEmptyStringForMissingPool() {
        XCTAssertEqual(NotificationPhrase.title(for: .tap, localeID: "xx_ZZ"), "")
        XCTAssertEqual(NotificationPhrase.moan(for: .hard, localeID: "xx_ZZ"), "")
    }

    // MARK: - Random selection

    /// Multi-variant pools return values drawn from the pool — never a
    /// value that isn't in the pool and never an empty string.
    func testRandomSelectionStaysInPool() {
        let variants = ["a", "b", "c", "d"]
        let pools: [String: [String]] = [
            "title_tap": variants,
            "moan_tap":  variants,
        ]
        NotificationPhrase._testInject(pools: pools, for: "test")

        var seen: Set<String> = []
        for _ in 0..<200 {
            let title = NotificationPhrase.title(for: .tap, localeID: "test")
            XCTAssertTrue(variants.contains(title), "title \(title) not in variants")
            seen.insert(title)
        }
        // With 200 draws of 4 variants, we expect to have seen all 4.
        XCTAssertEqual(seen, Set(variants), "random selection should cover all variants")
    }
}
