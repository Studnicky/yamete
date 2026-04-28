#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import CoreGraphics

// MARK: - Display brightness driver protocol
//
// Abstracts the DisplayServices.framework dlopen + symbol resolution
// embedded in `DisplayBrightnessFlash`. The real driver loads the
// private framework once and resolves
// `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness`. Tests
// inject a mock that records every `set` call and lets a test specify
// the value returned by `get`.

public protocol DisplayBrightnessDriver: AnyObject, Sendable {
    /// True if DisplayServices loaded and the symbols resolved.
    var isAvailable: Bool { get }

    /// Read the current brightness for the given display. Returns `nil`
    /// if the read failed or the framework is unavailable.
    func get(displayID: CGDirectDisplayID) -> Float?

    /// Write a new brightness level for the given display. No-op when
    /// the framework is unavailable.
    func set(displayID: CGDirectDisplayID, level: Float)
}

// MARK: - Real implementation

/// Production driver. Loads `DisplayServices.framework` on `init` and
/// resolves the two symbols once. Reuses the resolved function pointers
/// for the lifetime of the process.
public final class RealDisplayBrightnessDriver: DisplayBrightnessDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: the resolved C function pointers
    // are immutable after `init` and the C functions themselves are
    // documented to be safe to call from any thread (DisplayServices
    // performs its own internal serialization).

    private static let log = AppLog(category: "RealDisplayBrightnessDriver")

    private typealias GetFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getB: GetFunc?
    private let setB: SetFunc?

    public init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_GLOBAL) {
            getB = unsafeBitCast(dlsym(handle, "DisplayServicesGetBrightness"), to: GetFunc?.self)
            setB = unsafeBitCast(dlsym(handle, "DisplayServicesSetBrightness"), to: SetFunc?.self)
            if getB != nil, setB != nil {
                Self.log.info("entity:DisplayServices wasGeneratedBy activity:Init")
            } else {
                Self.log.warning("entity:DisplayServices wasInvalidatedBy activity:Init — symbols not found")
            }
        } else {
            getB = nil
            setB = nil
            Self.log.warning("entity:DisplayServices wasInvalidatedBy activity:Init — framework unavailable")
        }
    }

    public var isAvailable: Bool { getB != nil && setB != nil }

    public func get(displayID: CGDirectDisplayID) -> Float? {
        guard let getB else { return nil }
        var brightness: Float = 0
        let result = getB(displayID, &brightness)
        guard result == 0 else { return nil }
        return brightness
    }

    public func set(displayID: CGDirectDisplayID, level: Float) {
        _ = setB?(displayID, level.clamped(to: 0...1))
    }
}
