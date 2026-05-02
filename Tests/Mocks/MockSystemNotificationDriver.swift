import Foundation
import os
@testable import ResponseKit

enum MockNotificationError: Error, Sendable {
    case postFailed
}

/// Test double for `SystemNotificationDriver`. Defaults: authorized,
/// post succeeds. Tests flip `cannedAuth` and `shouldFailPost` to drive
/// every documented authorization + delivery state.
final class MockSystemNotificationDriver: SystemNotificationDriver, @unchecked Sendable {
    struct PostRecord: Sendable, Equatable {
        let identifier: String
        let title: String
        let body: String
        let threadID: String
        let categoryID: String
        let interruptionLevel: NotificationContent.InterruptionLevel
        let relevanceScore: Double
    }

    private struct State: Sendable {
        var auth: NotificationAuth = .authorized
        var requestAuthorizationGranted: Bool = true
        var shouldFailPost: Bool = false
        var posts: [PostRecord] = []
        var lastContent: NotificationContent?
        var removed: [String] = []
        var requestAuthorizationCalls: Int = 0
        var currentAuthorizationCalls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    func setAuth(_ value: NotificationAuth) { state.withLock { $0.auth = value } }
    func setRequestGranted(_ value: Bool) { state.withLock { $0.requestAuthorizationGranted = value } }
    func setShouldFailPost(_ value: Bool) { state.withLock { $0.shouldFailPost = value } }

    var posts: [PostRecord] { state.withLock { $0.posts } }
    var removed: [String] { state.withLock { $0.removed } }
    var requestAuthorizationCalls: Int { state.withLock { $0.requestAuthorizationCalls } }
    var currentAuthorizationCalls: Int { state.withLock { $0.currentAuthorizationCalls } }

    /// Last posted `NotificationContent` (full struct, not just the recorded
    /// summary fields). Tests assert exact `interruptionLevel` /
    /// `relevanceScore` values via this seam.
    var lastPostedContent: NotificationContent? { state.withLock { $0.lastContent } }

    func currentAuthorization() async -> NotificationAuth {
        state.withLock { s in
            s.currentAuthorizationCalls += 1
            return s.auth
        }
    }

    func requestAuthorization() async -> Bool {
        state.withLock { s in
            s.requestAuthorizationCalls += 1
            // Granting moves auth to authorized. Denying leaves notDetermined → denied.
            if s.requestAuthorizationGranted {
                s.auth = .authorized
            } else {
                s.auth = .denied
            }
            return s.requestAuthorizationGranted
        }
    }

    func post(content: NotificationContent, identifier: String) async throws {
        try state.withLock { s -> Void in
            if s.shouldFailPost { throw MockNotificationError.postFailed }
            s.posts.append(PostRecord(
                identifier: identifier,
                title: content.title,
                body: content.body,
                threadID: content.threadID,
                categoryID: content.categoryID,
                interruptionLevel: content.interruptionLevel,
                relevanceScore: content.relevanceScore
            ))
            s.lastContent = content
        }
    }

    func remove(identifier: String) {
        state.withLock { $0.removed.append(identifier) }
    }
}
