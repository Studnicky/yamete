import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Headline matrix test: every (source, kind) pair drives a SpyOutput action,
/// and per-kind blocking via the OutputConfigProvider matrix prevents action
/// delivery for the GatedSpyOutput.
@MainActor
final class StimulusToOutputScenariosTests: XCTestCase {

    func test_everySourceKind_reachesSubscribedOutput() async throws {
        for contract in SourceContract.all {
            for kind in contract.emittedKinds {
                try await runReachableCase(contract: contract, kind: kind)
            }
        }
    }

    private func runReachableCase(contract: SourceContract, kind: ReactionKind) async throws {
        let harness = BusHarness()
        await harness.setUp()

        guard let source = SourceContract.makeSource(for: contract.id),
              let emitter = source as? TestEmitter else {
            XCTFail("Cannot build source/emitter for \(contract.id.rawValue)")
            return
        }
        await source.start(publishingTo: harness.bus)

        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()

        let consumeTask = Task { @MainActor [bus = harness.bus] in
            await spy.consume(from: bus, configProvider: provider)
        }
        // Allow consume() to subscribe before emitting.
        try await Task.sleep(for: .milliseconds(30))

        await emitter._testEmit(kind)

        // Give coalesce (16 ms) + action (~2 ms) + slack to land.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(spy.actionKinds().contains(kind),
                      "[\(contract.id.rawValue)/\(kind.rawValue)] action did not fire — got \(spy.actionKinds().map(\.rawValue))")
        // Strict-equal assertion: emitting a single kind must produce
        // EXACTLY one matching action call. A regression where an emit
        // double-fans-out or echos a different kind is caught here.
        let matchCount = spy.actionKinds().filter { $0 == kind }.count
        XCTAssertEqual(matchCount, 1,
                       "[\(contract.id.rawValue)/\(kind.rawValue)] expected exactly 1 action of this kind, got \(matchCount); kinds=\(spy.actionKinds().map(\.rawValue))")

        source.stop()
        consumeTask.cancel()
        await harness.close()
    }

    func test_disabledKind_isBlockedFromOutput() async throws {
        for contract in SourceContract.all {
            for kind in contract.emittedKinds {
                try await runBlockedCase(contract: contract, kind: kind)
            }
        }
    }

    private func runBlockedCase(contract: SourceContract, kind: ReactionKind) async throws {
        let harness = BusHarness()
        await harness.setUp()

        guard let source = SourceContract.makeSource(for: contract.id),
              let emitter = source as? TestEmitter else {
            XCTFail("Cannot build source/emitter for \(contract.id.rawValue)")
            return
        }
        await source.start(publishingTo: harness.bus)

        let provider = MockConfigProvider()
        provider.block(kind: kind)

        let gated = GatedSpyOutput()

        let consumeTask = Task { @MainActor [bus = harness.bus] in
            await gated.consume(from: bus, configProvider: provider)
        }
        try await Task.sleep(for: .milliseconds(30))

        await emitter._testEmit(kind)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(gated.actionKinds().contains(kind),
                       "[\(contract.id.rawValue)/\(kind.rawValue)] action fired despite block — got \(gated.actionKinds().map(\.rawValue))")

        source.stop()
        consumeTask.cancel()
        await harness.close()
    }

    // MARK: - OS-surface migration cells
    //
    // The legacy cells above use `_testEmit` to bypass detection. These
    // cells drive the SAME reaction kind through the OS-event-routing
    // surface (`MockEventMonitor.emit(...)`) and assert the output sees it.
    // Proves the production detection pipeline (debounce, attribution,
    // RMS thresholds) doesn't break delivery for happy-path inputs.
    //
    // Sources whose detection isn't NSEvent-driven (USB, Power,
    // AudioPeripheral, Bluetooth, Thunderbolt, Display, Sleep, Keyboard
    // HID) are NOT covered here — they need their own `_inject*` seams
    // from the parallel agents. Those cells stay on `_testEmit` until
    // those seams land.

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
        try await Task.sleep(for: .milliseconds(30))

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
        try await Task.sleep(for: .milliseconds(50))

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
        try await Task.sleep(for: .milliseconds(180))

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
    //   by the keyboard-source agent. The legacy _testEmit cell remains as the
    //   coverage stand-in until that seam compiles cleanly.
    // - usbAttached / usbDetached / acConnected / acDisconnected / etc.:
    //   require _injectAttach / _injectPowerChange / _injectWillSleep seams from
    //   the IOKit-callback-source agent.
}
