import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Device-attribution matrix.
///
/// Bug class: at the OS event-routing layer, `NSEvent.addGlobalMonitor` for
/// `.leftMouseDown` fires for ANY left-mouse-down — built-in trackpad,
/// Magic Trackpad, OR an external USB mouse. There is no public API that
/// attributes a click to a specific input device. Without explicit gating,
/// `TrackpadActivitySource`'s tap monitor counts external-mouse clicks as
/// trackpad taps, and so a single mouse click fires BOTH `.mouseClicked`
/// (from `MouseActivitySource`'s IOHIDManager-filtered click handler) AND
/// `.trackpadTapping` (from the trackpad's NSEvent monitor). The user
/// experiences "one click → two reactions" / mouse-only behavior triggers
/// trackpad reactions.
///
/// Production fix: `TrackpadActivitySource` requires a recent confirmed
/// trackpad GESTURE (scroll with non-empty phase, magnify, rotate) before
/// it credits a `.leftMouseDown` as a trackpad tap. Outside the
/// `tapAttributionWindow` (0.5s), clicks are attributed to "some other
/// device" and dropped at the trackpad source. The mouse source's
/// IOHIDManager click pipeline still fires for those clicks, so mouse
/// clicks correctly reach `.mouseClicked` only.
///
/// This matrix simulates the OS-event-routing surface using
/// `MockEventMonitor.emit(_:ofType:)` and asserts the right kinds reach
/// the bus for each interaction pattern.
@MainActor
final class MatrixDeviceAttributionTests: XCTestCase {

    // MARK: - Synthetic NSEvent helpers

    /// Synthesize a left-mouse-down NSEvent for emission through the mock.
    /// `NSEvent.mouseEvent(with:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:)`
    /// works at runtime even when no real window exists.
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

    /// Synthesize a trackpad scroll-wheel NSEvent. `phase != []` is the
    /// signal that this came from a touch surface (trackpad / Magic Mouse).
    /// AppKit's public NSEvent API does not let you set `phase` directly;
    /// CGEvent does. Build via CGEvent → NSEvent bridge.
    private func makeTrackpadScroll() -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: 5,
                               wheel2: 0,
                               wheel3: 0) else { return nil }
        // kCGScrollWheelEventScrollPhase = 99. .began == 1.
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        return NSEvent(cgEvent: cg)
    }

    // MARK: - Cell helpers

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

    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [FiredReaction] {
        var collected: [FiredReaction] = []
        let stream = await bus.subscribe()
        let deadline = Date().addingTimeInterval(seconds)
        let task = Task {
            for await fired in stream {
                collected.append(fired)
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        // Drain a tick after cancel so the last yield lands.
        try? await Task.sleep(for: .milliseconds(20))
        _ = deadline
        return collected
    }

    // MARK: - Scenario 1: standalone external-mouse click

    /// User has an external mouse only (no recent trackpad activity). They
    /// click. The TRACKPAD source must NOT see this as a tap. Mouse source
    /// owns mouse clicks via its IOHIDManager pipeline — that pipeline is
    /// not exercised here (it's the OS-callback surface), but the trackpad
    /// source's NSEvent monitor IS, and it must reject.
    func testExternalMouseClick_doesNotFireTrackpadTap() async {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: monitor)
        // Tap rate 0.5/s: a single click is enough rate-wise — IF
        // attribution gate lets it through. The attribution gate is what
        // we're actually testing; rate is not the focus.
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.1, scrollMax: 0.8,
            touchingMin: 0.1, touchingMax: 0.5,
            slidingMin: 0.5, slidingMax: 0.9,
            contactMin: 0.5, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0,
            tappingEnabled: true
        )
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        // No trackpad gesture has occurred. User clicks the external mouse.
        // NSEvent's global monitor catches it and the trackpad source sees
        // a leftMouseDown. The attribution gate must drop it.
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(80))

        let collected = await collectTask.value
        let kinds = collected.map(\.kind)
        XCTAssertFalse(
            kinds.contains(.trackpadTapping),
            "[scenario=external-mouse-click] click without prior trackpad gesture must NOT credit trackpadTapping; got \(kinds)"
        )
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Scenario 2: trackpad gesture then trackpad tap

    /// User scrolls with two fingers on the trackpad (a confirmed
    /// trackpad gesture), then taps within the attribution window.
    /// The trackpad source SHOULD credit the click as a trackpad tap.
    func testTrackpadGestureThenTap_firesTrackpadTap() async throws {
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
            tappingEnabled: true
        )
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.6) }
        try? await Task.sleep(for: .milliseconds(20))

        // Step 1: trackpad scroll gesture (non-empty phase) — stamps
        // lastTrackpadGestureAt.
        if let scroll = makeTrackpadScroll() {
            monitor.emit(scroll, ofType: .scrollWheel)
        } else {
            throw XCTSkip("CGEvent could not synthesize a phased scroll on this host")
        }
        try? await Task.sleep(for: .milliseconds(50))

        // Step 2: click within the attribution window (0.5s).
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let kinds = collected.map(\.kind)
        XCTAssertTrue(
            kinds.contains(.trackpadTapping),
            "[scenario=trackpad-gesture-then-tap] click after recent trackpad gesture must credit trackpadTapping; got \(kinds)"
        )
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Scenario 3: trackpad gesture, long delay, then click

    /// User scrolls on the trackpad. Then walks away and 2 seconds later
    /// clicks an external mouse (still in the same session). The click is
    /// outside the attribution window — must NOT credit trackpad.
    func testStaleTrackpadGesture_doesNotCarryOver() async throws {
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
            tappingEnabled: true
        )
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 1.4) }
        try? await Task.sleep(for: .milliseconds(20))

        if let scroll = makeTrackpadScroll() {
            monitor.emit(scroll, ofType: .scrollWheel)
        } else {
            throw XCTSkip("CGEvent could not synthesize a phased scroll on this host")
        }
        // Wait > tapAttributionWindow (0.5s).
        try? await Task.sleep(for: .milliseconds(900))

        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let kinds = collected.map(\.kind)
        XCTAssertFalse(
            kinds.contains(.trackpadTapping),
            "[scenario=stale-gesture-then-click] click >0.5s after trackpad gesture must NOT credit trackpadTapping; got \(kinds)"
        )
        trackpad.stop()
        await bus.close()
    }

    // MARK: - Scenario 4: tapping disabled — no crediting at all

    /// When trackpad tapping is disabled, no clicks should ever fire
    /// trackpadTapping regardless of attribution window state.
    func testTappingDisabled_noTapsRegardlessOfAttribution() async {
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
            tappingEnabled: false   // <-- toggled off
        )
        trackpad.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        if let scroll = makeTrackpadScroll() {
            monitor.emit(scroll, ofType: .scrollWheel)
        }
        try? await Task.sleep(for: .milliseconds(50))
        monitor.emit(makeLeftMouseDown(), ofType: .leftMouseDown)
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let kinds = collected.map(\.kind)
        XCTAssertFalse(
            kinds.contains(.trackpadTapping),
            "[scenario=tapping-disabled] tapping disabled must suppress trackpadTapping; got \(kinds)"
        )
        trackpad.stop()
        await bus.close()
    }
}
