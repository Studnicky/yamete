import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Behavioural cells for `AppleSPUDevice`, the multi-subscriber broker
/// over the SPU HID device. Each cell drives the broker through a
/// `MockSPUKernelDriver` so the IOKit lifecycle is directly observable
/// (open/close call counts, refcount-driven transitions) without
/// requiring real SPU hardware.
///
/// Fan-out invariant under test: the broker registers exactly ONE
/// input-report callback at the device level on first subscribe, and
/// fans the full report buffer out to every active subscriber regardless
/// of which `(usagePage, usage)` tuple they declared. Subscribers are
/// expected to decode their own bytes; the broker does NOT filter by
/// tuple. These cells exercise that contract via the
/// `_testInjectReport(...)` seam, which synthesises a report through
/// the same dispatch path the C callback would take in production.
final class AppleSPUDevice_Tests: XCTestCase {

    // MARK: - Lifecycle: refcount-driven open/close

    /// First subscribe opens the device exactly once; second subscribe
    /// reuses the open handle (no second `hidManagerCreate`/`hidDeviceOpen`).
    /// Two unsubscribes in sequence close the device exactly once on the
    /// transition to refcount=0.
    func testRefcount_openOnFirstSubscribe_closeOnLastUnsubscribe() async {
        let mock = MockSPUKernelDriver()
        let broker = AppleSPUDevice(driver: mock)

        XCTAssertFalse(broker._testIsDeviceOpen(),
            "[apple-spu-broker=initial-state] device must not be open before any subscribe")

        let firstHandler: @Sendable (SPUReport) -> Void = { _ in }
        guard let token1 = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel, handler: firstHandler) else {
            XCTFail("[apple-spu-broker=first-subscribe] subscribe must succeed with happy-path mock")
            return
        }

        let openCount1 = mock.hidManagerOpenCalls
        let deviceOpenCount1 = mock.hidDeviceOpenCalls
        XCTAssertEqual(openCount1, 1, "[apple-spu-broker=first-subscribe] first subscribe must open IOHIDManager exactly once (got \(openCount1))")
        XCTAssertEqual(deviceOpenCount1, 1, "[apple-spu-broker=first-subscribe] first subscribe must open IOHIDDevice exactly once (got \(deviceOpenCount1))")
        XCTAssertTrue(broker._testIsDeviceOpen(),
            "[apple-spu-broker=first-subscribe] device must be open after first subscribe")
        XCTAssertEqual(broker._testActiveSubscriptionCount(), 1,
            "[apple-spu-broker=first-subscribe] active subscription count must be 1")

