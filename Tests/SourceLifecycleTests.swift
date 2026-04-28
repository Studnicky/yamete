import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

@MainActor
final class SourceLifecycleTests: XCTestCase {

    // MARK: - Double-start idempotency

    func test_doubleStart_isIdempotent_USB() async throws {
        try await assertDoubleStartIdempotent(makeSource: { USBSource() }, kind: .usbAttached)
    }

    /// Trackpad / Mouse / Keyboard sources subscribe to REAL NSEvent global
    /// monitors and IOHIDManager callbacks via their default initializer.
    /// During the 0.4s collect window, ambient OS-level input from the developer's
    /// hands (scrolling, typing, mouse clicks while the test runs) can produce
    /// extra events on the bus and fail the "exactly one delivery" assertion.
    /// These sources inject `MockEventMonitor` + `MockHIDDeviceMonitor` so the
    /// test sees ONLY events produced by `_testEmit`. The bus + lifecycle
    /// path is still exercised end-to-end; only the OS-input source is mocked.
    func test_doubleStart_isIdempotent_Trackpad() async throws {
        try await assertDoubleStartIdempotent(
            makeSource: { TrackpadActivitySource(eventMonitor: MockEventMonitor()) },
            kind: .trackpadTouching
        )
    }

    func test_doubleStart_isIdempotent_Mouse() async throws {
        try await assertDoubleStartIdempotent(
            makeSource: { MouseActivitySource(eventMonitor: MockEventMonitor()) },
            kind: .mouseClicked
        )
    }

    private func assertDoubleStartIdempotent<S: StimulusSource>(
        makeSource: () -> S,
        kind: ReactionKind
    ) async throws {
        let harness = BusHarness()
        await harness.setUp()

        let source = makeSource()
        await source.start(publishingTo: harness.bus)
        // Second start must be a no-op — the test seam targets the bus stored
        // on the first call. Either way, _testEmit must produce exactly one
        // FiredReaction per call.
        await source.start(publishingTo: harness.bus)

        async let collected = harness.collectFor(seconds: 0.4)
        try await Task.sleep(for: .milliseconds(40))

        guard let emitter = source as? TestEmitter else {
            XCTFail("Source \(type(of: source)) does not conform to TestEmitter")
            return
        }
        await emitter._testEmit(kind)

        let fired = await collected
        let matches = fired.filter { $0.kind == kind }
        XCTAssertEqual(matches.count, 1,
                       "double-start must not double-publish — got \(matches.count) for \(kind.rawValue)")

        source.stop()
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
        await source.start(publishingTo: harness.bus)

        async let collected = harness.collectFor(seconds: 0.6)
        try await Task.sleep(for: .milliseconds(40))

        for _ in 0..<10 {
            await source._testEmit(.usbAttached)
        }

        let fired = await collected
        let count = fired.filter { $0.kind == .usbAttached }.count
        XCTAssertEqual(count, 10,
                       "all 10 rapid emissions must reach the bus — got \(count)")

        source.stop()
    }
}
