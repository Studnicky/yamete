#if canImport(YameteCore)
import YameteCore
#endif
import AppKit

// MARK: - NSEvent global monitor protocol
//
// Abstracts `NSEvent.addGlobalMonitorForEvents` + `NSEvent.removeMonitor`
// for the three activity sources (trackpad / mouse / keyboard). The real
// driver delegates to NSEvent directly. Mocks record installations,
// expose handlers so tests can synthesize events, and verify removal
// happened.
//
// The opaque token returned by NSEvent has type `Any?` — we expose it
// as `EventMonitorToken` so tests can inject a typed sentinel and the
// production driver can wrap the NSEvent return.

public final class EventMonitorToken: @unchecked Sendable {
    // `@unchecked Sendable` rationale: the token is immutable after
    // construction. `payload` is `AnyObject?` — its contents may not be
    // formally Sendable (NSEvent's removeMonitor accepts `Any` and the
    // production driver stores its raw token there) but the token
    // object itself is only used as an opaque key passed back from the
    // installer to the remover; no inspection of `payload` happens
    // outside the driver that produced the token.
    public let payload: AnyObject?

    public init(payload: AnyObject? = nil) {
        self.payload = payload
    }
}

@MainActor
public protocol EventMonitor: AnyObject {
    /// Install a global event handler. Returns a token that must be
    /// passed to `removeMonitor` to deregister. Returns `nil` when the
    /// monitor cannot be installed (e.g. mock configured to fail).
    ///
    /// The handler is invoked on the main thread by NSEvent (and by the
    /// real driver / mocks). It is NOT marked `@Sendable` because
    /// NSEvent is itself not formally Sendable; the real
    /// `addGlobalMonitorForEvents` has the same constraint.
    func addGlobalMonitor(matching: NSEvent.EventTypeMask,
                          handler: @escaping (NSEvent) -> Void) -> EventMonitorToken?

    /// Remove a previously installed monitor. Idempotent.
    func removeMonitor(_ token: EventMonitorToken)
}

// MARK: - Real implementation

/// Production NSEvent-backed monitor.
@MainActor
public final class RealEventMonitor: EventMonitor {
    /// Wraps the raw `Any?` returned by NSEvent so the token can carry
    /// it as an `AnyObject`. NSEvent returns the monitor as `Any?` but
    /// the documented contract is that you pass it back to
    /// `NSEvent.removeMonitor`.
    //
    // `@unchecked Sendable` rationale: `raw` is whatever NSEvent hands
    // back from `addGlobalMonitorForEvents` — opaque, not formally
    // Sendable, but immutable for the lifetime of the box. The box is
    // only used to pair install with remove; nothing inspects `raw`.
    private final class TokenBox: @unchecked Sendable {
        let raw: Any
        init(_ raw: Any) { self.raw = raw }
    }

    public init() {}

    public func addGlobalMonitor(matching: NSEvent.EventTypeMask,
                                 handler: @escaping (NSEvent) -> Void) -> EventMonitorToken? {
        guard let raw = NSEvent.addGlobalMonitorForEvents(matching: matching, handler: { event in
            handler(event)
        }) else {
            return nil
        }
        return EventMonitorToken(payload: TokenBox(raw))
    }

    public func removeMonitor(_ token: EventMonitorToken) {
        guard let box = token.payload as? TokenBox else { return }
        NSEvent.removeMonitor(box.raw)
    }
}
