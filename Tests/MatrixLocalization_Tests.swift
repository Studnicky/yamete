import XCTest
@testable import YameteCore
@testable import ResponseKit

/// NotificationPhrase localization matrix:
///   ReactionKind × locale × pool injection × fallback resolution
///
/// The SPM test bundle does not include `App/Resources/*.lproj` strings
/// (those are bundled into the `.app` by the Makefile only). So this matrix
/// drives the injection seam and asserts:
///   1. Every event-shaped `ReactionKind` produces non-empty title+body
///      when both pools are populated for its locale.
///   2. Every `ImpactTier` produces non-empty title+body when both
///      `title_<tier>` and `moan_<tier>` pools are populated.
///   3. Locale fallback: when the preferred locale has no pools, we fall
///      back to `en`. When `en` is also empty, the title falls back to the
///      raw key (documented contract).
///   4. The Japanese cell exercises a non-Latin locale identifier so a
///      regression that hard-codes "en" is caught.
@MainActor
final class MatrixLocalization_Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        NotificationPhrase._testClear()
    }

    override func tearDown() {
        NotificationPhrase._testClear()
        super.tearDown()
    }

    // MARK: - Event kinds covered by Events.strings on disk

    /// These match the prefixes present in `App/Resources/en.lproj/Events.strings`.
    /// Must stay in sync with that file or the matrix shrinks silently.
    private static let eventKindsWithStrings: [ReactionKind] = [
        .usbAttached, .usbDetached,
        .acConnected, .acDisconnected,
        .audioPeripheralAttached, .audioPeripheralDetached,
        .bluetoothConnected, .bluetoothDisconnected,
        .thunderboltAttached, .thunderboltDetached,
        .displayConfigured, .willSleep, .didWake,
    ]

    // MARK: - Sample reactions per kind

    private func sampleReaction(for kind: ReactionKind) -> Reaction {
        switch kind {
        case .impact:                   return .impact(.init(timestamp: Date(), intensity: 0.5, confidence: 1.0, sources: []))
        case .usbAttached:              return .usbAttached(.init(name: "x", vendorID: 0, productID: 0))
        case .usbDetached:              return .usbDetached(.init(name: "x", vendorID: 0, productID: 0))
        case .acConnected:              return .acConnected
        case .acDisconnected:           return .acDisconnected
        case .audioPeripheralAttached: return .audioPeripheralAttached(.init(uid: "u", name: "n"))
        case .audioPeripheralDetached: return .audioPeripheralDetached(.init(uid: "u", name: "n"))
        case .bluetoothConnected:       return .bluetoothConnected(.init(address: "a", name: "n"))
        case .bluetoothDisconnected:    return .bluetoothDisconnected(.init(address: "a", name: "n"))
        case .thunderboltAttached:      return .thunderboltAttached(.init(name: "n"))
        case .thunderboltDetached:      return .thunderboltDetached(.init(name: "n"))
        case .displayConfigured:        return .displayConfigured
        case .willSleep:                return .willSleep
        case .didWake:                  return .didWake
        case .trackpadTouching:         return .trackpadTouching
        case .trackpadSliding:          return .trackpadSliding
        case .trackpadContact:          return .trackpadContact
        case .trackpadTapping:          return .trackpadTapping
        case .trackpadCircling:         return .trackpadCircling
        case .mouseClicked:             return .mouseClicked
        case .mouseScrolled:            return .mouseScrolled
        case .keyboardTyped:            return .keyboardTyped
        case .gyroSpike:            return .gyroSpike
        case .lidOpened:            return .lidOpened
        case .lidClosed:            return .lidClosed
        case .lidSlammed:           return .lidSlammed
        }
    }

    // MARK: - Matrix A: every event kind × en

    /// With injected pools, every event kind's title + body must be non-empty
    /// AND not equal to the lookup key (raw-key bug).
    func testEventPhrasingNonEmptyForEveryEventKindEN() {
        var pools: [String: [String]] = [:]
        for kind in Self.eventKindsWithStrings {
            pools["title_\(kind.rawValue)"] = ["en-title-\(kind.rawValue)"]
            pools["body_\(kind.rawValue)"] = ["en-body-\(kind.rawValue)"]
        }
        NotificationPhrase._testInjectEvents(pools: pools, for: "en")

        for kind in Self.eventKindsWithStrings {
            let phrase = NotificationPhrase.phrasing(for: sampleReaction(for: kind), preferredLocale: "en")
            XCTAssertFalse(phrase.title.isEmpty,
                "[locale=en kind=\(kind)] title must be non-empty")
            XCTAssertFalse(phrase.body.isEmpty,
                "[locale=en kind=\(kind)] body must be non-empty")
            XCTAssertNotEqual(phrase.title, kind.rawValue,
                "[locale=en kind=\(kind)] title must not be raw key '\(kind.rawValue)'")
        }
    }

    // MARK: - Matrix B: every event kind × ja

    /// Same coverage for `ja`. Different locale identifier proves the cache
    /// keying is per-locale and not hard-coded to `en`.
    func testEventPhrasingNonEmptyForEveryEventKindJA() {
        var pools: [String: [String]] = [:]
        for kind in Self.eventKindsWithStrings {
            pools["title_\(kind.rawValue)"] = ["ja-title-\(kind.rawValue)"]
            pools["body_\(kind.rawValue)"] = ["ja-body-\(kind.rawValue)"]
        }
        NotificationPhrase._testInjectEvents(pools: pools, for: "ja")

        for kind in Self.eventKindsWithStrings {
            let phrase = NotificationPhrase.phrasing(for: sampleReaction(for: kind), preferredLocale: "ja")
            XCTAssertEqual(phrase.title, "ja-title-\(kind.rawValue)",
                "[locale=ja kind=\(kind)] title must come from ja pools, got '\(phrase.title)'")
            XCTAssertEqual(phrase.body, "ja-body-\(kind.rawValue)",
                "[locale=ja kind=\(kind)] body must come from ja pools, got '\(phrase.body)'")
        }
    }

    // MARK: - Matrix C: every ImpactTier × en moans pools

    func testImpactPhrasingNonEmptyForEveryTier() {
        let tiers: [ImpactTier] = ImpactTier.allCases
        var pools: [String: [String]] = [:]
        for tier in tiers {
            let slug = tierSlug(tier)
            pools["title_\(slug)"] = ["en-title-\(slug)"]
            pools["moan_\(slug)"] = ["en-moan-\(slug)"]
        }
        NotificationPhrase._testInject(pools: pools, for: "en")

        for tier in tiers {
            let intensity = intensityFor(tier: tier)
            let reaction = Reaction.impact(.init(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: []))
            let phrase = NotificationPhrase.phrasing(for: reaction, preferredLocale: "en")
            XCTAssertFalse(phrase.title.isEmpty,
                "[locale=en tier=\(tier) intensity=\(intensity)] title must be non-empty")
            XCTAssertFalse(phrase.body.isEmpty,
                "[locale=en tier=\(tier) intensity=\(intensity)] body must be non-empty")
            XCTAssertEqual(phrase.title, "en-title-\(tierSlug(tier))",
                "[locale=en tier=\(tier)] title must resolve to injected en value")
        }
    }

    // MARK: - Matrix D: locale fallback

    /// Unsupported locale (`zz`) with pools only in `en` falls back to `en`.
    func testUnsupportedLocaleFallsBackToEN() {
        let kind = ReactionKind.usbAttached
        var enPools: [String: [String]] = [:]
        enPools["title_\(kind.rawValue)"] = ["en-fallback-title"]
        enPools["body_\(kind.rawValue)"] = ["en-fallback-body"]
        NotificationPhrase._testInjectEvents(pools: enPools, for: "en")
        // Inject zz with EMPTY pools so the loader's fallback path runs
        NotificationPhrase._testInjectEvents(pools: [:], for: "zz")

        let phrase = NotificationPhrase.phrasing(for: sampleReaction(for: kind), preferredLocale: "zz")
        XCTAssertEqual(phrase.title, "en-fallback-title",
            "[locale=zz kind=usbAttached] title must fall back to en, got '\(phrase.title)'")
        XCTAssertEqual(phrase.body, "en-fallback-body",
            "[locale=zz kind=usbAttached] body must fall back to en, got '\(phrase.body)'")
    }

    /// When the preferred locale lacks pools for an impact tier, the resolver
    /// returns the en localeID instead. Asserts on `resolveLocale` directly.
    func testImpactResolveLocaleFallback() {
        // Inject en with pools for `tap`, leave zz empty
        NotificationPhrase._testInject(pools: ["title_tap": ["t"], "moan_tap": ["m"]], for: "en")
        NotificationPhrase._testInject(pools: [:], for: "zz")

        let resolved = NotificationPhrase.resolveLocale(preferred: "zz", for: .tap)
        XCTAssertEqual(resolved, "en",
            "[locale=zz tier=tap] resolveLocale must fall back to 'en', got '\(resolved)'")

        let resolvedEn = NotificationPhrase.resolveLocale(preferred: "en", for: .tap)
        XCTAssertEqual(resolvedEn, "en",
            "[locale=en tier=tap] resolveLocale must keep 'en' when pools present, got '\(resolvedEn)'")
    }

    /// When neither preferred nor en has body for a kind, body falls back to
    /// empty string and title falls back to raw key — documented contract.
    func testMissingKeyFallsBackToRawKey() {
        let kind = ReactionKind.thunderboltAttached
        // No injection at all — ensures both en and zz return empty pools
        NotificationPhrase._testInjectEvents(pools: [:], for: "en")
        NotificationPhrase._testInjectEvents(pools: [:], for: "zz")

        let phrase = NotificationPhrase.phrasing(for: sampleReaction(for: kind), preferredLocale: "zz")
        XCTAssertEqual(phrase.title, kind.rawValue,
            "[locale=zz kind=thunderboltAttached] missing-key title falls back to raw key")
        XCTAssertEqual(phrase.body, "",
            "[locale=zz kind=thunderboltAttached] missing-key body falls back to empty string")
    }

    // MARK: - Helpers

    private func tierSlug(_ tier: ImpactTier) -> String {
        switch tier {
        case .tap: "tap"; case .light: "light"; case .medium: "medium"; case .firm: "firm"; case .hard: "hard"
        }
    }

    private func intensityFor(tier: ImpactTier) -> Float {
        switch tier {
        case .tap: 0.10
        case .light: 0.25
        case .medium: 0.50
        case .firm: 0.70
        case .hard: 0.90
        }
    }
}
