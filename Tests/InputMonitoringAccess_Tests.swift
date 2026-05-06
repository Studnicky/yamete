import XCTest
@testable import YameteCore

/// Behavioural cells for `InputMonitoringAccess` — the helper Yamete
/// uses to consult and prompt for the macOS Input Monitoring TCC class
/// (`kIOHIDRequestTypeListenEvent`). These tests pin the contract that
/// production callers (Yamete.bootstrap, source.start paths) rely on:
/// the URL is a valid Privacy & Security deep-link, the status accessor
/// is stable across calls, and `requestIfUnknown` never re-prompts after
/// a decision is cached.
final class InputMonitoringAccess_Tests: XCTestCase {

    /// `settingsURL` is a non-nil URL pointing at the System Settings
    /// Privacy & Security pane scoped to Input Monitoring. The scheme
    /// must be `x-apple.systempreferences:` for `NSWorkspace.shared.open`
    /// to route it correctly to the System Settings app rather than
    /// fall back to a browser.
    func testSettingsURL_isValidSystemSettingsDeepLink() {
        let url = InputMonitoringAccess.settingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences",
            "[input-monitoring=settings-url-scheme] settingsURL must use the x-apple.systempreferences scheme so System Settings opens (got \(url.scheme ?? "nil"))")
        XCTAssertTrue(url.absoluteString.contains("Privacy_ListenEvent"),
            "[input-monitoring=settings-url-anchor] settingsURL must reference the Privacy_ListenEvent anchor so the pane lands on Input Monitoring (got \(url.absoluteString))")
    }

    /// `status()` is a pure read of the current TCC state — calling it
    /// repeatedly without intervening `requestIfUnknown` returns the
    /// same value. This pins the no-side-effect contract that the
    /// foreground-active observer relies on.
    func testStatus_isStableAcrossCalls() {
        let first = InputMonitoringAccess.status()
        let second = InputMonitoringAccess.status()
        XCTAssertEqual(first, second,
            "[input-monitoring=status-stable] consecutive status() calls must return the same value (\(first) vs \(second))")
    }

    /// `requestIfUnknown` is idempotent on non-`.unknown` states. macOS
    /// only honors a single `IOHIDRequestAccess` per process lifetime;
    /// once status is `.granted` or `.denied`, subsequent calls must
    /// return that same value without re-prompting. We can assert this
    /// when the test environment is in a settled state — `.granted` or
    /// `.denied` — and skip when it happens to be `.unknown` (a fresh
    /// CI environment with no prior decision recorded).
    func testRequestIfUnknown_idempotentOnSettledStates() {
        let initial = InputMonitoringAccess.status()
        guard initial != .unknown else {
            // CI environment with no cached decision; we cannot assert
            // idempotence without prompting, which we will not do from
            // a unit test.
            return
        }
        let after = InputMonitoringAccess.requestIfUnknown()
        XCTAssertEqual(after, initial,
            "[input-monitoring=requestIfUnknown-idempotent] requestIfUnknown must return the cached status without re-prompting on settled states (initial=\(initial), after=\(after))")
    }
}
