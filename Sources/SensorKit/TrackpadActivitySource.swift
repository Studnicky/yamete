#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

private let log = AppLog(category: "TrackpadActivitySource")

/// Monitors five categories of trackpad activity and publishes the appropriate
/// Reaction to the bus, independent of impact fusion.
///
/// Detection modes:
///   - **Scroll/swipe** (`.trackpadTouching`, `.trackpadSliding`): two-finger scroll
///     velocity via `NSEvent.scrollWheel` delta accumulation.
///   - **Finger contact** (`.trackpadContact`): finger rests on pad for ≥ `contactMin`
///     seconds while still held — fires via a timer after the threshold elapses.
///   - **Tapping** (`.trackpadTapping`): rapid primary-button click rate via NSEvent
///     global monitor for `.leftMouseDown`. Force Touch trackpads do not expose button
///     HID elements via IOHIDManager (clicks are haptic simulation, not a real switch),
///     so NSEvent is the only reliable public tap-detection surface.
///   - **Circling** (`.trackpadCircling`): finger traces ≥1 full revolution (2π rad)
///     as detected by accumulating signed angle deltas across scroll events.
///
/// Conforms to StimulusSource — publishes directly to the bus, independent of impact fusion.
@MainActor
public final class TrackpadActivitySource: StimulusSource {
    public let id: SensorID = .trackpadActivity

    // MARK: - NSEvent monitor injection
    private let eventMonitor: EventMonitor

    // MARK: - Scroll monitor (NSEvent)
    private var monitor: EventMonitorToken?

    // MARK: - Tap monitor (NSEvent leftMouseDown — works for Force Touch)
    private var tapMonitor: EventMonitorToken?
    // Bus reference for tap callbacks (weak to avoid retain cycle)
    private weak var bus: ReactionBus?

    // MARK: - Tuning parameters

    private var windowDuration: Double = 1.5
    private var scrollMin: Double = 0.1
    private var scrollMax: Double = 0.8
    private var touchingMin: Double = 0.1
    private var touchingMax: Double = 0.5
    private var slidingMin: Double = 0.5
    private var slidingMax: Double = 0.9
    private var contactMin: Double = 0.5
    private var contactMax: Double = 2.5
    private var tapMin: Double = 2.0
    private var tapMax: Double = 6.0

    // MARK: - Per-mode enable flags

    private var touchingEnabled: Bool = true
    private var slidingEnabled: Bool = true
    /// Most recent trackpad gesture timestamp (scroll/swipe with non-empty
    /// phase, or magnify/rotate). NSEvent's `.leftMouseDown` global monitor
    /// fires for ANY mouse click — built-in trackpad, Magic Trackpad, OR an
    /// external USB mouse. There's no public API to attribute a click to a
    /// specific input device. We use gesture recency as a proxy: a tap is
    /// only credited to the trackpad if a confirmed trackpad gesture
    /// happened within `tapAttributionWindow` seconds before it. Otherwise
    /// the click came from somewhere else (mouse, virtual click) and we
    /// drop it. This stops external-mouse clicks from being double-counted
    /// as trackpad taps. The trade-off: pure tap-only-no-scroll users get
    /// no taps registered until they touch the trackpad surface — a known
    /// false negative we accept to eliminate the false positive.
    private var lastTrackpadGestureAt: Date = .distantPast
    /// Click → trackpad attribution window. A leftMouseDown within this
    /// many seconds after a confirmed trackpad gesture is credited to the
    /// trackpad; outside it, dropped (the click came from elsewhere).
    private let tapAttributionWindow: TimeInterval = 0.5
    private var contactEnabled: Bool = true
    private var tappingEnabled: Bool = true
    private var circlingEnabled: Bool = true

    // MARK: - Scroll / swipe state

    private var scrollWindow: [(timestamp: Date, magnitude: Float)] = []

    // MARK: - Contact state

    private var contactStart: Date?
    private var contactTimer: Task<Void, Never>?

    // MARK: - Tap state

    private var tapWindow: [Date] = []

