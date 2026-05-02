import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Source-detection-pipeline → output coverage: drive a stimulus source
/// through its real OS-event surface (`MockEventMonitor.emit(...)` →
/// debounce / attribution / RMS thresholds) and assert the output sees
/// the resulting `ReactionKind`.
///
/// This file owns Ring 1 / OS-surface migration cells ONLY. The legacy
/// `_testEmit`-based "every source kind reaches output / disabled kind
/// is blocked" loops have moved to `BusRoutingContractTests`
/// (`test_busRoutes_everySourceKind_toSubscribedOutput` /
/// `test_busBlocks_disabledKind_fromOutput`) — they were orthogonal
/// bus-fanout coverage, not Ring 1 misses.
///
/// Sources whose detection isn't NSEvent-driven (USB, Power,
/// AudioPeripheral, Bluetooth, Thunderbolt, Display, Sleep, Keyboard
/// HID, IOHID mouse-click) get their OS-surface coverage in the
/// `Matrix*OSEvents_Tests` and `MatrixL2_*` families via dedicated
/// `_inject*` seams. Bus-fanout coverage for every declared kind across
/// every source lives in `BusRoutingContractTests`.
@MainActor
final class StimulusToOutputScenariosTests: XCTestCase {

    // MARK: - OS-surface migration cells

    func test_trackpadGesture_OSSurface_reachesOutput() async throws {
        let harness = BusHarness()
        await harness.setUp()
        let monitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: monitor)
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.0, touchingMax: 1.0,
            slidingMin: 0.0, slidingMax: 1.0,
            contactMin: 0.5, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0
        )
        trackpad.start(publishingTo: harness.bus)

        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()
        let consumeTask = Task { @MainActor [bus = harness.bus] in
            await spy.consume(from: bus, configProvider: provider)
        }
        try await Task.sleep(for: .milliseconds(30))

        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 2,
                               wheel1: 30, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent unavailable on this host")
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        guard let nsEvent = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent bridge unavailable")
        }
        for _ in 0..<5 {
            monitor.emit(nsEvent, ofType: .scrollWheel)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(150))

        let trackpadKinds: Set<ReactionKind> = [.trackpadTouching, .trackpadSliding, .trackpadContact, .trackpadCircling]
        XCTAssertTrue(spy.actionKinds().contains(where: { trackpadKinds.contains($0) }),
                      "[trackpadActivity/OSSurface] gesture must produce an action — got \(spy.actionKinds().map(\.rawValue))")
        trackpad.stop()
        consumeTask.cancel()
        await harness.close()
    }

    /// Trackpad gesture-then-tap — drives the click attribution path through
    /// the OS surface end-to-end and asserts `.trackpadTapping` reaches the
    /// output. This is the migrated counterpart of the legacy
    /// `_testEmit(.trackpadTapping)` flow.
    func test_trackpadTap_afterGesture_OSSurface_reachesOutput() async throws {
        let harness = BusHarness()
        await harness.setUp()
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
        trackpad.start(publishingTo: harness.bus)

        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()
        let consumeTask = Task { @MainActor [bus = harness.bus] in
            await spy.consume(from: bus, configProvider: provider)
        }
        // Wait for subscriber registration before driving events. Polling
        // is robust against scheduling delays on the GitHub macos runner —
        // a fixed 30 ms lead can land before the consume task has actually
        // registered, which means the gesture flows into a bus with no
        // subscribers and the test fails for an unrelated reason.
        _ = await awaitUntil(timeout: 1.0) {
            await harness.bus._testSubscriberCount() > 0
        }

        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 2,
                               wheel1: 5, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent unavailable on this host")
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        guard let scroll = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent bridge unavailable")
        }
        monitor.emit(scroll, ofType: .scrollWheel)
        // CI-scaled gap between gesture and click. The attribution window
        // in TrackpadActivitySource closes after a few hundred ms, but the
        // click must land AFTER the scroll has been ingested by the source.
        // 50 ms is comfortable locally; on slow CI the scroll ingest may
        // not have completed — scaling gives the source room to settle.
        try await Task.sleep(for: CITiming.scaledDuration(ms: 50))

        let click = NSEvent.mouseEvent(
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
        monitor.emit(click, ofType: .leftMouseDown)
        // Replace the brittle 180 ms fixed sleep with a poll on the spy's
        // recorded actions. The trackpad source's attribution + the bus
        // fanout + the output's lifecycle take wildly variable wall time
        // under CI load; awaitUntil scales the timeout via CITiming and
        // returns the moment the assertion would pass.
        _ = await awaitUntil(timeout: 2.0) {
            spy.actionKinds().contains(.trackpadTapping)
        }

        XCTAssertTrue(spy.actionKinds().contains(.trackpadTapping),
                      "[trackpadActivity/OSSurface tapping] gesture+click must produce trackpadTapping — got \(spy.actionKinds().map(\.rawValue))")
        trackpad.stop()
        consumeTask.cancel()
        await harness.close()
    }

    // BLOCKED CELLS (require parallel-agent injection seams):
    // - mouseClicked via OS surface: needs MouseActivitySource._injectClick(transport:product:)
    // - mouseScrolled via OS surface: viable via MockEventMonitor.emit + makeMouseScroll,
    //   but RMS threshold in MouseActivitySource is non-trivial to drive reliably
    //   from synthetic CGEvent magnitudes — leaving for parallel agent's _injectMouseWheel
    //   or equivalent if they add one.
    // - keyboardTyped via OS surface: needs _injectKeyPress; the seam is being added
    //   by the keyboard-source agent. Bus-fanout coverage of `.keyboardTyped`
    //   lives in BusRoutingContractTests until that seam compiles cleanly.
    // - usbAttached / usbDetached / acConnected / acDisconnected / etc.:
    //   require _injectAttach / _injectPowerChange / _injectWillSleep seams from
    //   the IOKit-callback-source agent.
}
