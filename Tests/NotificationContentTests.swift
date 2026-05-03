import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Verifies every notification posted by `NotificationResponder` carries the
/// `.active` interruption level + `relevanceScore == 1.0`. macOS suppresses
/// passive-level banners while the app is active or under Focus, and a stale
/// regression once defaulted every reaction's notification to `.passive` —
/// silently swallowing every banner. The assertions here lock both fields
/// down per `ReactionKind`.
@MainActor
final class NotificationContentTests: XCTestCase {

    func testEveryReactionKindPostsAtActiveInterruptionLevel() async throws {
        for kind in ReactionKind.allCases {
            let mock = MockSystemNotificationDriver()
            mock.setAuth(.authorized)
            let responder = NotificationResponder(driver: mock, localeProvider: { "en" })
            let provider = MockConfigProvider()
            provider.notification = NotificationOutputConfig(
                enabled: true,
                perReaction: MockConfigProvider.allKindsEnabled(),
                dismissAfter: 0.05,
                localeID: "en"
            )
            let fired = Self.firedReaction(kind: kind, intensity: 0.5)
            await responder.action(fired, multiplier: 1.0, provider: provider)

            guard let last = mock.lastPostedContent else {
                XCTFail("[\(kind.rawValue)] no notification posted")
                continue
            }
            XCTAssertEqual(last.interruptionLevel, .active,
                           "[\(kind.rawValue)] interruptionLevel must be .active so macOS displays the banner")
            XCTAssertEqual(last.relevanceScore, 1.0, accuracy: 0.0001,
                           "[\(kind.rawValue)] relevanceScore must be 1.0 so rapid reactions don't get coalesced/hidden")
        }
    }

    /// One concrete crash regression we want locked: notifications must NOT
    /// post at `.passive`. This is asserted globally (independent of any
    /// per-kind dispatch) so any future code path that builds notification
    /// content has to either use the canonical responder or change the
    /// pinned value here on purpose.
    func testNotificationLevelIsNeverPassive() async throws {
        let mock = MockSystemNotificationDriver()
        mock.setAuth(.authorized)
        let responder = NotificationResponder(driver: mock, localeProvider: { "en" })
        let provider = MockConfigProvider()
        provider.notification = NotificationOutputConfig(
            enabled: true,
            perReaction: MockConfigProvider.allKindsEnabled(),
            dismissAfter: 0.05,
            localeID: "en"
        )
        let fired = Self.firedReaction(kind: .impact, intensity: 0.5)
        await responder.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertNotNil(mock.lastPostedContent)
        XCTAssertNotEqual(mock.lastPostedContent?.interruptionLevel, .passive,
                          "passive banners get suppressed by macOS — never the right level for a reaction")
    }

    static func firedReaction(kind: ReactionKind, intensity: Float) -> FiredReaction {
        FiredReaction(
            reaction: Self.reaction(for: kind, intensity: intensity),
            clipDuration: 0.05,
            soundURL: nil,
            faceIndices: [0],
            publishedAt: Date()
        )
    }

    static func reaction(for kind: ReactionKind, intensity: Float) -> Reaction {
        switch kind {
        case .impact:
            return .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: []))
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
