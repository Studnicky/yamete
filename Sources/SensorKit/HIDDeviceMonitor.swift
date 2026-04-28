#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid
import CoreGraphics

// MARK: - HID device monitor protocol
//
// Abstracts the IOHIDManager device-discovery surface used by the three
// activity-source `isPresent` checks (trackpad / mouse / keyboard). The
// real driver wraps `IOHIDManagerCreate` / `IOHIDManagerSetDeviceMatchingMultiple`
// / `IOHIDManagerCopyDevices`. Mocks return canned `[HIDDeviceInfo]` lists
// so tests can drive presence detection deterministically without touching
// real hardware.
//
// `HIDMatcher` is a strict-typed replacement for the `[String: Any]`
// CFDictionary literals that previously appeared at every IOHIDManager
// call site.

public struct HIDMatcher: Sendable, Equatable, Hashable {
    public var transport: String?
    public var product: String?
    public var usagePage: Int?
    public var usage: Int?

    public init(transport: String? = nil,
                product: String? = nil,
                usagePage: Int? = nil,
                usage: Int? = nil) {
        self.transport = transport
        self.product = product
        self.usagePage = usagePage
        self.usage = usage
    }

    /// Bridge to the `[String: Any]` shape IOKit expects.
    public func toCFDictionary() -> CFDictionary {
        var dict: [String: Any] = [:]
        if let transport { dict[kIOHIDTransportKey] = transport }
        if let product   { dict[kIOHIDProductKey]   = product }
        if let usagePage { dict[kIOHIDDeviceUsagePageKey] = usagePage }
        if let usage     { dict[kIOHIDDeviceUsageKey]     = usage }
        return dict as CFDictionary
    }
}

public struct HIDDeviceInfo: Sendable, Equatable {
    public let transport: String
    public let product: String
    public let vendorID: Int
    public let productID: Int

    public init(transport: String, product: String, vendorID: Int, productID: Int) {
        self.transport = transport
        self.product = product
        self.vendorID = vendorID
        self.productID = productID
    }
}

public protocol HIDDeviceMonitor: Sendable {
    /// Query the system for HID devices matching any of the given
    /// matchers. Empty matcher list returns nothing.
    func queryDevices(matchers: [HIDMatcher]) -> [HIDDeviceInfo]

    /// True if the host has any built-in display (laptop). Distinct from
    /// device matching — uses `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`.
    func hasBuiltInDisplay() -> Bool
}

// MARK: - Real implementation

/// Production IOHIDManager + CoreGraphics-backed driver.
public final class RealHIDDeviceMonitor: HIDDeviceMonitor, @unchecked Sendable {
    // `@unchecked Sendable` rationale: stateless wrapper. IOHIDManager
    // instances are created and released within a single call.

    public init() {}

    public func queryDevices(matchers: [HIDMatcher]) -> [HIDDeviceInfo] {
        guard !matchers.isEmpty else { return [] }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let cfMatchers = matchers.map { $0.toCFDictionary() } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, cfMatchers)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { device in
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let product   = IOHIDDeviceGetProperty(device, kIOHIDProductKey   as CFString) as? String ?? ""
            let vendor    = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey  as CFString) as? Int) ?? 0
            let pid       = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            return HIDDeviceInfo(transport: transport, product: product, vendorID: vendor, productID: pid)
        }
    }

    public func hasBuiltInDisplay() -> Bool {
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        guard onlineCount > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount)
        return ids.prefix(Int(onlineCount)).contains(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}
