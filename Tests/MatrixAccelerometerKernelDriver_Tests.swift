import XCTest
import IOKit
@testable import SensorKit
@testable import YameteCore

/// Mutation-anchor cells for the kernel-result fidelity gates in
/// `Sources/SensorKit/AccelerometerReader.swift`. Each cell drives a
/// real production entry point (`SensorActivation.activate`,
/// `SensorActivation.deactivate`, `AccelHardware.isSPUDevicePresent`,
/// `AccelHardware.isSensorActivelyReporting`, `AccelHardware.openStream`)
/// with `MockAccelerometerKernelDriver` configured to force a kernel
/// failure code on a single call. The cell then asserts:
///   • the production function returned the failure-path value, OR
///   • the loop body downstream of the gate did NOT execute (counter on
///     the mock stays at zero), proving the gate short-circuited.
///
/// Mutations target each gate's `KERN_SUCCESS` / `kIOReturnSuccess` /
/// iterator-sentinel comparison. Removing the gate (or inverting it)
/// runs the loop body anyway / takes the success path anyway, which the
/// counter assertions surface as a non-zero call count or a wrong
/// return value.
final class MatrixAccelerometerKernelDriver_Tests: XCTestCase {

    // MARK: - SensorActivation.activate — L174 KERN_SUCCESS gate

    /// `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS else { return false }`
    /// at the head of `SensorActivation.activate`. With the gate present,
    /// a forced kernel failure makes `activate` return false and the
    /// loop body must NEVER execute (no `registrySetCFProperty` calls).
    /// Removing the gate runs the loop body anyway, which the counter
    /// catches.
    func testActivate_matchingFailure_shortCircuitsBeforeRegistryWrites() {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceMatchingFailureKr(KERN_FAILURE)

        let result = SensorActivation.activate(reportIntervalUS: 10000, driver: mock)

        XCTAssertFalse(
            result,
            "[accel-kernel-gate=activate-matching-fidelity] forced KERN_FAILURE on getMatchingServices must yield activate=false (got true)"
        )
        XCTAssertEqual(
            mock.registrySetPropertyCalls, 0,
            "[accel-kernel-gate=activate-matching-fidelity] forced KERN_FAILURE must short-circuit before loop body (got \(mock.registrySetPropertyCalls) registrySetCFProperty calls)"
        )
    }

    // MARK: - SensorActivation.activate — L180 iterator sentinel gate

    /// `guard service != 0 else { break }` inside `SensorActivation.activate`'s
    /// `while true` loop. On the happy path the mock yields exactly one
    /// non-zero service then 0; the gate breaks on the second call. With
    /// the gate inverted (`service == 0`) the loop breaks BEFORE
    /// processing the synthetic service, so the registry-write counter
    /// stays at 0.
    func testActivate_iteratorYieldsOneService_loopBodyExecutesThreeWrites() {
        let mock = MockAccelerometerKernelDriver()

        _ = SensorActivation.activate(reportIntervalUS: 10000, driver: mock)

        // One iteration writes 3 properties (ReportInterval,
        // SensorPropertyReportingState, SensorPropertyPowerState).
        XCTAssertEqual(
            mock.registrySetPropertyCalls, 3,
            "[accel-kernel-gate=activate-iterator-sentinel] iterator yielded one service but loop body did not execute its 3 registry writes (got \(mock.registrySetPropertyCalls))"
        )
        // Iterator queried twice: once yields service, second returns 0
        // and the sentinel gate breaks.
        XCTAssertEqual(
            mock.iteratorNextCalls, 2,
            "[accel-kernel-gate=activate-iterator-sentinel] iterator must be polled exactly twice (once for service, once for sentinel); got \(mock.iteratorNextCalls)"
        )
    }

    // MARK: - SensorActivation.deactivate — L203 KERN_SUCCESS gate

    /// `guard ... == KERN_SUCCESS else { return }` at the head of
    /// `SensorActivation.deactivate`. Forced kernel failure must
    /// short-circuit; loop body's registry writes must be zero.
    func testDeactivate_matchingFailure_shortCircuitsBeforeRegistryWrites() {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceMatchingFailureKr(KERN_FAILURE)

        SensorActivation.deactivate(driver: mock)

        XCTAssertEqual(
            mock.registrySetPropertyCalls, 0,
            "[accel-kernel-gate=deactivate-matching-fidelity] forced KERN_FAILURE must short-circuit deactivate before loop body (got \(mock.registrySetPropertyCalls) registry writes)"
        )
    }

    // MARK: - SensorActivation.deactivate — L208 iterator sentinel gate

