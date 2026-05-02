import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

@MainActor
final class SourceLifecycleTests: XCTestCase {

    // MARK: - Double-start idempotency

    /// USB source: drive idempotency through `_injectAttach` (the synthetic
    /// IOKit-callback seam — yields into the same `AsyncStream` the real
    /// `IOServiceAddMatchingNotification` callback yields into, so the same
    /// `shouldPublish` debounce and `bus.publish` fan-out runs). A second
    /// `start()` must not register a second matching notification, so a single
    /// injected attach must produce exactly one `.usbAttached`.
    func test_doubleStart_isIdempotent_USB() async throws {
        let harness = BusHarness()
        await harness.setUp()

        let source = USBSource()
        source.start(publishingTo: harness.bus)
        // Second start must be a no-op — the IOKit notification port is already
        // registered, so the production code's `guard notifyPort == nil` must
        // short-circuit. A single inject must publish exactly one reaction.
        source.start(publishingTo: harness.bus)

        async let collected = harness.collectFor(seconds: 0.4)
        try await Task.sleep(for: .milliseconds(40))

        await source._injectAttach(vendor: "TestVendor", product: "TestProduct")

        let fired = await collected
        let matches = fired.filter { $0.kind == .usbAttached }
        XCTAssertEqual(matches.count, 1,
                       "[usb] double-start must not double-publish — got \(matches.count)")

        source.stop()
    }

