import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Lifecycle matrix for the three activity sources after EventMonitor
/// injection. Each source goes through (notStarted, running, stopped,
/// restarted) and (monitor-installs / monitor-fails-to-install).
@MainActor
final class MatrixActivitySourceLifecycle_Tests: XCTestCase {

    // MARK: - TrackpadActivitySource

    func testTrackpadStartInstallsTwoMonitors() async throws {
        let mock = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        XCTAssertEqual(mock.installedCount, 0, "notStarted: no monitors")
        source.start(publishingTo: bus)
        XCTAssertEqual(mock.installedCount, 2, "running: scroll + tap monitors installed")
        XCTAssertEqual(mock.installCount, 2)
    }

    func testTrackpadStopRemovesMonitors() async throws {
        let mock = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        source.stop()
        XCTAssertEqual(mock.installedCount, 0, "stopped: all monitors removed")
        XCTAssertEqual(mock.removalCount, 2)
    }

    func testTrackpadRestartPattern() async throws {
        let mock = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        for _ in 0..<3 {
            source.start(publishingTo: bus)
            source.stop()
        }
        XCTAssertEqual(mock.installCount, 6, "3 cycles × 2 monitors per cycle = 6 installs")
        XCTAssertEqual(mock.removalCount, 6, "all installs removed")
    }

    func testTrackpadInstallFailureLeavesNoMonitor() async throws {
        let mock = MockEventMonitor()
        mock.shouldFailInstall = true
        let source = TrackpadActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        XCTAssertEqual(mock.installCount, 2, "start attempts both monitors")
        XCTAssertEqual(mock.installedCount, 0, "but neither registers a token")
    }

    func testTrackpadStartIsIdempotent() async throws {
        let mock = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)  // second call should be a no-op
        XCTAssertEqual(mock.installCount, 2, "second start is a no-op")
    }

    // MARK: - MouseActivitySource

    func testMouseStartInstallsScrollMonitor() async throws {
        let mock = MockEventMonitor()
        let source = MouseActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        XCTAssertEqual(mock.installedCount, 1, "running: scroll monitor only (HID for clicks)")
    }

    func testMouseStopRemovesScrollMonitor() async throws {
        let mock = MockEventMonitor()
        let source = MouseActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        source.stop()
        XCTAssertEqual(mock.installedCount, 0)
        XCTAssertEqual(mock.removalCount, 1)
    }

    func testMouseInstallFailure() async throws {
        let mock = MockEventMonitor()
        mock.shouldFailInstall = true
        let source = MouseActivitySource(eventMonitor: mock)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        XCTAssertEqual(mock.installCount, 1)
        XCTAssertEqual(mock.installedCount, 0, "failed installs leave no token")
    }

    // MARK: - KeyboardActivitySource

    func testKeyboardStartHasNoEventMonitor() async throws {
        // Keyboard uses pure HID, no NSEvent monitor. Start shouldn't crash.
        let source = KeyboardActivitySource()
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        source.stop()
    }

    // MARK: - Hardware-presence × monitor-success cross-product

    func testTrackpadFullMatrix() async throws {
        // (presence × monitor-success) × (start, restart) → 8 cells
        for hardwarePresent in [true, false] {
            for monitorSucceeds in [true, false] {
                let hidMonitor = MockHIDDeviceMonitor()
                if hardwarePresent {
                    hidMonitor.setCannedDevices([
                        HIDDeviceInfo(transport: "SPI", product: "trackpad", vendorID: 0, productID: 0)
                    ])
                }
                let presenceObserved = TrackpadActivitySource.isPresent(monitor: hidMonitor)
                XCTAssertEqual(presenceObserved, hardwarePresent,
                               "presence(\(hardwarePresent)) match")

                let eventMonitor = MockEventMonitor()
                eventMonitor.shouldFailInstall = !monitorSucceeds
                let source = TrackpadActivitySource(eventMonitor: eventMonitor)
                let bus = ReactionBus()
                source.start(publishingTo: bus)
                source.stop()
                if monitorSucceeds {
                    XCTAssertEqual(eventMonitor.removalCount, 2, "monitor=true removes 2")
                } else {
                    XCTAssertEqual(eventMonitor.removalCount, 0, "monitor=false never installed")
                }
            }
        }
    }
}