    /// `guard service != 0 else { break }` inside `deactivate`'s loop.
    /// One iteration writes 3 properties; mutated gate that flips the
    /// comparison breaks immediately and the writes are zero.
    func testDeactivate_iteratorYieldsOneService_loopBodyExecutesThreeWrites() {
        let mock = MockAccelerometerKernelDriver()

        SensorActivation.deactivate(driver: mock)

        XCTAssertEqual(
            mock.registrySetPropertyCalls, 3,
            "[accel-kernel-gate=deactivate-iterator-sentinel] iterator yielded one service but loop body did not execute its 3 registry writes (got \(mock.registrySetPropertyCalls))"
        )
    }

    // MARK: - AccelHardware.isSPUDevicePresent — L238 IOHIDManagerOpen gate

    /// `guard IOHIDManagerOpen(...) == kIOReturnSuccess else { return false }`.
    /// Forced manager-open failure must yield false and short-circuit
    /// before `hidManagerCopyDevices` is called.
    func testIsSPUDevicePresent_managerOpenFailure_returnsFalseShortCircuit() {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceManagerOpenFailure(kIOReturnNotPermitted)

        let present = AccelHardware.isSPUDevicePresent(driver: mock)

        XCTAssertFalse(
            present,
            "[accel-kernel-gate=isSPUDevicePresent-managerOpen-fidelity] forced kIOReturnNotPermitted on IOHIDManagerOpen must yield false (got true)"
        )
        XCTAssertEqual(
            mock.hidDeviceTransportCalls, 0,
            "[accel-kernel-gate=isSPUDevicePresent-managerOpen-fidelity] forced manager-open failure must short-circuit before transport probing (got \(mock.hidDeviceTransportCalls) transport calls)"
        )
    }

    // MARK: - AccelHardware.isSensorActivelyReporting — L270 KERN_SUCCESS gate

    /// `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS else { return false }`
    /// at the head of `isSensorActivelyReporting`. Forced failure must
    /// yield false and short-circuit before the iterator is polled.
    func testIsSensorActivelyReporting_matchingFailure_returnsFalseShortCircuit() {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceMatchingFailureKr(KERN_FAILURE)

        let reporting = AccelHardware.isSensorActivelyReporting(driver: mock)

        XCTAssertFalse(
            reporting,
            "[accel-kernel-gate=isSensorActivelyReporting-matching-fidelity] forced KERN_FAILURE must yield false (got true)"
        )
        XCTAssertEqual(
            mock.iteratorNextCalls, 0,
            "[accel-kernel-gate=isSensorActivelyReporting-matching-fidelity] forced KERN_FAILURE must short-circuit before iterator polling (got \(mock.iteratorNextCalls) iteratorNext calls)"
        )
    }

    // MARK: - AccelHardware.isSensorActivelyReporting — L277 iterator sentinel

    /// `guard service != 0 else { break }` inside `isSensorActivelyReporting`'s
    /// iterator loop. The probe queries `dispatchAccel` and `DebugState`
    /// per service. Mock yields one service then 0; the loop body must
    /// execute its two `registryCreateCFProperty` calls. Mutated gate
    /// that breaks early skips the body and the counter is 0.
    func testIsSensorActivelyReporting_iteratorYieldsOneService_loopBodyProbesTwoProperties() {
        let mock = MockAccelerometerKernelDriver()

        _ = AccelHardware.isSensorActivelyReporting(driver: mock)

        XCTAssertEqual(
            mock.registryCreatePropertyCalls, 2,
            "[accel-kernel-gate=isSensorActivelyReporting-iterator-sentinel] iterator yielded one service but loop body did not probe dispatchAccel + DebugState (got \(mock.registryCreatePropertyCalls) registryCreateCFProperty calls)"
        )
    }

    // MARK: - AccelHardware.openStream — IOHIDManagerOpen gate

    /// `guard openResult == kIOReturnSuccess else { ... }` at the head
    /// of `openStream`. Forced manager-open failure must surface
    /// `SensorError.ioKitError` on the consumer stream and short-circuit
    /// before any device-side work.
    func testOpenStream_managerOpenFailure_surfacesIoKitErrorShortCircuit() async {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceManagerOpenFailure(kIOReturnNotPermitted)

        let stream = AccelHardware.openStream(
            adapterID: SensorID.accelerometer,
            adapterName: "test",
            reportIntervalUS: 10000,
            bandpassLowHz: 20.0, bandpassHighHz: 25.0,
            detectorConfig: .accelerometer(),
            driver: mock
        )

        var caughtIoKitError = false
        do {
            for try await _ in stream {
                XCTFail("[accel-kernel-gate=openStream-managerOpen-fidelity] no impact must reach the consumer when manager-open fails")
            }
        } catch SensorError.ioKitError {
            caughtIoKitError = true
        } catch {
            XCTFail("[accel-kernel-gate=openStream-managerOpen-fidelity] expected SensorError.ioKitError, got \(error)")
        }

        XCTAssertTrue(
            caughtIoKitError,
            "[accel-kernel-gate=openStream-managerOpen-fidelity] forced kIOReturnNotPermitted on IOHIDManagerOpen must surface ioKitError"
        )
        XCTAssertEqual(
            mock.hidDeviceOpenCalls, 0,
            "[accel-kernel-gate=openStream-managerOpen-fidelity] forced manager-open failure must short-circuit before IOHIDDeviceOpen (got \(mock.hidDeviceOpenCalls) device-open calls)"
        )
    }

