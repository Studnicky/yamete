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

    // Injectable seams — kept uniform across all 3 activity sources so that
    // tests construct every source with the same signature shape. Keyboard
    // does not actually drive NSEvent (HID-only), so the eventMonitor is
    // retained but unused at runtime; it's there so a `MockEventMonitor`
    // parameter can be passed in matrix tests without a special case.
    private let eventMonitor: EventMonitor
    private let hidMonitor: HIDDeviceMonitor

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

    private let enableHIDDetection: Bool

    public init(eventMonitor: EventMonitor = RealEventMonitor(),
                hidMonitor: HIDDeviceMonitor = RealHIDDeviceMonitor(),
                enableHIDDetection: Bool = true) {
        self.eventMonitor = eventMonitor
        self.hidMonitor = hidMonitor
        self.enableHIDDetection = enableHIDDetection
    }

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
        // Hold the bus reference unconditionally so the `_injectKeyPress` test
        // seam can drive `handleKeyPress` through the real rate-window /
        // debounce / publish pipeline even when Input Monitoring is not
        // granted (CI). Real IOKit callbacks remain gated on TCC below.
        self.bus = bus
        // Tests pass `enableHIDDetection: false` so ambient typing on the dev
        // host doesn't bleed into matrix runs. Production stays on the TCC gate.
        guard enableHIDDetection else {
            log.debug("entity:KeyboardActivitySource startHID skipped — disabled by caller (test seam)")
            return
        }
        // Requires Input Monitoring TCC permission
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            log.warning("entity:KeyboardActivitySource wasInvalidatedBy activity:Start — Input Monitoring not granted")
            return
        }
        startHID()
        log.info("entity:KeyboardActivitySource wasGeneratedBy activity:Start")
    }

    #if DEBUG
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = _testBus else { return }
        guard kind == .keyboardTyped else { return }
        await bus.publish(.keyboardTyped)
    }

    /// Test seam — drives the same internal handler that the real
    /// `IOHIDManager` input-value callback calls. Bypasses the IOKit
    /// kernel hop but exercises the rest of the detection pipeline
    /// (rate window, debounce, threshold, bus publish). Lets tests
    /// drive the production rate-detection logic without requiring
    /// Input Monitoring permission.
    public func _injectKeyPress(at timestamp: Date = Date()) async {
        self.handleKeyPress(timestamp: timestamp)
        // Yield once so any spawned `Task { await bus.publish(...) }`
        // gets a chance to run before the caller observes the bus.
        await Task.yield()
    }
    #endif

    public func stop() {
        stopHID()
        bus = nil
        keyWindow.removeAll()
        log.info("entity:KeyboardActivitySource wasInvalidatedBy activity:Stop")
    }

    // MARK: - Key press callback target

    /// Internal handler called by both the real IOKit input-value callback
    /// (`hidKeyPressed`) and the `_injectKeyPress` test seam. Owns the
    /// rate-window, debounce gate, and bus publish.
    func handleKeyPress(timestamp now: Date) {
        keyWindow.append(now)
        keyWindow.removeAll { now.timeIntervalSince($0) > 2.0 }

        let rate = Double(keyWindow.count) / 2.0
        log.debug("activity:KeyPress rate=\(String(format:"%.1f",rate))/s threshold=\(String(format:"%.1f",tapRateThreshold)) gateOpen=\(now >= typingGate)")
        guard rate >= tapRateThreshold, now >= typingGate else { return }
        typingGate = now.addingTimeInterval(typingDebounce)
        log.info("activity:Publish wasGeneratedBy entity:KeyboardActivity kind=keyboardTyped rate=\(String(format:"%.1f",rate))/s")
        if let bus { Task { await bus.publish(.keyboardTyped) } }
    }

    /// Real IOKit input-value callback target. Forwards to the shared
    /// `handleKeyPress` so the test seam exercises the same pipeline.
    func hidKeyPressed() {
        handleKeyPress(timestamp: Date())
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