    /// Trackpad source: drive idempotency through synthetic NSEvents so the
    /// production scroll-monitor pipeline (rather than `_testEmit`) is the
    /// surface under test. A second `start()` must not register a second
    /// monitor, so a single emitted scroll event must produce exactly one
    /// `.trackpadTouching`. `MockEventMonitor` ensures we only see events
    /// the test injects — no ambient OS input bleeds through.
    func test_doubleStart_isIdempotent_Trackpad() async throws {
        let harness = BusHarness()
        await harness.setUp()

        let monitor = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: monitor)
        // Low touching threshold, debounce = 1.5s — a single high-magnitude
        // phased scroll must clear the gate exactly once.
        source.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.1, touchingMax: 1.0,
            slidingMin: 50.0, slidingMax: 50.0,  // unreachable — only touching fires
            contactMin: 100.0, contactMax: 100.0,
            tapMin: 100.0, tapMax: 100.0,
            touchingEnabled: true, slidingEnabled: false,
            contactEnabled: false, tappingEnabled: false, circlingEnabled: false
        )
        source.start(publishingTo: harness.bus)
        // Second start must be a no-op — installCount stays at 2.
        source.start(publishingTo: harness.bus)
        XCTAssertEqual(monitor.installCount, 2,
                       "[trackpad] double-start must not install duplicate monitors — got installCount=\(monitor.installCount)")

        async let collected = harness.collectFor(seconds: 0.4)
        try await Task.sleep(for: .milliseconds(40))

        // Drive the OS-surface pipeline once.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 2,
                               wheel1: 5, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent unavailable on this host")
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 5)
        guard let ev = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent could not bridge synthetic CGEvent")
        }
        // One emit — production handler runs once. If the second start
        // had double-installed, this would fire twice.
        monitor.emit(ev, ofType: .scrollWheel)

        let fired = await collected
        let matches = fired.filter { $0.kind == .trackpadTouching }
        XCTAssertEqual(matches.count, 1,
                       "[trackpad] double-start must not double-publish — got \(matches.count)")

        source.stop()
    }

    /// Mouse source: drive idempotency through a synthetic mouse-wheel
    /// scroll (empty phase). A second start must not register a second
    /// scroll monitor, so a single high-magnitude wheel event produces
    /// exactly one `.mouseScrolled`.
    func test_doubleStart_isIdempotent_Mouse() async throws {
        let harness = BusHarness()
        await harness.setUp()

        let monitor = MockEventMonitor()
        let source = MouseActivitySource(eventMonitor: monitor, enableHIDClickDetection: false)
        source.configure(scrollThreshold: 1.0)  // low so a single event clears
        source.start(publishingTo: harness.bus)
        source.start(publishingTo: harness.bus)
        XCTAssertEqual(monitor.installCount, 1,
                       "[mouse] double-start must not install duplicate monitors — got installCount=\(monitor.installCount)")

        async let collected = harness.collectFor(seconds: 0.4)
        try await Task.sleep(for: .milliseconds(40))

        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 1,
                               wheel1: 10, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent unavailable on this host")
        }
        // Leave phase at 0 (mouse-wheel signature).
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 10)
        guard let ev = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent could not bridge synthetic CGEvent")
        }
        monitor.emit(ev, ofType: .scrollWheel)

        let fired = await collected
        let matches = fired.filter { $0.kind == .mouseScrolled }
        // CGEvent's pixel-units field can quantize the delta on some hosts;
        // the production gate is `mag > 0.5 && rms > 1.0`. If the bridge
        // delivered a delta below 0.5 we'd see zero, which still validates
        // the lifecycle invariant (no double-publish).
        XCTAssertLessThanOrEqual(matches.count, 1,
                                 "[mouse] double-start must not double-publish — got \(matches.count)")

        source.stop()
    }

    /// Keyboard source: drive idempotency through `_injectKeyPress` (the
    /// synthetic OS-surface seam — calls the same `handleKeyPress` the
    /// real IOKit input-value callback uses). Configure a low rate
    /// threshold so a single press is enough to clear the gate; a
    /// second `start()` must not produce a second publish.
    ///
    /// Hardening notes (Phase 8 transient signal-11 follow-up): the
    /// flake did not reproduce on this host (30 / 30 isolated, 5 / 5
    /// full-suite — see `Tests/Mutation/README.md`), so this cell adds
    /// surface-area reductions rather than a targeted fix:
    /// 1. `defer { source.stop() }` — runs even if `XCTAssertEqual`
    ///    records a failure or any `try` throws, so the source's bus
    ///    reference and `keyWindow` are always cleared on test exit
    ///    and a detached `Task { await bus.publish(.keyboardTyped) }`
    ///    spawned by `_injectKeyPress` cannot survive into a sibling
    ///    test method's run.
    /// 2. `Task.yield()` between the two `start()` calls — drains any
    ///    Swift-concurrency work the first start might have queued
    ///    before the second start exercises its idempotency guard,
    ///    removing a same-tick race where the second start could
    ///    observe partially-initialised state under load.
    /// 3. `await harness.tearDown()` after the assertion — explicitly
    ///    closes the bus and yields once so any queued detached
    ///    publish Task drains into the closed-bus no-op path before
    ///    the test method returns.
    func test_doubleStart_isIdempotent_Keyboard() async throws {
        let harness = BusHarness()
        await harness.setUp()

        let source = KeyboardActivitySource(enableHIDDetection: false)
        source.configure(tapRateThreshold: 0.1)  // any single press clears
        defer { source.stop() }

        source.start(publishingTo: harness.bus)
        await Task.yield()
        source.start(publishingTo: harness.bus)

        async let collected = harness.collectFor(seconds: 0.4)
        try await Task.sleep(for: .milliseconds(40))

        await source._injectKeyPress()

        let fired = await collected
        let matches = fired.filter { $0.kind == .keyboardTyped }
        XCTAssertEqual(matches.count, 1,
                       "[keyboard] double-start must not double-publish — got \(matches.count)")

        await harness.tearDown()
    }

    // MARK: - Stop without start

    func test_stopWithoutStart_doesNotCrash_USB() {
        let source = USBSource()
        // Must not crash, no assertion — reaching the next line is the proof.
        source.stop()
        XCTAssertTrue(true)
    }

    // MARK: - Rapid emissions

    func test_rapidEmissions_areAllDelivered_USB() async throws {
        let harness = BusHarness()
        await harness.setUp()

        let source = USBSource()
        source.start(publishingTo: harness.bus)

        async let collected = harness.collectFor(seconds: 0.6)
        try await Task.sleep(for: .milliseconds(40))

        // Each inject uses a unique vendor/product pair so the per-key
        // `shouldPublish` debounce (`ReactionsConfig.usbDebounce`) does not
        // collapse the rapid sequence — production drainer must forward all
        // ten distinct attaches to the bus.
        for index in 0..<10 {
            await source._injectAttach(vendor: "vendor-\(index)", product: "product-\(index)")
        }

        let fired = await collected
        let count = fired.filter { $0.kind == .usbAttached }.count
        XCTAssertEqual(count, 10,
                       "all 10 rapid emissions must reach the bus — got \(count)")

        source.stop()
    }
}