    // MARK: - AccelHardware.openStream — IOHIDDeviceOpen gate

    /// `guard devOpenResult == kIOReturnSuccess else { ... }` after the
    /// per-device open call. Forced device-open failure must surface
    /// `SensorError.ioKitError` and short-circuit before
    /// `hidDeviceMaxReportSize` is called.
    func testOpenStream_deviceOpenFailure_surfacesIoKitErrorShortCircuit() async {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceDeviceOpenFailure(kIOReturnNotPermitted)

        let stream = AccelHardware.openStream(
            adapterID: SensorID.accelerometer,
            adapterName: "test",
            reportIntervalUS: 10000,
            bandpassLowHz: 20.0, bandpassHighHz: 25.0,
            detectorConfig: .accelerometer(),
            driver: mock
        )

        var caughtIoKitError = false
        do {
            for try await _ in stream {
                XCTFail("[accel-kernel-gate=openStream-deviceOpen-fidelity] no impact must reach the consumer when device-open fails")
            }
        } catch SensorError.ioKitError {
            caughtIoKitError = true
        } catch {
            XCTFail("[accel-kernel-gate=openStream-deviceOpen-fidelity] expected SensorError.ioKitError, got \(error)")
        }

        XCTAssertTrue(
            caughtIoKitError,
            "[accel-kernel-gate=openStream-deviceOpen-fidelity] forced kIOReturnNotPermitted on IOHIDDeviceOpen must surface ioKitError"
        )
        XCTAssertEqual(
            mock.hidDeviceMaxReportSizeCalls, 0,
            "[accel-kernel-gate=openStream-deviceOpen-fidelity] forced device-open failure must short-circuit before hidDeviceMaxReportSize (got \(mock.hidDeviceMaxReportSizeCalls) maxReportSize calls)"
        )
    }

    // MARK: - AccelHardware.openStream — maxSize > 0 gate

    /// `guard maxSize > 0 else { ... }` after `hidDeviceMaxReportSize`.
    /// Mock returns 0 — production must surface `SensorError.ioKitError`
    /// with the `kIOReturnInternalError` substring (NOT a watchdog-stall
    /// substring) and never allocate a report buffer. The cell pins the
    /// error code so a mutation that drops the gate (allowing maxSize=0
    /// to slip through to the watchdog stall after 5s) does not get
    /// mis-counted as caught.
    func testOpenStream_maxSizeZero_surfacesIoKitError() async {
        let mock = MockAccelerometerKernelDriver()
        mock.setForceMaxReportSizeZero(true)

        let stream = AccelHardware.openStream(
            adapterID: SensorID.accelerometer,
            adapterName: "test",
            reportIntervalUS: 10000,
            bandpassLowHz: 20.0, bandpassHighHz: 25.0,
            detectorConfig: .accelerometer(),
            driver: mock
        )

        var caughtMessage: String?
        do {
            for try await _ in stream {
                XCTFail("[accel-kernel-gate=openStream-maxSize-fidelity] no impact must reach the consumer when maxReportSize is 0")
            }
        } catch SensorError.ioKitError(let msg) {
            caughtMessage = msg
        } catch {
            XCTFail("[accel-kernel-gate=openStream-maxSize-fidelity] expected SensorError.ioKitError, got \(error)")
        }

        // kIOReturnInternalError = 0xe00002bd. The gate-thrown error
        // formats this code; the watchdog stall error string starts
        // with "accelerometer report stream stalled". Asserting the
        // hex-code substring rejects the watchdog-fall-through path
        // that a mutation removing the gate would otherwise produce.
        XCTAssertEqual(
            caughtMessage, String(format: "0x%08x", kIOReturnInternalError),
            "[accel-kernel-gate=openStream-maxSize-fidelity] maxSize=0 must surface ioKitError(0x%08x kIOReturnInternalError) immediately, NOT fall through to a watchdog stall (got \(String(describing: caughtMessage)))"
        )
    }
}
