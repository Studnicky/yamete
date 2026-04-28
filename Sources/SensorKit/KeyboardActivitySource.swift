#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

private let log = AppLog(category: "KeyboardActivitySource")

/// Detects keyboard typing activity via IOHIDManager.
/// Requires Input Monitoring permission (kIOHIDRequestTypeListenEvent).
/// Fires `.keyboardTyped` when key-press rate crosses the configured threshold.
///
/// Static `isPresent` checks for non-SPI keyboard devices; call once at startup.
@MainActor
public final class KeyboardActivitySource: StimulusSource {
    public let id: SensorID = .keyboardActivity

    nonisolated(unsafe) private var hidManager: IOHIDManager?
    private var hidRetained: Unmanaged<KeyboardActivitySource>?
    private weak var bus: ReactionBus?

    private var keyWindow: [Date] = []
    private var typingGate: Date = .distantPast
    private let typingDebounce: TimeInterval = 0.8
    private var tapRateThreshold: Double = 3.0  // key presses / second
    #if DEBUG
    /// Test seam — set unconditionally on start so `_testEmit` works even when
    /// Input Monitoring permission is not granted (i.e. in CI / unit tests).
    private weak var _testBus: ReactionBus?
    #endif

    public init() {}

    // MARK: - Availability

    /// Static matcher list for keyboards. Used by both the default
    /// `isPresent` and the injectable variant.
    nonisolated public static let presenceMatchers: [HIDMatcher] = [
        HIDMatcher(usagePage: 0x01, usage: 0x06),  // GenericDesktop / Keyboard
    ]

    /// Returns true if at least one non-built-in keyboard is connected.
    /// Default uses `RealHIDDeviceMonitor`; tests inject a mock.
    nonisolated public static func isPresent(monitor: HIDDeviceMonitor = RealHIDDeviceMonitor()) -> Bool {
        let devices = monitor.queryDevices(matchers: presenceMatchers)
        let matched = devices.contains { $0.transport != "SPI" }
        if matched { log.info("isPresent: matched keyboard via HID device query") }
        return matched
    }

    /// Backwards-compatible static accessor.
    nonisolated public static var isPresent: Bool { isPresent(monitor: RealHIDDeviceMonitor()) }

    // MARK: - StimulusSource

    public func configure(tapRateThreshold: Double) {
        self.tapRateThreshold = tapRateThreshold
    }

    public func start(publishingTo bus: ReactionBus) {
        guard hidManager == nil else { return }
        #if DEBUG
        // Set the test seam unconditionally so `_testEmit` works in CI without
        // Input Monitoring permission. Real callbacks still gate on TCC below.
        self._testBus = bus
        #endif
        // Requires Input Monitoring TCC permission
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            log.warning("entity:KeyboardActivitySource wasInvalidatedBy activity:Start — Input Monitoring not granted")
            return
        }
        self.bus = bus
        startHID()
        log.info("entity:KeyboardActivitySource wasGeneratedBy activity:Start")
    }

    #if DEBUG
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        guard kind == .keyboardTyped else { return }
        await bus.publish(.keyboardTyped)
    }
    #endif

    public func stop() {
        stopHID()
        bus = nil
        keyWindow.removeAll()
        log.info("entity:KeyboardActivitySource wasInvalidatedBy activity:Stop")
    }

    // MARK: - Key press callback target

    func hidKeyPressed() {
        let now = Date()
        keyWindow.append(now)
        keyWindow.removeAll { now.timeIntervalSince($0) > 2.0 }

        let rate = Double(keyWindow.count) / 2.0
        log.debug("activity:KeyPress rate=\(String(format:"%.1f",rate))/s threshold=\(String(format:"%.1f",tapRateThreshold)) gateOpen=\(now >= typingGate)")
        guard rate >= tapRateThreshold, now >= typingGate else { return }
        typingGate = now.addingTimeInterval(typingDebounce)
        log.info("activity:Publish wasGeneratedBy entity:KeyboardActivity kind=keyboardTyped rate=\(String(format:"%.1f",rate))/s")
        if let bus { Task { await bus.publish(.keyboardTyped) } }
    }

    // MARK: - HID manager

    private func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Same matcher as `presenceMatchers` — bridging happens once via HIDMatcher.
        if let matcher = KeyboardActivitySource.presenceMatchers.first {
            IOHIDManagerSetDeviceMatching(manager, matcher.toCFDictionary())
        }
        let retained = Unmanaged.passRetained(self)
        hidRetained = retained
        IOHIDManagerRegisterInputValueCallback(manager, keyboardHIDCallback, retained.toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            hidManager = manager
        } else {
            retained.release()
            hidRetained = nil
            log.warning("entity:KeyboardActivitySource wasInvalidatedBy activity:HIDOpen result=0x\(String(result, radix:16))")
        }
    }

    private func stopHID() {
        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            hidManager = nil
        }
        hidRetained?.release()
        hidRetained = nil
    }
}

private func keyboardHIDCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    let element = IOHIDValueGetElement(value)
    // Only keyboard usage page (0x07) key press events (value > 0 = pressed)
    guard IOHIDElementGetUsagePage(element) == 0x07,
          IOHIDElementGetUsage(element) > 0,
          IOHIDValueGetIntegerValue(value) != 0 else { return }
    let source = Unmanaged<KeyboardActivitySource>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in source.hidKeyPressed() }
}