    // MARK: - Circle detection state

    private var circleLastAngle: Double?
    private var circleAngleAccum: Double = 0
    private var circleEventCount: Int = 0
    private var circlingGate: Date = .distantPast
    private let circlingDebounce: TimeInterval = 2.5

    // MARK: - Per-kind debounce gates

    private var touchingGate: Date = .distantPast
    private var slidingGate:  Date = .distantPast
    private var contactGate:  Date = .distantPast
    private var tappingGate:  Date = .distantPast

    private let touchingDebounce: TimeInterval = 1.5
    private let slidingDebounce:  TimeInterval = 0.8
    private let contactDebounce:  TimeInterval = 2.0
    private let tappingDebounce:  TimeInterval = 1.0

    public convenience init() {
        self.init(eventMonitor: RealEventMonitor())
    }

    public init(eventMonitor: EventMonitor) {
        self.eventMonitor = eventMonitor
    }

    deinit { MainActor.assumeIsolated { stop() } }

    /// Static matcher list for trackpad detection. Used by both the
    /// default `isPresent` and the injectable variant. SPI = built-in
    /// MacBook trackpad; usage page 0x000D / usage 0x0005 = HID
    /// digitizer touch pad; Bluetooth Magic Trackpads matched by product.
    nonisolated public static let presenceMatchers: [HIDMatcher] = [
        HIDMatcher(transport: "SPI"),
        HIDMatcher(usagePage: 0x000D, usage: 0x0005),
        HIDMatcher(transport: "Bluetooth", product: "Magic Trackpad"),
        HIDMatcher(transport: "Bluetooth", product: "Apple Magic Trackpad"),
        HIDMatcher(transport: "Bluetooth", product: "Apple Magic Trackpad 2"),
    ]

    /// Returns true if a built-in (SPI) or external Magic Trackpad is connected.
    /// Default uses `RealHIDDeviceMonitor`; tests inject a mock to drive
    /// presence detection deterministically.
    nonisolated public static func isPresent(monitor: HIDDeviceMonitor = RealHIDDeviceMonitor()) -> Bool {
        if !monitor.queryDevices(matchers: presenceMatchers).isEmpty {
            log.info("isPresent: matched trackpad via HID device query")
            return true
        }
        // Final fallback: any built-in display means a MacBook/MacBook Pro/Air.
        if monitor.hasBuiltInDisplay() {
            log.info("isPresent: matched trackpad via built-in display fallback")
            return true
        }
        return false
    }

    /// Backwards-compatible static accessor used by callers that don't
    /// need to override the device monitor.
    nonisolated public static var isPresent: Bool { isPresent(monitor: RealHIDDeviceMonitor()) }

    // MARK: - StimulusSource

    public func configure(windowDuration: Double,
                           scrollMin: Double, scrollMax: Double,
                           touchingMin: Double, touchingMax: Double,
                           slidingMin: Double, slidingMax: Double,
                           contactMin: Double, contactMax: Double,
                           tapMin: Double, tapMax: Double,
                           touchingEnabled: Bool = true,
                           slidingEnabled: Bool = true,
                           contactEnabled: Bool = true,
                           tappingEnabled: Bool = true,
                           circlingEnabled: Bool = true) {
        self.windowDuration = windowDuration
        self.scrollMin = scrollMin
        self.scrollMax = scrollMax
        self.touchingMin = touchingMin
        self.touchingMax = touchingMax
        self.slidingMin = slidingMin
        self.slidingMax = slidingMax
        self.contactMin = contactMin
        self.contactMax = contactMax
        self.tapMin = tapMin
        self.tapMax = tapMax
        self.touchingEnabled = touchingEnabled
        self.slidingEnabled = slidingEnabled
        self.contactEnabled = contactEnabled
        self.tappingEnabled = tappingEnabled
        self.circlingEnabled = circlingEnabled
    }

