import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Notifications use an `Events.strings` table keyed by reaction kind to look
/// up `title_<kind>_<n>` / `body_<kind>_<n>` pools. If a kind is missing from
/// the table the responder falls back to the kind raw-value as title and an
/// empty body — which still posts but ships an embarrassingly broken UI.
///
/// In the SPM test bundle there are no `.lproj` resources, so the loader is
/// driven via the test seam (`NotificationPhrase._testInject`). The seam only
/// covers the impact-tier pools, not the event pools, so for non-impact kinds
/// we assert the documented fallback shape: title falls back to `key`, body
/// falls back to empty. For `.impact`, we inject pools and assert both fields
/// resolve non-empty.
@MainActor
final class NotificationPhraseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NotificationPhrase._testClear()
    }

    override func tearDown() {
        NotificationPhrase._testClear()
        super.tearDown()
    }

    /// Impact tiers route through `Moans.strings` pools. With pools injected,
    /// both title and body must resolve to a non-empty string for every tier.
    func testImpactPhrasingNonEmptyForEveryTier() {
        // Inject one entry per pool for both prefixes × every tier.
        var pools: [String: [String]] = [:]
        for slug in ["tap", "light", "medium", "firm", "hard"] {
            pools["title_\(slug)"] = ["title-\(slug)"]
            pools["moan_\(slug)"]  = ["moan-\(slug)"]
        }
        NotificationPhrase._testInject(pools: pools, for: "en")

        let intensities: [Float] = [0.05, 0.25, 0.5, 0.75, 1.0]
        for intensity in intensities {
            let reaction = Reaction.impact(FusedImpact(
                timestamp: Date(), intensity: intensity, confidence: 1.0, sources: []
            ))
            let phrase = NotificationPhrase.phrasing(for: reaction, preferredLocale: "en")
            XCTAssertFalse(phrase.title.isEmpty, "impact intensity=\(intensity) title must be non-empty")
            XCTAssertFalse(phrase.body.isEmpty,  "impact intensity=\(intensity) body must be non-empty")
        }
    }

    /// Documented fallback for non-impact kinds when no `Events.strings`
    /// resource is available: title falls back to the raw-value key string,
    /// so the title field is always non-empty and the kind is recognizable
    /// in the banner. The body is empty under the fallback. This locks the
    /// kind→key mapping so a missing dispatch case can't silently produce a
    /// blank banner.
    ///
    /// The fallback path only runs when both `eventPools(for:preferred)`
    /// and `eventPools(for:fallback)` come back empty. Under SPM the test
    /// bundle has no `.lproj` resources so this is automatic; under
    /// host-app `Bundle.main` is the real `Yamete.app` which ships
    /// `Events.strings`, and without intervention the loader hands back
    /// authored strings instead. `_testClearAndDisableLoad` short-circuits
    /// the bundle-driven loader so the fallback is exercised under both
    /// build environments.
    func testEventFallbackUsesKindRawValueAsTitle() {
        NotificationPhrase._testClearAndDisableLoad()
        for kind in ReactionKind.allCases where kind != .impact {
            let reaction = ReactionForKind.make(kind: kind)
            let phrase = NotificationPhrase.phrasing(for: reaction, preferredLocale: "en")
            XCTAssertEqual(phrase.title, kind.rawValue,
                           "[\(kind.rawValue)] title must fall back to raw-value when Events.strings has no entry")
            // Body is documented as fallback-empty; the assertion locks that
            // contract so future regressions to "nil" or non-string don't
            // pass silently.
            XCTAssertEqual(phrase.body, "",
                           "[\(kind.rawValue)] body must be empty when Events.strings has no entry")
        }
    }
}

/// Tiny domain helper: build a synthetic `Reaction` for any kind. Owned by a
/// nested type rather than a free function per the global rule.
enum ReactionForKind {
    @MainActor
    static func make(kind: ReactionKind) -> Reaction {
        switch kind {
        case .impact:
            return .impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1.0, sources: []))
        case .usbAttached:              return .usbAttached(.init(name: "n", vendorID: 0, productID: 0))
        case .usbDetached:              return .usbDetached(.init(name: "n", vendorID: 0, productID: 0))
        case .acConnected:              return .acConnected
        case .acDisconnected:           return .acDisconnected
        case .audioPeripheralAttached:  return .audioPeripheralAttached(.init(uid: "u", name: "n"))
        case .audioPeripheralDetached:  return .audioPeripheralDetached(.init(uid: "u", name: "n"))
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
}
