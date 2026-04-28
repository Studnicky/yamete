#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import CoreGraphics

// MARK: - Display tint driver protocol
//
// Abstracts `CGSetDisplayTransferByTable` and
// `CGDisplayRestoreColorSyncSettings`. The real driver delegates to
// CoreGraphics directly. Mocks record gamma table sizes and a counter
// of restore calls so tests can verify the sequence without touching
// the real display.

public protocol DisplayTintDriver: AnyObject, Sendable {
    /// True when tinting is supported on the current OS. macOS 26+ rejects
    /// `CGSetDisplayTransferByTable`, so the production driver returns
    /// false there.
    var isAvailable: Bool { get }

    /// Apply gamma tables for the three RGB channels to the given display.
    /// All three arrays must have the same count. No-op when unavailable.
    func applyGamma(displayID: CGDirectDisplayID, r: [Float], g: [Float], b: [Float])

    /// Restore the system color sync defaults. Idempotent.
    func restore(displayID: CGDirectDisplayID)
}

// MARK: - Real implementation

/// Production CoreGraphics-backed driver.
public final class RealDisplayTintDriver: DisplayTintDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: the type is stateless. CoreGraphics
    // documents `CGSetDisplayTransferByTable` and
    // `CGDisplayRestoreColorSyncSettings` as thread-safe.

    public init() {}

    public var isAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
    }

    public func applyGamma(displayID: CGDirectDisplayID, r: [Float], g: [Float], b: [Float]) {
        guard isAvailable else { return }
        precondition(r.count == g.count && g.count == b.count, "gamma tables must be equal length")
        var rT = r, gT = g, bT = b
        CGSetDisplayTransferByTable(displayID, UInt32(rT.count), &rT, &gT, &bT)
    }

    public func restore(displayID: CGDirectDisplayID) {
        // CGDisplayRestoreColorSyncSettings restores all displays —
        // the displayID parameter is ignored by the production driver
        // but kept in the protocol so mocks can record it.
        _ = displayID
        CGDisplayRestoreColorSyncSettings()
    }
}
