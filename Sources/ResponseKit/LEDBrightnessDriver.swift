#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid
import os
import ObjectiveC

// MARK: - LED brightness driver protocol
//
// Abstracts the two LED hardware boundaries used by `LEDFlash`:
//   1. Keyboard backlight via the private `KeyboardBrightnessClient` class
//      (CoreBrightness.framework, looked up via NSClassFromString and
//      message-sent through `unsafeBitCast`-resolved IMPs).
//   2. Caps Lock LED via IOHIDManager device + element discovery and
//      `IOHIDDeviceSetValue`.
//
// `LEDFlash` becomes a thin policy class that drives the flash pattern
// envelope. All `dlopen` / `unsafeBitCast` / `IOHIDManager` plumbing is
// confined to `RealLEDBrightnessDriver`. Tests inject a mock that records
// every `setLevel` / `capsLockSet` call and lets a test assert the flash
// pattern emitted by the policy class without touching real hardware.

public protocol LEDBrightnessDriver: AnyObject, Sendable {
    /// True if CoreBrightness loaded and the keyboard-backlight client is
    /// available on this host (Mac Pro / Mini etc. report false).
    var keyboardBacklightAvailable: Bool { get }

    /// True if Input Monitoring TCC access is granted for Caps Lock LED writes.
    /// Real driver requests on construction and reports the granted state. Mocks
    /// expose a setter so tests can drive the granted/denied paths deterministically.
    var capsLockAccessGranted: Bool { get }

    /// Read the current keyboard brightness. Returns `nil` when the
    /// backlight client is unavailable so the caller can fall back to a
    /// stored launch-time level.
    func currentLevel() -> Float?

    /// Write a new keyboard brightness level (0...1). No-op when the
    /// backlight client is unavailable.
    func setLevel(_ level: Float)

    /// Read the auto-brightness flag. Defaults to `true` if unavailable.
    func isAutoEnabled() -> Bool

    /// Write the auto-brightness flag. No-op when unavailable.
    func setAutoEnabled(_ enabled: Bool)

    /// Suspend or resume the kb idle-dimming timer. No-op when unavailable.
    func setIdleDimmingSuspended(_ suspended: Bool)

    /// Set every Caps Lock LED element on every connected keyboard.
    /// No-op when Caps Lock access has not been granted.
    func capsLockSet(_ on: Bool)
}

// MARK: - Real implementation