    public func start(publishingTo bus: ReactionBus) {
        guard monitor == nil else { return }
        self.bus = bus

        // Scroll / gesture monitor (NSEvent global) — non-empty phase = trackpad gesture.
        // The handler closure runs synchronously when the event arrives. We capture
        // `Date()` here (event-arrival time) and pass it forward, instead of letting
        // `handleScrollEvent` compute its own `Date()` after the @MainActor hop —
        // under heavy MainActor load the hop can lag enough to defeat
        // `lastTrackpadGestureAt`'s recency check, conflating mouse-clicks as
        // trackpad-taps. Capture-at-arrival makes the gate's timing faithful.
        monitor = eventMonitor.addGlobalMonitor(
            matching: [.scrollWheel, .gesture, .magnify, .rotate]
        ) { [weak self] event in
            let stampedAt = Date()
            Task { @MainActor [weak self] in
                self?.handleScrollEvent(event, bus: bus, at: stampedAt)
            }
        }

        // Tap monitor: NSEvent leftMouseDown. Force Touch trackpads don't expose button
        // HID elements via IOHIDManager (click is haptic simulation), so NSEvent is required.
        // Same arrival-time capture pattern as the scroll monitor.
        tapMonitor = eventMonitor.addGlobalMonitor(matching: [.leftMouseDown]) { [weak self] _ in
            let stampedAt = Date()
            Task { @MainActor [weak self] in self?.handleTapDown(at: stampedAt) }
        }

        log.info("entity:TrackpadActivitySource wasGeneratedBy activity:Start")
    }

    #if DEBUG
    /// Test seam — publishes the given trackpad reaction kind directly to the
    /// bus this source was started with. Returns immediately if the source
    /// has not been started or if `kind` is not a trackpad reaction.
    public func _testEmit(_ kind: ReactionKind) async {
        guard let bus = bus else { return }
        let reaction: Reaction
        switch kind {
        case .trackpadTouching: reaction = .trackpadTouching
        case .trackpadSliding:  reaction = .trackpadSliding
        case .trackpadContact:  reaction = .trackpadContact
        case .trackpadTapping:  reaction = .trackpadTapping
        case .trackpadCircling: reaction = .trackpadCircling
        default:                return
        }
        await bus.publish(reaction)
    }
    #endif

    public func stop() {
        if let m = monitor { eventMonitor.removeMonitor(m) }
        monitor = nil
        if let m = tapMonitor { eventMonitor.removeMonitor(m) }
        tapMonitor = nil
        bus = nil
        contactTimer?.cancel()
        contactTimer = nil
        scrollWindow.removeAll()
        contactStart = nil
        tapWindow.removeAll()
        circleLastAngle = nil
        circleAngleAccum = 0
        circleEventCount = 0
        log.info("entity:TrackpadActivitySource wasInvalidatedBy activity:Stop")
    }

    // MARK: - Tap detection (NSEvent)

    private func handleTapDown(at now: Date = Date()) {
        guard tappingEnabled else { return }
        // DEVICE ATTRIBUTION: NSEvent's global .leftMouseDown monitor catches
        // every left-click, including from external USB mice. Without this
        // gate, a mouse click would fire trackpadTapping AND mouseClicked.
        // Only count clicks as trackpad taps if a confirmed trackpad gesture
        // happened recently — proxy for "the user's hand is on the trackpad."
        let sinceGesture = now.timeIntervalSince(lastTrackpadGestureAt)
        guard sinceGesture <= tapAttributionWindow else {
            log.debug("activity:TrackpadTapDown dropped — \(String(format:"%.2f",sinceGesture))s since last trackpad gesture > \(tapAttributionWindow)s window; click attributed to other device")
            return
        }
        tapWindow.append(now)
        tapWindow.removeAll { now.timeIntervalSince($0) > 2.0 }
        let rate = Double(tapWindow.count) / 2.0
        log.debug("activity:TrackpadTapDown rate=\(String(format:"%.1f",rate))/s tapMin=\(String(format:"%.1f",tapMin)) gateOpen=\(now >= tappingGate)")
        guard rate >= tapMin, now >= tappingGate else { return }
        tappingGate = now.addingTimeInterval(tappingDebounce)
        log.info("activity:Publish wasGeneratedBy entity:TrackpadActivity kind=trackpadTapping rate=\(String(format:"%.1f",rate))/s")
        if let bus { Task { await bus.publish(.trackpadTapping) } }
    }

