#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

private let log = AppLog(category: "MouseActivitySource")

private let kHIDPageGenericDesktopMouse: Int = 0x01
private let kHIDUsageGDMouseUsage: Int = 0x02
private let kHIDUsageGDPointerUsage: Int = 0x01

/// Detects activity from external (non-trackpad) mice: primary button clicks
/// and sustained scroll-wheel movement. Uses NSEvent for scroll (phase == [] =
/// mouse wheel) and IOHIDManager for button clicks on non-SPI devices.
///
/// Static `isPresent` scans connected HID devices at call time; call once at
/// app startup and cache the result — the check is synchronous but fast.
@MainActor
public final class MouseActivitySource: StimulusSource {
    public let id: SensorID = .mouseActivity

    private let eventMonitor: EventMonitor
    private var scrollMonitor: EventMonitorToken?
    nonisolated(unsafe) private var clickHIDManager: IOHIDManager?
    private var clickHIDRetained: Unmanaged<MouseActivitySource>?

    private var scrollWindow: [(timestamp: Date, magnitude: Float)] = []
    private var scrollGate: Date = .distantPast
    private var clickGate: Date = .distantPast
    private weak var bus: ReactionBus?

    private var scrollThreshold: Float = 3.0
    private let scrollDebounce: TimeInterval = 1.0
    private let clickDebounce: TimeInterval = 0.5

    public convenience init() {
        self.init(eventMonitor: RealEventMonitor())
    }

    public init(eventMonitor: EventMonitor) {
        self.eventMonitor = eventMonitor
    }

    deinit { MainActor.assumeIsolated { stop() } }

    public func configure(scrollThreshold: Double) {
        self.scrollThreshold = Float(scrollThreshold)
    }

    // MARK: - Availability

    /// Static matcher list for non-trackpad pointing devices. Used by both
    /// the default `isPresent` and the injectable variant.
    nonisolated public static let presenceMatchers: [HIDMatcher] = [
        HIDMatcher(usagePage: kHIDPageGenericDesktopMouse, usage: kHIDUsageGDMouseUsage),
        HIDMatcher(usagePage: kHIDPageGenericDesktopMouse, usage: kHIDUsageGDPointerUsage),
    ]

    /// Returns true if at least one non-trackpad pointer device is connected.
    /// Excludes SPI transport (built-in trackpad) and Bluetooth devices whose
    /// product name contains "Trackpad". Default uses `RealHIDDeviceMonitor`;
    /// tests inject a mock to drive presence detection deterministically.
    nonisolated public static func isPresent(monitor: HIDDeviceMonitor = RealHIDDeviceMonitor()) -> Bool {
        let devices = monitor.queryDevices(matchers: presenceMatchers)
        let matched = devices.contains { d in
            d.transport != "SPI" && !d.product.lowercased().contains("trackpad")
        }
        if matched { log.info("isPresent: matched mouse via HID device query") }
        return matched
    }

    /// Backwards-compatible static accessor used by callers that don't
    /// need to override the device monitor.
    nonisolated public static var isPresent: Bool { isPresent(monitor: RealHIDDeviceMonitor()) }

    // MARK: - StimulusSource

    public func start(publishingTo bus: ReactionBus) {
        guard scrollMonitor == nil else { return }
        self.bus = bus

        // Scroll: mouse wheel events have phase == [] (empty) — distinct from trackpad gestures
        scrollMonitor = eventMonitor.addGlobalMonitor(matching: [.scrollWheel]) { [weak self] event in
            guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return }
            Task { @MainActor [weak self] in self?.handleMouseScroll(event, bus: bus) }
        }

        startClickHID()
        log.info("entity:MouseActivitySource wasGeneratedBy activity:Start")
    }

    #if DEBUG
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = bus else { return }
        let reaction: Reaction
        switch kind {
        case .mouseClicked:  reaction = .mouseClicked
        case .mouseScrolled: reaction = .mouseScrolled
        default:             return
        }
        await bus.publish(reaction)
    }
    #endif

    public func stop() {
        if let m = scrollMonitor { eventMonitor.removeMonitor(m) }
        scrollMonitor = nil
        stopClickHID()
        bus = nil
        scrollWindow.removeAll()
        log.info("entity:MouseActivitySource wasInvalidatedBy activity:Stop")
    }

    // MARK: - Scroll detection

    private func handleMouseScroll(_ event: NSEvent, bus: ReactionBus) {
        let mag = Float(hypot(event.scrollingDeltaX, event.scrollingDeltaY))
        guard mag > 0.5 else { return }  // filter tiny accidental movements
        let now = Date()
        scrollWindow.append((now, mag))
        log.debug("activity:MouseScroll mag=\(String(format:"%.2f",mag)) windowCount=\(scrollWindow.count)")
        scrollWindow.removeAll { now.timeIntervalSince($0.timestamp) > 2.0 }

        let rms: Float = {
            let v = scrollWindow.map { $0.magnitude * $0.magnitude }
            return sqrt(v.reduce(0, +) / Float(v.count))
        }()
        guard rms > scrollThreshold, now >= scrollGate else { return }
        scrollGate = now.addingTimeInterval(scrollDebounce)
        log.info("activity:Publish wasGeneratedBy entity:MouseActivity kind=mouseScrolled rms=\(String(format:"%.2f",rms))")
        Task { await bus.publish(.mouseScrolled) }
    }

    // MARK: - Click detection (IOHIDManager)

    func hidMouseButtonDown() {
        let now = Date()
        log.debug("activity:MouseButtonDown gateOpen=\(now >= clickGate)")
        guard now >= clickGate else { return }
        clickGate = now.addingTimeInterval(clickDebounce)
        log.info("activity:Publish wasGeneratedBy entity:MouseActivity kind=mouseClicked")
        if let bus { Task { await bus.publish(.mouseClicked) } }
    }

    private func startClickHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Same matcher list as `presenceMatchers` — convert through `HIDMatcher`
        // so the `[String: Any]` bridging happens in exactly one place.
        let cfMatchers = MouseActivitySource.presenceMatchers.map { $0.toCFDictionary() } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, cfMatchers)
        let retained = Unmanaged.passRetained(self)
        clickHIDRetained = retained
        IOHIDManagerRegisterInputValueCallback(manager, mouseClickHIDCallback, retained.toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            clickHIDManager = manager
        } else {
            retained.release()
            clickHIDRetained = nil
        }
    }

    private func stopClickHID() {
        if let manager = clickHIDManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            clickHIDManager = nil
        }
        clickHIDRetained?.release()
        clickHIDRetained = nil
    }
}

private func mouseClickHIDCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    // Only care about button-1 presses (usage page 0x09, usage 0x01)
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == 0x09,
          IOHIDElementGetUsage(element) == 0x01,
          IOHIDValueGetIntegerValue(value) != 0 else { return }
    // Check that this device is not a trackpad (exclude SPI and Trackpad names)
    let device = IOHIDElementGetDevice(element)
    let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
    let product   = IOHIDDeviceGetProperty(device, kIOHIDProductKey   as CFString) as? String ?? ""
    guard transport != "SPI", !product.lowercased().contains("trackpad") else { return }
    let source = Unmanaged<MouseActivitySource>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in source.hidMouseButtonDown() }
}