/// Production driver. Loads `CoreBrightness.framework` lazily, looks up the
/// `KeyboardBrightnessClient` class, requests Input Monitoring access on
/// `setUp`, and discovers Caps Lock LED elements via `IOHIDManager`.
public final class RealLEDBrightnessDriver: LEDBrightnessDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: the driver wraps `IOHIDManager`
    // (a CFTypeRef that is intrinsically thread-safe) plus an `AnyObject`
    // backed by the private `KeyboardBrightnessClient` class. The driver
    // is owned by a single `LEDFlash` instance confined to MainActor;
    // method dispatch into the C function pointers happens on that actor.

    private static let log = AppLog(category: "RealLEDBrightnessDriver")

    private static let coreBrightnessLoaded: Bool = {
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() ?? false
    }()

    private static func makeKeyboardBrightnessClient() -> AnyObject? {
        _ = coreBrightnessLoaded
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }

    private static let kHIDPageGenericDesktop: Int = 0x01
    private static let kHIDUsageGDKeyboard: Int = 0x06
    private static let kHIDPageLEDs: Int = 0x08
    private static let kHIDUsageLEDCapsLock: Int = 0x02

    private let manager: IOHIDManager
    private let kbClient: AnyObject?
    private let accessState = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        kbClient = Self.makeKeyboardBrightnessClient()
        // Device-level matching: keyboards. Confined to this Real driver —
        // HIDMatcher lives in SensorKit which ResponseKit does not depend on.
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Self.kHIDPageGenericDesktop,
            kIOHIDDeviceUsageKey:     Self.kHIDUsageGDKeyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        // Request Input Monitoring access for Caps Lock LED writes. The
        // public IOHIDCheckAccess is synchronous; IOHIDRequestAccess shows
        // the system dialog when status is .unknown.
        let granted: Bool = {
            let currentAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            switch currentAccess {
            case kIOHIDAccessTypeGranted: return true
            case kIOHIDAccessTypeUnknown: return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            default:                      return false  // explicitly denied
            }
        }()
        accessState.withLock { $0 = granted }
        if granted {
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        } else {
            Self.log.warning("entity:CapsLockLED wasInvalidatedBy activity:TCC — Input Monitoring not granted")
        }
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public var keyboardBacklightAvailable: Bool { kbClient != nil }

    public var capsLockAccessGranted: Bool { accessState.withLock { $0 } }

    public func currentLevel() -> Float? {
        guard kbClient != nil else { return nil }
        return readFloat(selector: "brightnessForKeyboard:")
    }

    public func setLevel(_ level: Float) {
        guard let client = kbClient else { return }
        let selStr = "setBrightness:fadeSpeed:commit:forKeyboard:"
        let sel = NSSelectorFromString(selStr)
        guard let m = class_getInstanceMethod(object_getClass(client), sel) else { return }
        guard validateArgCount(m, expected: 4) else { return }
        let f = unsafeBitCast(method_getImplementation(m),
                              to: (@convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool).self)
        _ = f(client, sel, level, 0, true, 1)
    }

    public func isAutoEnabled() -> Bool {
        guard let client = kbClient else { return true }
        let sel = NSSelectorFromString("autoBrightnessEnabledForKeyboard:")
        guard let m = class_getInstanceMethod(object_getClass(client), sel) else { return true }
        guard validateArgCount(m, expected: 1) else { return true }
        let f = unsafeBitCast(method_getImplementation(m),
                              to: (@convention(c) (AnyObject, Selector, UInt64) -> Bool).self)
        return f(client, sel, 1)
    }

    public func setAutoEnabled(_ enabled: Bool) {
        guard let client = kbClient else { return }
        let sel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        guard let m = class_getInstanceMethod(object_getClass(client), sel) else { return }
        guard validateArgCount(m, expected: 2) else { return }
        let f = unsafeBitCast(method_getImplementation(m),
                              to: (@convention(c) (AnyObject, Selector, Bool, UInt64) -> Void).self)
        f(client, sel, enabled, 1)
    }

    public func setIdleDimmingSuspended(_ suspended: Bool) {
        guard let client = kbClient else { return }
        let sel = NSSelectorFromString("suspendIdleDimming:forKeyboard:")
        guard let m = class_getInstanceMethod(object_getClass(client), sel) else { return }
        guard validateArgCount(m, expected: 2) else { return }
        let f = unsafeBitCast(method_getImplementation(m),
                              to: (@convention(c) (AnyObject, Selector, Bool, UInt64) -> Void).self)
        f(client, sel, suspended, 1)
    }

    public func capsLockSet(_ on: Bool) {
        guard accessState.withLock({ $0 }) else { return }
        let elements = capsLockElements()
        for element in elements { writeLED(element: element, on: on) }
    }

    // MARK: - Private helpers

    private func validateArgCount(_ m: Method, expected: UInt32) -> Bool {
        method_getNumberOfArguments(m) == expected + 2
    }

    private func readFloat(selector selStr: String) -> Float? {
        guard let client = kbClient else { return nil }
        let sel = NSSelectorFromString(selStr)
        guard let m = class_getInstanceMethod(object_getClass(client), sel) else { return nil }
        guard validateArgCount(m, expected: 1) else { return nil }
        let f = unsafeBitCast(method_getImplementation(m),
                              to: (@convention(c) (AnyObject, Selector, UInt64) -> Float).self)
        return f(client, sel, 1)
    }

    private func capsLockElements() -> [IOHIDElement] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var results: [IOHIDElement] = []
        let match: [String: Any] = [
            kIOHIDElementUsagePageKey: Self.kHIDPageLEDs,
            kIOHIDElementUsageKey: Self.kHIDUsageLEDCapsLock,
        ]
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, match as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            results.append(contentsOf: elements)
        }
        return results
    }

    private func writeLED(element: IOHIDElement, on: Bool) {
        let device = IOHIDElementGetDevice(element)
        guard IOHIDDeviceGetService(device) != IO_OBJECT_NULL else { return }
        let timestamp = mach_absolute_time()
        let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, timestamp, on ? 1 : 0)
        _ = IOHIDDeviceSetValue(device, element, value)
    }
}