    // MARK: - Scroll / swipe (NSEvent)

    private func handleScrollEvent(_ event: NSEvent, bus: ReactionBus, at now: Date = Date()) {
        switch event.type {
        case .scrollWheel:
            // Only stamp the gesture timestamp when phase is non-empty (i.e.
            // a confirmed trackpad gesture, not a mouse wheel — which has
            // empty phase). Mouse-wheel scroll must NOT register the user's
            // hand as being on the trackpad.
            if !event.phase.isEmpty { lastTrackpadGestureAt = now }
            handleScroll(event, bus: bus, now: now)
        case .magnify:
            // Magnify and rotate are trackpad-only gestures (or Magic Mouse;
            // Magic Mouse counts as a trackpad-class touch surface for
            // attribution purposes — it's the same pattern of finger-on-glass).
            lastTrackpadGestureAt = now
            let mag = Float(abs(event.magnification)) * 10
            appendScroll(mag, now: now)
            evaluateScroll(bus: bus, now: now)
        case .rotate:
            lastTrackpadGestureAt = now
            let mag = Float(abs(event.rotation)) / 10
            appendScroll(mag, now: now)
            evaluateScroll(bus: bus, now: now)
        default:
            break
        }
    }

    private func handleScroll(_ event: NSEvent, bus: ReactionBus, now: Date) {
        let phase = event.phase
        // Traditional mouse scroll wheels produce scrollWheel events with an
        // empty phase ([]). Trackpad and Magic Mouse gestures always carry a
        // non-empty phase (.began, .changed, .ended, etc.). Gate here so mouse
        // wheels don't accumulate RMS or trigger contact detection.
        guard !phase.isEmpty else { return }

        log.debug("activity:TrackpadPhase raw=\(phase.rawValue) contactActive=\(contactStart != nil)")

        if phase.contains(.mayBegin) || phase.contains(.began) {
            if contactStart == nil {
                contactStart = now
                log.debug("activity:TrackpadContactStart phase=\(phase.rawValue)")
                // Start a timer — fire contact after contactMin seconds while still held
                let minDur = contactMin
                contactTimer?.cancel()
                contactTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(minDur))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        self?.attemptFireContact(at: Date())
                    }
                }
            }
        } else if phase.contains(.ended) || phase.contains(.cancelled) {
            contactTimer?.cancel()
            contactTimer = nil
            contactStart = nil
            // Reset circle accumulation when gesture ends
            circleLastAngle = nil
            circleAngleAccum = 0
            circleEventCount = 0
        }

        let mag = Float(hypot(event.scrollingDeltaX, event.scrollingDeltaY))
        guard mag > 0.01 else { return }
        appendScroll(mag, now: now)
        evaluateScroll(bus: bus, now: now)
        evaluateCircle(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY), bus: bus, now: now)
    }

    private func appendScroll(_ magnitude: Float, now: Date) {
        scrollWindow.append((now, magnitude))
        scrollWindow.removeAll { now.timeIntervalSince($0.timestamp) > windowDuration * 2.0 }
    }

    private func evaluateScroll(bus: ReactionBus, now: Date) {
        let touchThreshold = Float(touchingMin * 10.0)
        let slideThreshold = Float(slidingMax * 26.0)

        let touchWin = scrollWindow.filter { now.timeIntervalSince($0.timestamp) <= windowDuration }
        let touchRMS = rms(touchWin.map { $0.magnitude })

        let slideWin = scrollWindow.filter { now.timeIntervalSince($0.timestamp) <= windowDuration * 0.267 }
        let slideRMS = rms(slideWin.map { $0.magnitude })

        log.debug("activity:TrackpadScrollRMS touch=\(String(format:"%.2f",touchRMS)) slide=\(String(format:"%.2f",slideRMS)) threshold=\(String(format:"%.2f",touchThreshold))")
        if slideRMS > slideThreshold, now >= slidingGate {
            guard slidingEnabled else { return }
            slidingGate = now.addingTimeInterval(slidingDebounce)
            log.info("activity:Publish wasGeneratedBy entity:TrackpadActivity kind=trackpadSliding rms=\(String(format:"%.2f",slideRMS))")
            Task { await bus.publish(.trackpadSliding) }
        }

        if touchRMS > touchThreshold, now >= touchingGate {
            guard touchingEnabled else { return }
            touchingGate = now.addingTimeInterval(touchingDebounce)
            log.info("activity:Publish wasGeneratedBy entity:TrackpadActivity kind=trackpadTouching rms=\(String(format:"%.2f",touchRMS))")
            Task { await bus.publish(.trackpadTouching) }
        }
    }

    // MARK: - Circle detection

    private func evaluateCircle(dx: Float, dy: Float, bus: ReactionBus, now: Date) {
        let mag = hypotf(dx, dy)
        guard mag > 2.0 else { return }  // ignore tiny movements

        let angle = Double(atan2f(dy, dx))
        if let last = circleLastAngle {
            var delta = angle - last
            // Normalize delta to [-π, π] to handle wrap-around
            if delta > .pi  { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            circleAngleAccum += delta
            circleEventCount += 1
        }
        circleLastAngle = angle

        // Require: at least 2π accumulated rotation AND minimum event count for smooth motion
        guard abs(circleAngleAccum) > 2 * .pi, circleEventCount >= 15 else { return }
        guard circlingEnabled, now >= circlingGate else {
            // Reset if gate is closed but we detected a circle (avoid stale accumulation)
            if abs(circleAngleAccum) > 3 * .pi { circleAngleAccum = 0; circleLastAngle = nil; circleEventCount = 0 }
            return
        }
        circlingGate = now.addingTimeInterval(circlingDebounce)
        circleAngleAccum = 0
        circleLastAngle = nil
        circleEventCount = 0
        log.info("activity:Publish wasGeneratedBy entity:TrackpadActivity kind=trackpadCircling")
        Task { await bus.publish(.trackpadCircling) }
    }

    // MARK: - Helpers

    /// Body of the contactTimer's MainActor block, extracted so tests
    /// can drive it with a synthesized `now` (skipping the real wallclock
    /// wait) and assert the `dur <= contactMax` gate.
    fileprivate func attemptFireContact(at now: Date) {
        guard self.contactStart != nil else { return }
        guard let bus = self.bus, self.contactEnabled else { return }
        let dur = now.timeIntervalSince(self.contactStart ?? now)
        guard dur <= contactMax else { return }
        self.log_contactFired(dur: dur)
        log.info("activity:Publish wasGeneratedBy entity:TrackpadActivity kind=trackpadContact dur=\(String(format:"%.2f",dur))s")
        Task { await bus.publish(.trackpadContact) }
    }

    #if DEBUG
    /// Test seam — drives `attemptFireContact` with a synthesized `now`
    /// so cells can assert the `dur <= contactMax` gate without waiting
    /// real time. `contactStart` must already be set (drive a `.began`
    /// scroll first).
    public func _testTriggerContactFire(at now: Date) {
        attemptFireContact(at: now)
    }

    /// Test seam — drives `evaluateCircle` directly so cells can assert
    /// the magnitude floor (`mag > 2.0`), the rotation+event-count gate
    /// (`abs(circleAngleAccum) > 2π && circleEventCount >= 15`), and
    /// the circling enable + debounce gate.
    public func _injectCircleSample(dx: Float, dy: Float) {
        guard let bus = self.bus else { return }
        evaluateCircle(dx: dx, dy: dy, bus: bus, now: Date())
    }
    #endif

    private func log_contactFired(dur: Double) {
        log.debug("activity:TrackpadContact duration=\(String(format:"%.2f",dur))s")
    }

    private func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.map { $0 * $0 }.reduce(0, +) / Float(values.count))
    }
}
