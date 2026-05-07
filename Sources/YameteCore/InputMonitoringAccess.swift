import Foundation
import IOKit.hid

/// TCC contract for the macOS Input Monitoring privilege class
/// (`kIOHIDRequestTypeListenEvent`). Yamete needs this access for three
/// kernel-level HID paths: `MouseActivitySource`'s click detection,
/// `KeyboardActivitySource`'s keypress detection, and `RealLEDBrightnessDriver`'s
/// Caps Lock LED writes. None of these can be detected from the App Sandbox;
/// the unsandboxed Direct build prompts the user once and persists the grant
/// per cdhash.
///
/// The grant is fragile in development: every `make install` ad-hoc-resigns
/// the bundle, changing its cdhash, and macOS silently revokes the existing
/// grant. macOS does NOT report this back as an error from
/// `IOHIDManagerOpen` / `IOHIDManagerRegisterInputValueCallback` — those
/// calls succeed but no input events are ever delivered. The only honest
/// signal is `IOHIDCheckAccess`, which is what this helper wraps.
///
/// Usage:
/// • Call `requestIfUnknown()` ONCE per app launch (typically from
///   `Yamete.bootstrap()`). macOS only honors a single
///   `IOHIDRequestAccess` prompt per process lifetime; subsequent calls
///   return the cached decision without re-prompting.
/// • Call `status()` from a foreground notification observer to refresh
///   the published flag after the user round-trips through System
///   Settings — `status()` is purely a read, never prompts, safe from
///   any actor.
/// • Surface a `.denied` result in the menu UI with a button that opens
///   `settingsURL`; the user MUST grant in System Settings since macOS
///   will not present another in-process prompt this lifetime.
public enum InputMonitoringAccess {

    /// Three-state TCC outcome for the Input Monitoring privilege class.
    public enum Status: Sendable, Equatable {
        /// User has explicitly granted access; HID input callbacks will
        /// be delivered to this process.
        case granted
        /// User has explicitly denied access OR a previously-granted
        /// access was silently revoked (most commonly because the bundle
        /// cdhash changed across an ad-hoc-signed reinstall). Callbacks
        /// are not delivered. The user must re-grant via System Settings.
        case denied
        /// Status has not been set — the user has never seen the prompt
        /// for this bundle. This is the only state in which a process
        /// can successfully invoke `IOHIDRequestAccess`.
        case unknown
    }

    /// Read current TCC status without side effects. Safe from any
    /// actor; never prompts. Use this from foreground observers or any
    /// code path that wants to report status without driving UI.
    public static func status() -> Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown
        }
    }

    /// Trigger the system Input Monitoring prompt iff status is
    /// `.unknown`. Returns the resulting status. Idempotent on
    /// `.granted` and `.denied` — macOS only honors one prompt per
    /// process lifetime, so calling this repeatedly after a decision
    /// has been made will not re-prompt; subsequent calls return the
    /// cached status.
    ///
    /// Call this once per app launch from `Yamete.bootstrap()`. Source
    /// `start()` paths should NOT call this — they should call `status()`
    /// and bail without prompting. Letting every source prompt at
    /// pipeline start would race for the one allowed prompt and produce
    /// non-deterministic UX.
    public static func requestIfUnknown() -> Status {
        let current = status()
        guard current == .unknown else { return current }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? .granted : .denied
    }

    /// Privacy & Security pane deep-link to the Input Monitoring entry
    /// list. Open via `NSWorkspace.shared.open(_:)`. The path the user
    /// lands on contains every app that has prompted for Input
    /// Monitoring — Yamete+'s row will be visible there even if
    /// its grant has been silently revoked, so the user can flip it
    /// back on without hunting through nested panes.
    public static let settingsURL: URL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!
}
