#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
@preconcurrency import UserNotifications

// MARK: - System notification driver protocol
//
// Abstracts `UNUserNotificationCenter` for `NotificationResponder`. The
// real driver wraps the singleton notification center; mocks record
// every authorization query, post, and removal so tests can verify the
// per-reaction post sequence without touching the real notification
// center (which would actually post system banners during a test run).

/// Authorization status reported by the driver. Maps 1:1 to the
/// `UNAuthorizationStatus` cases the responder cares about.
public enum NotificationAuth: Sendable {
    case authorized
    case provisional
    case ephemeral
    case denied
    case notDetermined
    case unknown
}

/// Sendable mirror of `UNMutableNotificationContent`. The responder
/// constructs one of these per impact and hands it to the driver.
public struct NotificationContent: Sendable {
    public let title: String
    public let body: String
    public let threadID: String
    public let categoryID: String
    public let interruptionLevel: NotificationContent.InterruptionLevel
    public let relevanceScore: Double

    public enum InterruptionLevel: Sendable, Equatable {
        case passive, active, timeSensitive, critical
    }

    public init(title: String,
                body: String,
                threadID: String,
                categoryID: String,
                interruptionLevel: NotificationContent.InterruptionLevel,
                relevanceScore: Double) {
        self.title = title
        self.body = body
        self.threadID = threadID
        self.categoryID = categoryID
        self.interruptionLevel = interruptionLevel
        self.relevanceScore = relevanceScore
    }
}

public protocol SystemNotificationDriver: AnyObject, Sendable {
    /// Read the current authorization status.
    func currentAuthorization() async -> NotificationAuth

    /// Trigger an authorization request. Returns whether it was granted.
    func requestAuthorization() async -> Bool

    /// Post a notification with the given identifier.
    func post(content: NotificationContent, identifier: String) async throws

    /// Remove pending and delivered notifications with the given identifier.
    func remove(identifier: String)
}

// MARK: - Real implementation

/// Production `UNUserNotificationCenter`-backed driver.
public final class RealSystemNotificationDriver: SystemNotificationDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: the underlying singleton is
    // documented to be safe to call from any thread; the driver itself
    // is stateless.

    public init() {}

    public func currentAuthorization() async -> NotificationAuth {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.map(settings.authorizationStatus))
            }
        }
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    public func post(content: NotificationContent, identifier: String) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.threadIdentifier = content.threadID
        body.categoryIdentifier = content.categoryID
        body.sound = nil
        body.interruptionLevel = Self.map(content.interruptionLevel)
        body.relevanceScore = content.relevanceScore
        try await center.add(UNNotificationRequest(identifier: identifier, content: body, trigger: nil))
    }

    public func remove(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuth {
        switch status {
        case .authorized:    return .authorized
        case .provisional:   return .provisional
        case .ephemeral:     return .ephemeral
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .unknown
        }
    }

    private static func map(_ level: NotificationContent.InterruptionLevel) -> UNNotificationInterruptionLevel {
        switch level {
        case .passive:       return .passive
        case .active:        return .active
        case .timeSensitive: return .timeSensitive
        case .critical:      return .critical
        }
    }
}
