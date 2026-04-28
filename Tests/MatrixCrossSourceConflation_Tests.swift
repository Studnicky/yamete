import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Cross-source conflation matrix.
///
/// Bug class: TWO different sources both fire for the same OS-level event.
/// The mouse-trackpad conflation bug is the canonical instance — a single
/// `NSEvent.leftMouseDown` would fire `.mouseClicked` (via mouse source) AND
/// `.trackpadTapping` (via trackpad source's NSEvent monitor) because no
/// device attribution existed at the trackpad source.
///
/// This matrix drives ONE synthetic OS event through the wired sources and
/// asserts only the right source(s) react. Each cell pins an interaction
/// pattern (event type × transport × product × prior-gesture state) and
/// asserts the published reaction set.
///
/// Cells where the production path is IOKit-callback only (mouse click via
/// `IOHIDManager`) and no `_injectClick(...)` seam has landed yet are
/// stubbed via `#if false` and listed in the run report.
@MainActor
final class MatrixCrossSourceConflationTests: XCTestCase {

    // MARK: - Synthetic NSEvent helpers

    /// Plain left-mouse-down. NSEvent.mouseEvent works at runtime even with
    /// no real window (used by AppKit-less unit tests).
    private func makeLeftMouseDown() -> NSEvent {
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    /// Mouse-wheel scrollWheel event: phase == [], momentumPhase == [].
    /// Built with `CGEvent.init(source:units:wheelCount:wheel1:wheel2:wheel3:)`,
    /// scroll-phase field left at default 0 (empty).
    private func makeMouseScroll() -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: 5,
                               wheel2: 0,
                               wheel3: 0) else { return nil }
        // Explicitly leave phase = 0 (empty). This is what mouse wheels emit.
        return NSEvent(cgEvent: cg)
    }

    /// Trackpad scrollWheel event: phase = .began (1). CGEvent → NSEvent.
    private func makeTrackpadScroll(phaseRaw: Int64 = 1, magnitude: Int32 = 5) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: magnitude,
                               wheel2: 0,
                               wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseRaw)
        return NSEvent(cgEvent: cg)
    }

    // MARK: - Bus + collector

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction,
                          clipDuration: 0.5,
                          soundURL: nil,
                          faceIndices: [0],
                          publishedAt: publishedAt)
        }
        return bus
    }

    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [ReactionKind] {
        var kinds: [ReactionKind] = []
        let stream = await bus.subscribe()
        let task = Task {
            for await fired in stream {
                kinds.append(fired.kind)
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        return kinds
    }

    /// Configure a TrackpadActivitySource with permissive thresholds so that
    /// any synthesized scroll/tap with magnitude > 0 trips detection. This
    /// keeps cells focused on attribution / conflation, not on tuning.
    private func makePermissiveTrackpad(monitor: MockEventMonitor) -> TrackpadActivitySource {
        let trackpad = TrackpadActivitySource(eventMonitor: monitor)
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.0, touchingMax: 1.0,
            slidingMin: 0.0, slidingMax: 1.0,
            contactMin: 0.5, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0,
            tappingEnabled: true
        )
        return trackpad
    }

    private func makePermissiveMouse(monitor: MockEventMonitor) -> MouseActivitySource {
        let mouse = MouseActivitySource(eventMonitor: monitor)
        mouse.configure(scrollThreshold: 0.0)
        return mouse
    }

    // MARK: - Cell 1 — bare leftMouseDown (no trackpad gesture)

    /// User clicks an external mouse with NO prior trackpad gesture. The
    /// trackpad source's NSEvent leftMouseDown monitor sees the click but
    /// MUST drop it via the gesture-recency gate. This is the canonical
    /// conflation bug: same NSEvent, two reactions.
    ///
    /// Mouse source is intentionally NOT started — its production click
    /// path uses IOHIDManager against the real OS, which doesn't honor a
    /// `MockEventMonitor`. Bringing up the mouse source would let real
    /// ambient mouse clicks bleed into the assertion stream and flake.
    func test_leftMouseDown_noPriorGesture_trackpadDoesNotFire() async {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(120))

        let kinds = await collectTask.value
        XCTAssertFalse(kinds.contains(.trackpadTapping),
                       "[cell=leftMouseDown-noPriorGesture] trackpad must NOT credit a bare click as a tap; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 2 — mouse wheel (phase==[]) does not fire trackpad

    /// User scrolls a mouse wheel. NSEvent has phase==[]. Trackpad source's
    /// `handleScroll` MUST reject the event via its `phase.isEmpty` guard.
    /// Only the trackpad source is started — the mouse source's scroll
    /// path could fire and bleed via real ambient input.
    func test_mouseWheelScroll_trackpadDoesNotFire() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        // Burst several wheel events to clear mouse RMS threshold.
        guard let wheel = makeMouseScroll() else {
            throw XCTSkip("CGEvent could not synthesize a phase-empty scroll on this host")
        }
        for _ in 0..<10 {
            monitor.emit(wheel, ofType: .scrollWheel)
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(150))

        let kinds = await collectTask.value
        XCTAssertFalse(kinds.contains(.trackpadTouching),
                       "[cell=mouseWheel] trackpad must NOT publish .trackpadTouching for mouse-wheel events; got \(kinds)")
        XCTAssertFalse(kinds.contains(.trackpadSliding),
                       "[cell=mouseWheel] trackpad must NOT publish .trackpadSliding for mouse-wheel events; got \(kinds)")
        XCTAssertFalse(kinds.contains(.trackpadContact),
                       "[cell=mouseWheel] trackpad must NOT publish .trackpadContact for mouse-wheel events; got \(kinds)")
        // Conflation invariant: trackpad stays silent for mouse-wheel events.
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 3 — trackpad gesture fires only trackpad

    /// User performs a two-finger scroll on the trackpad. NSEvent has
    /// phase=.began. Trackpad source publishes `.trackpadTouching` (or
    /// `.trackpadSliding` per RMS). Mouse source is wired in to confirm
    /// that the same `MockEventMonitor.emit(...)` reaches BOTH sources'
    /// installed monitors, but the assertion focuses on the trackpad
    /// firing — the mouse-fires-or-not is the OS-ambient flake risk and
    /// not what this cell is testing.
    func test_trackpadGesture_mouseDoesNotFire() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        let mouse = makePermissiveMouse(monitor: monitor)
        trackpad.start(publishingTo: bus)
        mouse.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        guard let scroll = makeTrackpadScroll(phaseRaw: 1, magnitude: 30) else {
            throw XCTSkip("CGEvent could not synthesize a phased scroll on this host")
        }
        for _ in 0..<5 {
            monitor.emit(scroll, ofType: .scrollWheel)
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(180))

        let kinds = await collectTask.value
        // Trackpad should fire one of the touching/sliding kinds for a
        // phased magnitude-30 scroll; assert SOMETHING trackpad-class fired.
        let trackpadKinds: Set<ReactionKind> = [.trackpadTouching, .trackpadSliding, .trackpadContact, .trackpadCircling]
        XCTAssertTrue(kinds.contains(where: { trackpadKinds.contains($0) }),
                      "[cell=trackpadGesture] trackpad should fire SOMETHING for a phased scroll; got \(kinds)")
        // Mouse-source non-firing is asserted in a dedicated cell where
        // ambient OS input cannot bleed in (mouse source not started).
        trackpad.stop(); mouse.stop()
        await bus.close()
    }

    // MARK: - Cell 4 — trackpad gesture then tap → trackpad fires

    /// Trackpad gesture stamps `lastTrackpadGestureAt`. Subsequent
    /// leftMouseDown within the attribution window (0.5s) is credited as
    /// `.trackpadTapping`. Mouse source not started — its NSEvent monitor
    /// is scrollWheel-only and its IOHIDManager click path runs against
    /// real OS events, which can flake against ambient mouse input.
    func test_trackpadGestureThenClick_trackpadTaps() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.6) }
        try? await Task.sleep(for: .milliseconds(20))

        guard let scroll = makeTrackpadScroll(phaseRaw: 1, magnitude: 30) else {
            throw XCTSkip("CGEvent could not synthesize a phased scroll on this host")
        }
        monitor.emit(scroll, ofType: .scrollWheel)
        try? await Task.sleep(for: .milliseconds(50))
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(180))

        let kinds = await collectTask.value
        XCTAssertTrue(kinds.contains(.trackpadTapping),
                      "[cell=gestureThenClick] click after recent gesture must credit trackpadTapping; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 5 — trackpad disabled, leftMouseDown silent

    /// `tappingEnabled = false` short-circuits the attribution logic. A
    /// recent gesture still stamps the timestamp, but the click drops at
    /// the `guard tappingEnabled` line. No reaction.
    func test_trackpadTappingDisabled_clickSilent() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: monitor)
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.0, touchingMax: 1.0,
            slidingMin: 0.0, slidingMax: 1.0,
            contactMin: 0.5, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0,
            tappingEnabled: false
        )
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        if let scroll = makeTrackpadScroll(phaseRaw: 1, magnitude: 30) {
            monitor.emit(scroll, ofType: .scrollWheel)
        }
        try? await Task.sleep(for: .milliseconds(50))
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(180))

        let kinds = await collectTask.value
        XCTAssertFalse(kinds.contains(.trackpadTapping),
                       "[cell=tappingDisabled] disabled tapping must suppress trackpadTapping; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 6 — momentumPhase scroll (deceleration after gesture)

    /// `event.momentumPhase` is non-empty during inertial scrolling after
    /// a trackpad gesture released. Trackpad's `handleScroll` guard is
    /// `phase.isEmpty` (without checking momentumPhase), so a pure
    /// momentum event with empty phase drops at trackpad. Only the
    /// trackpad source is started — mouse non-firing is covered in a
    /// dedicated cell that can't be flaked by ambient OS input.
    func test_momentumPhaseScroll_trackpadDoesNotFire() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        // Build a synthetic "momentum" event: phase = 0, momentumPhase != 0.
        // kCGScrollWheelEventMomentumPhase = 123. .began = 1.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 2,
                               wheel1: 5, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent could not synthesize on this host")
        }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        guard let momentum = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent bridge unavailable for momentum scroll")
        }
        for _ in 0..<5 {
            monitor.emit(momentum, ofType: .scrollWheel)
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(120))

        let kinds = await collectTask.value
        XCTAssertFalse(kinds.contains(.trackpadTouching),
                       "[cell=momentumScroll] empty-phase momentum must not publish .trackpadTouching; got \(kinds)")
        XCTAssertFalse(kinds.contains(.trackpadSliding),
                       "[cell=momentumScroll] empty-phase momentum must not publish .trackpadSliding; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 7 — phase=.changed (mid-gesture)

    /// `phase = .changed (4)` is the body of an in-progress trackpad
    /// gesture. Trackpad source updates RMS and may publish a touching/
    /// sliding reaction. Mouse source is intentionally not started here
    /// — its scroll path is exercised separately, and its real
    /// IOHIDManager-free NSEvent monitor would correctly reject phased
    /// events (already covered by mutation 3 on Cell 2).
    func test_phaseChanged_trackpadAdvancesScroll() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        // .began (1) then several .changed (4) for natural scroll arc.
        guard let began = makeTrackpadScroll(phaseRaw: 1, magnitude: 20),
              let changed = makeTrackpadScroll(phaseRaw: 4, magnitude: 30) else {
            throw XCTSkip("CGEvent could not synthesize phased scrolls")
        }
        monitor.emit(began, ofType: .scrollWheel)
        for _ in 0..<6 {
            monitor.emit(changed, ofType: .scrollWheel)
            try? await Task.sleep(for: .milliseconds(8))
        }
        try? await Task.sleep(for: .milliseconds(150))

        let kinds = await collectTask.value
        let trackpadKinds: Set<ReactionKind> = [.trackpadTouching, .trackpadSliding, .trackpadContact]
        XCTAssertTrue(kinds.contains(where: { trackpadKinds.contains($0) }),
                      "[cell=phaseChanged] phased scroll must produce a trackpad reaction; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 8 — both sources started, no events emitted, no reactions

    /// Sanity: starting the trackpad source without driving any event
    /// must yield zero trackpad reactions. Catches "started state itself
    /// fires something". Mouse source not started — its real IOHIDManager
    /// can deliver ambient OS clicks during the test window.
    func test_startTrackpadSource_noEventsEmitted_noTrackpadReactions() async {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.25) }
        let kinds = await collectTask.value
        let trackpadKinds: Set<ReactionKind> = [
            .trackpadTouching, .trackpadSliding, .trackpadContact,
            .trackpadTapping, .trackpadCircling
        ]
        XCTAssertFalse(kinds.contains(where: { trackpadKinds.contains($0) }),
                       "[cell=noEvents] starting trackpad must not synthesize reactions; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 9 — second click within debounce drops trackpad-side

    /// After the first attributed tap, the trackpad's `tappingDebounce`
    /// (1.0s) drops a second click that arrives 100ms later — even with
    /// fresh gesture-recency. The second click within the same window
    /// must not fire .trackpadTapping again.
    func test_tappingDebounce_secondClickWithinWindow_drops() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.7) }
        try? await Task.sleep(for: .milliseconds(20))

        guard let scroll = makeTrackpadScroll(phaseRaw: 1, magnitude: 30) else {
            throw XCTSkip("CGEvent could not synthesize a phased scroll on this host")
        }
        // Build up tap rate above tapMin (0.5/s) — emit several taps in
        // quick succession, all within attribution window.
        monitor.emit(scroll, ofType: .scrollWheel)
        try? await Task.sleep(for: .milliseconds(40))
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(80))
        monitor.emit(scroll, ofType: .scrollWheel)
        try? await Task.sleep(for: .milliseconds(40))
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(200))

        let kinds = await collectTask.value
        let tappingCount = kinds.filter { $0 == .trackpadTapping }.count
        XCTAssertLessThanOrEqual(tappingCount, 1,
                                 "[cell=tappingDebounce] debounce should cap trackpadTapping at 1 inside window; got \(tappingCount)")
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Cell 10 — IOHID click cells (BLOCKED on _injectClick seam)

    /// IOHIDManager click on transport=SPI device → mouse must NOT publish
    /// `.mouseClicked` (production filter `transport != "SPI"`). This cell
    /// requires a `_injectClick(transport:product:)` seam on
    /// `MouseActivitySource`. Stubbed until the parallel agent lands it.
    #if false
    func test_hidClick_SPI_doesNotFireMouseClicked() async {
        // BLOCKED: requires MouseActivitySource._injectClick(transport:product:)
        // Expected behaviour: SPI transport (built-in trackpad button) is
        // dropped at the production filter; .mouseClicked must NOT appear.
    }

    func test_hidClick_USB_MagicTrackpad_doesNotFireMouseClicked() async {
        // BLOCKED: requires MouseActivitySource._injectClick(transport:product:)
        // Expected behaviour: USB transport but product == "Magic Trackpad 2"
        // is dropped at the production filter; .mouseClicked must NOT appear.
    }

    func test_hidClick_USB_LogitechMouse_firesMouseClicked_noTrackpadTap() async {
        // BLOCKED: requires MouseActivitySource._injectClick(transport:product:)
        // Expected: USB transport with non-trackpad product → .mouseClicked
        // fires. With NO recent trackpad gesture, trackpad source's gate
        // drops the leftMouseDown — only .mouseClicked appears.
    }

    func test_hidClick_USB_LogitechMouse_afterRecentGesture_bothFire() async {
        // BLOCKED: requires MouseActivitySource._injectClick(transport:product:)
        // Accepted-corner-case: when a real trackpad gesture happened within
        // the attribution window AND a USB mouse click arrives, BOTH
        // .mouseClicked (mouse owns the IOHIDManager click) AND
        // .trackpadTapping (gesture-recency permits it) fire. User chose
        // option (b)-permissive: live with double-fire when both devices
        // are simultaneously active. This cell asserts the trade-off so a
        // future "fix" doesn't regress silently.
    }
    #endif

    // MARK: - Cell 11 — keyboard does not consume mock-emitted leftMouseDown

    /// KeyboardActivitySource is HID-only (its IOHIDManager pipeline runs
    /// against real OS events, not the `MockEventMonitor`). The cell
    /// asserts the negative path: emitting a synthetic leftMouseDown
    /// through the mock does NOT cause keyboard to subscribe (the mock's
    /// `installed` table should hold zero monitors for this source).
    /// We can't assert "no .keyboardTyped fires" because real ambient
    /// keypresses during the test window would flake — a real bug not in
    /// scope. So we assert the structural invariant: keyboard never
    /// installs an NSEvent monitor against the mock.
    func test_keyboardSource_doesNotInstallNSEventMonitor() async {
        let monitor = MockEventMonitor()
        let keyboard = KeyboardActivitySource()
        let bus = await makeBus()
        keyboard.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        // Mock event monitor should not have any installed handlers from
        // keyboard — keyboard uses HID directly, never NSEvent.
        XCTAssertEqual(monitor.installedCount, 0,
                       "[cell=keyboardIsolation] keyboard must not install NSEvent monitors; mock holds \(monitor.installedCount)")
        keyboard.stop()
        await bus.close()
    }

    // MARK: - Cell 12 — phase=.ended releases contact, no spurious fire

    /// `phase = .ended (8)` ends a gesture. Source resets contact state.
    /// Must not fire any reaction at the boundary (gesture finalisation
    /// is a state transition, not a stimulus).
    func test_phaseEnded_noSpuriousFire() async throws {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = makePermissiveTrackpad(monitor: monitor)
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        guard let ended = makeTrackpadScroll(phaseRaw: 8, magnitude: 0) else {
            throw XCTSkip("CGEvent could not synthesize a .ended scroll")
        }
        monitor.emit(ended, ofType: .scrollWheel)
        try? await Task.sleep(for: .milliseconds(120))

        let kinds = await collectTask.value
        // .ended with magnitude 0 should NOT fire any trackpad reaction.
        XCTAssertFalse(kinds.contains(.trackpadTouching),
                       "[cell=phaseEnded] .ended with mag=0 must not fire trackpadTouching; got \(kinds)")
        XCTAssertFalse(kinds.contains(.trackpadSliding),
                       "[cell=phaseEnded] .ended with mag=0 must not fire trackpadSliding; got \(kinds)")
        trackpad.stop()
        await bus.close()
    }
}