        // Second subscribe: refcount only, no IOKit work.
        guard let token2 = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel, handler: firstHandler) else {
            XCTFail("[apple-spu-broker=second-subscribe] subscribe must succeed while device is open")
            return
        }
        XCTAssertEqual(mock.hidManagerOpenCalls, openCount1,
            "[apple-spu-broker=second-subscribe] second subscribe must NOT open the manager again (got \(mock.hidManagerOpenCalls), expected \(openCount1))")
        XCTAssertEqual(mock.hidDeviceOpenCalls, deviceOpenCount1,
            "[apple-spu-broker=second-subscribe] second subscribe must NOT open the device again (got \(mock.hidDeviceOpenCalls), expected \(deviceOpenCount1))")
        XCTAssertEqual(broker._testActiveSubscriptionCount(), 2,
            "[apple-spu-broker=second-subscribe] active subscription count must be 2 after second subscribe")

        // First unsubscribe: refcount falls to 1, device stays open.
        broker.unsubscribe(token1)
        XCTAssertTrue(broker._testIsDeviceOpen(),
            "[apple-spu-broker=first-unsubscribe] device must remain open while another subscriber holds it")
        XCTAssertEqual(broker._testActiveSubscriptionCount(), 1,
            "[apple-spu-broker=first-unsubscribe] active subscription count must be 1 after first unsubscribe")

        // Second unsubscribe: refcount=0, device closes.
        broker.unsubscribe(token2)
        let closed = await awaitUntil(timeout: 1.0) { @MainActor in
            !broker._testIsDeviceOpen()
        }
        XCTAssertTrue(closed,
            "[apple-spu-broker=last-unsubscribe] device must close when refcount drops to 0")
        XCTAssertEqual(broker._testActiveSubscriptionCount(), 0,
            "[apple-spu-broker=last-unsubscribe] active subscription count must be 0 after last unsubscribe")
    }

    // MARK: - Lifecycle: failed open does not corrupt refcount

    /// Forced manager-open failure makes `subscribe` return nil. The
    /// device must NOT be marked open and the active-subscription count
    /// must stay at zero — failing subscribers do not leak refcount.
    func testFailedOpen_returnsNilSubscription_refcountStaysZero() {
        let mock = MockSPUKernelDriver()
        mock.setForceManagerOpenFailure(kIOReturnNotPermitted)
        let broker = AppleSPUDevice(driver: mock)

        let token = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel) { _ in }

        XCTAssertNil(token,
            "[apple-spu-broker=failed-open] forced manager-open failure must yield nil subscription")
        XCTAssertFalse(broker._testIsDeviceOpen(),
            "[apple-spu-broker=failed-open] forced open failure must leave the broker in closed state")
        XCTAssertEqual(broker._testActiveSubscriptionCount(), 0,
            "[apple-spu-broker=failed-open] forced open failure must leave subscription count at 0")
        XCTAssertGreaterThanOrEqual(mock.hidManagerOpenCalls, 1,
            "[apple-spu-broker=failed-open] forced open failure must have actually attempted IOHIDManagerOpen")
    }

    // MARK: - Fan-out: same (usagePage, usage) — both subscribers fire

    /// Two subscribers with the SAME `(usagePage, usage)` tuple both
    /// fire on every report. The single-callback fan-out model means
    /// the broker does not deduplicate; both handlers see the same
    /// report bytes.
    func testFanOut_sameUsageTuple_bothHandlersFire() async {
        let mock = MockSPUKernelDriver()
        let broker = AppleSPUDevice(driver: mock)

        let counterA = Counter()
        let counterB = Counter()

        guard
            let tA = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel, handler: { _ in counterA.increment() }),
            let tB = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel, handler: { _ in counterB.increment() })
        else {
            XCTFail("[apple-spu-broker=fanout-same-tuple] subscribes must succeed")
            return
        }

        // Inject a synthetic report through the broker's dispatch path.
        let bufLen = 24
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
        buf.initialize(repeating: 0, count: bufLen)
        defer { buf.deallocate() }
        broker._testInjectReport(bytes: buf, length: bufLen)

        let bothFired = await awaitUntil(timeout: 1.0) { @MainActor in
            counterA.value == 1 && counterB.value == 1
        }
        XCTAssertTrue(bothFired,
            "[apple-spu-broker=fanout-same-tuple] both subscribers under same (page,usage) must each fire exactly once (a=\(counterA.value), b=\(counterB.value))")

        broker.unsubscribe(tA)
        broker.unsubscribe(tB)
    }

    // MARK: - Fan-out: different (usagePage, usage) — both still fire

    /// Two subscribers with DIFFERENT `(usagePage, usage)` tuples ALSO
    /// both fire on every report. The (page,usage) on the subscription
    /// record is metadata, not a filter — every active subscriber
    /// receives every report. This pins the documented fan-out contract
    /// in the broker's file header against future regressions where a
    /// maintainer might wrongly assume the broker filters by tuple.
    func testFanOut_differentUsageTuples_bothHandlersStillFire() async {
        let mock = MockSPUKernelDriver()
        let broker = AppleSPUDevice(driver: mock)

        let counterAccel = Counter()
        let counterGyro = Counter()

        guard
            let tAccel = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel, handler: { _ in counterAccel.increment() }),
            // Synthetic distinct tuple — the broker does not validate
            // the shape; the test is asserting the fan-out is unconditional.
            let tGyro = broker.subscribe(usagePage: 0xFF00, usage: 4, dispatch: .gyro, handler: { _ in counterGyro.increment() })
        else {
            XCTFail("[apple-spu-broker=fanout-different-tuples] subscribes must succeed")
            return
        }

        let bufLen = 24
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
        buf.initialize(repeating: 0, count: bufLen)
        defer { buf.deallocate() }
        broker._testInjectReport(bytes: buf, length: bufLen)

        let bothFired = await awaitUntil(timeout: 1.0) { @MainActor in
            counterAccel.value == 1 && counterGyro.value == 1
        }
        XCTAssertTrue(bothFired,
            "[apple-spu-broker=fanout-different-tuples] subscribers with different (page,usage) tuples must both fire on the same report (accel=\(counterAccel.value), gyro=\(counterGyro.value))")

        broker.unsubscribe(tAccel)
        broker.unsubscribe(tGyro)
    }

    // MARK: - Fan-out: report bytes propagate intact

    /// The handler receives the full report buffer with the same length
    /// the broker was given. Each subscriber sees the same length —
    /// no truncation per (page, usage).
    func testFanOut_reportBytesAndLengthPropagateIntact() async {
        let mock = MockSPUKernelDriver()
        let broker = AppleSPUDevice(driver: mock)

        let lengthBox = ValueBox<Int>()
        let firstByteBox = ValueBox<UInt8>()

        guard let token = broker.subscribe(usagePage: 0xFF00, usage: 3, dispatch: .accel, handler: { report in
            lengthBox.set(report.length)
            firstByteBox.set(report.bytes.pointee)
        }) else {
            XCTFail("[apple-spu-broker=fanout-bytes] subscribe must succeed")
            return
        }

        let bufLen = 24
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
        // Use a recognisable sentinel byte so the handler can witness
        // the broker did not stomp on the buffer.
        buf.initialize(repeating: 0, count: bufLen)
        buf[0] = 0xA5
        defer { buf.deallocate() }
        broker._testInjectReport(bytes: buf, length: bufLen)

        let received = await awaitUntil(timeout: 1.0) { @MainActor in
            lengthBox.get() != nil && firstByteBox.get() != nil
        }
        XCTAssertTrue(received, "[apple-spu-broker=fanout-bytes] handler must receive the report")
        XCTAssertEqual(lengthBox.get(), bufLen,
            "[apple-spu-broker=fanout-bytes] handler must receive the full length (got \(String(describing: lengthBox.get())), expected \(bufLen))")
        XCTAssertEqual(firstByteBox.get(), 0xA5,
            "[apple-spu-broker=fanout-bytes] handler must observe the buffer's first byte unchanged (got \(String(describing: firstByteBox.get())))")

        broker.unsubscribe(token)
    }

    // MARK: - Static helper: hardware presence

    /// `AppleSPUDevice.isHardwarePresent(driver:)` accepts an injected
    /// kernel driver so cells can drive the static path without real
    /// hardware. Forced manager-open failure must yield false.
    func testIsHardwarePresent_managerOpenFailure_returnsFalse() {
        let mock = MockSPUKernelDriver()
        mock.setForceManagerOpenFailure(kIOReturnNotPermitted)

        let present = AppleSPUDevice.isHardwarePresent(driver: mock)

        XCTAssertFalse(present,
            "[apple-spu-broker=isHardwarePresent-failure-path] forced manager-open failure must yield false")
    }

    /// Happy-path: with the default mock the device-presence check
    /// finds the synthetic device the mock vends and returns true.
    func testIsHardwarePresent_happyPath_returnsTrue() {
        let mock = MockSPUKernelDriver()
        let present = AppleSPUDevice.isHardwarePresent(driver: mock)
        XCTAssertTrue(present,
            "[apple-spu-broker=isHardwarePresent-happy-path] happy-path mock must report the synthetic device as present")
    }
}

// MARK: - Test helpers

/// Lock-protected counter for handler-fire assertions.
private final class Counter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<Int>(initialState: 0)
    func increment() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}

/// Lock-protected single-value box. Captures the first observed value
/// from a handler closure so cells can assert on it after a poll.
private final class ValueBox<T: Sendable>: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<T?>(initialState: nil)
    func set(_ v: T) { state.withLock { $0 = v } }
    func get() -> T? { state.withLock { $0 } }
}
