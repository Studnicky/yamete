@preconcurrency import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid
import IOHIDPublic
import os
@testable import SensorKit
import YameteCore

/// Test double for `AccelerometerKernelDriver`. Cells configure failure
/// codes for individual kernel calls — the next call returns the canned
/// failure (and the iteration is consumed, single-shot semantics) so the
/// production code's success-only branch is forced into its
/// failure-handling path.
///
/// Defaults are "happy-path mock":
///   • `getMatchingServices` returns `(KERN_SUCCESS, fakeIterator)`
///   • `iteratorNext` yields a sequence: one synthetic service, then 0
///     so the production loop terminates cleanly.
///   • `hidManagerCreate`, `hidManagerOpen`, `hidDeviceOpen` all return
///     success / a freshly created CF handle.
///   • `hidDeviceMaxReportSize` returns 64.
///   • `hidDeviceTransport` returns the production-required transport
///     (so `findSPUDevice` matches the synthetic device).
///   • `registrySetCFProperty` and `registryCreateCFProperty` are
///     no-ops returning success / nil.
///
/// Failure knobs (all default nil = pass-through to happy path):
///   • `forceMatchingFailureKr` — first `getMatchingServices` returns
///     this kernel result code; iterator is 0.
///   • `forceManagerOpenFailure` — first `hidManagerOpen` returns this
///     `IOReturn` code.
///   • `forceDeviceOpenFailure` — first `hidDeviceOpen` returns this
///     `IOReturn`.
///   • `forceMaxReportSizeZero` — `hidDeviceMaxReportSize` returns 0.
///   • `forceCopyDevicesNil` — `hidManagerCopyDevices` returns nil.
///   • `forceIteratorEmpty` — `iteratorNext` returns 0 immediately
///     (loop body never executes).
///   • `forceTransportMismatch` — `hidDeviceTransport` returns
///     "WRONG-TRANSPORT" so `findSPUDevice` rejects the device.
///   • `forceRegistrySetFailureKr` — `registrySetCFProperty` returns
///     this kr code.
///
/// The mock counts each call so cells can pin "production loop body
/// actually ran" via call-count assertions, which is how iterator
/// sentinel gates (`service != 0 else break`) get caught.
final class MockAccelerometerKernelDriver: AccelerometerKernelDriver, @unchecked Sendable {

    private struct State: Sendable {
        // Failure knobs
        var forceMatchingFailureKr: kern_return_t?
        var forceManagerOpenFailure: IOReturn?
        var forceDeviceOpenFailure: IOReturn?
        var forceMaxReportSizeZero: Bool = false
        var forceCopyDevicesNil: Bool = false
        var forceIteratorEmpty: Bool = false
        var forceTransportMismatch: Bool = false
        var forceRegistrySetFailureKr: kern_return_t?

        // Iterator state — `iteratorNext` returns one service then 0.
        var iteratorYieldsRemaining: Int = 1

        // Call counts — cells pin loop-body execution by asserting these.
        var iteratorNextCalls: Int = 0
        var registrySetPropertyCalls: Int = 0
        var registryCreatePropertyCalls: Int = 0
        var hidManagerCreateCalls: Int = 0
        var hidManagerOpenCalls: Int = 0
        var hidDeviceOpenCalls: Int = 0
        var hidDeviceMaxReportSizeCalls: Int = 0
        var hidDeviceTransportCalls: Int = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    init() {}

    // MARK: - Configuration

    func setForceMatchingFailureKr(_ kr: kern_return_t) {
        state.withLock { $0.forceMatchingFailureKr = kr }
    }

    func setForceManagerOpenFailure(_ kr: IOReturn) {
        state.withLock { $0.forceManagerOpenFailure = kr }
    }

    func setForceDeviceOpenFailure(_ kr: IOReturn) {
        state.withLock { $0.forceDeviceOpenFailure = kr }
    }

    func setForceMaxReportSizeZero(_ flag: Bool) {
        state.withLock { $0.forceMaxReportSizeZero = flag }
    }

    func setForceCopyDevicesNil(_ flag: Bool) {
        state.withLock { $0.forceCopyDevicesNil = flag }
    }

    func setForceIteratorEmpty(_ flag: Bool) {
        state.withLock { $0.forceIteratorEmpty = flag }
    }

    func setForceTransportMismatch(_ flag: Bool) {
        state.withLock { $0.forceTransportMismatch = flag }
    }

    func setForceRegistrySetFailureKr(_ kr: kern_return_t) {
        state.withLock { $0.forceRegistrySetFailureKr = kr }
    }

    // MARK: - Counters

    var iteratorNextCalls: Int { state.withLock { $0.iteratorNextCalls } }
    var registrySetPropertyCalls: Int { state.withLock { $0.registrySetPropertyCalls } }
    var registryCreatePropertyCalls: Int { state.withLock { $0.registryCreatePropertyCalls } }
    var hidManagerCreateCalls: Int { state.withLock { $0.hidManagerCreateCalls } }
    var hidManagerOpenCalls: Int { state.withLock { $0.hidManagerOpenCalls } }
    var hidDeviceOpenCalls: Int { state.withLock { $0.hidDeviceOpenCalls } }
    var hidDeviceMaxReportSizeCalls: Int { state.withLock { $0.hidDeviceMaxReportSizeCalls } }
    var hidDeviceTransportCalls: Int { state.withLock { $0.hidDeviceTransportCalls } }

    // MARK: - AccelerometerKernelDriver conformance

    func getMatchingServices(matching: CFDictionary?) -> (kr: kern_return_t, iterator: io_iterator_t) {
        state.withLock { s in
            if let kr = s.forceMatchingFailureKr {
                s.forceMatchingFailureKr = nil
                return (kr, 0)
            }
            // Synthetic non-zero iterator handle. The mock owns iteration
            // state; the value passed back to production is opaque.
            return (KERN_SUCCESS, fakeIteratorHandle)
        }
    }

    func iteratorNext(_ iterator: io_iterator_t) -> io_service_t {
        state.withLock { s in
            s.iteratorNextCalls += 1
            if s.forceIteratorEmpty { return 0 }
            if s.iteratorYieldsRemaining > 0 {
                s.iteratorYieldsRemaining -= 1
                return fakeServiceHandle
            }
            // Once exhausted, stay exhausted. Cells that drive multiple
            // separate iterations (e.g., activate then deactivate)
            // construct a fresh mock per iteration. Returning 0 here
            // forever keeps the production loop's iterator-sentinel
            // gate the only thing that breaks the while-true — a
            // mutation that removes the gate would loop forever (which
            // the test runner observes as a hang, escalating to
            // ESCAPED-via-timeout in the cell's own bounded await).
            return 0
        }
    }

    /// Resets the iterator yield counter so the mock can be reused
    /// across multiple sequential production calls in one cell.
    func resetIteratorYields(_ count: Int = 1) {
        state.withLock { $0.iteratorYieldsRemaining = count }
    }

    func objectRelease(_ object: io_object_t) {
        // Mock owns no kernel object; release is a no-op.
    }

    func registrySetCFProperty(_ service: io_service_t, key: CFString, value: CFTypeRef) -> kern_return_t {
        state.withLock { s in
            s.registrySetPropertyCalls += 1
            if let kr = s.forceRegistrySetFailureKr { return kr }
            return KERN_SUCCESS
        }
    }

    func registryCreateCFProperty(_ service: io_service_t, key: CFString) -> CFTypeRef? {
        state.withLock { s in
            s.registryCreatePropertyCalls += 1
        }
        return nil
    }

    func hidManagerCreate() -> IOHIDManager {
        state.withLock { $0.hidManagerCreateCalls += 1 }
        return IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func hidManagerOpen(_ manager: IOHIDManager) -> IOReturn {
        state.withLock { s in
            s.hidManagerOpenCalls += 1
            if let kr = s.forceManagerOpenFailure {
                s.forceManagerOpenFailure = nil
                return kr
            }
            return kIOReturnSuccess
        }
    }

    func hidManagerClose(_ manager: IOHIDManager) {
        // Mock leaves the IOHIDManager open until ARC tears it down.
    }

    func hidManagerSetDeviceMatching(_ manager: IOHIDManager, matching: CFDictionary) {
        // No-op: cells either short-circuit before this point or rely on
        // the synthetic device returned by `hidManagerCopyDevices`.
    }

    func hidManagerCopyDevices(_ manager: IOHIDManager) -> CFSet? {
        let nilOut = state.withLock { $0.forceCopyDevicesNil }
        if nilOut { return nil }
        // Returns a CFSet containing one synthetic pointer. The pointer
        // is type-punned as `IOHIDDevice` by `findSPUDevice` and passed
        // to the mock's `hidDeviceTransport`, which never dereferences
        // it — so any non-null CF object is sufficient. We use a
        // CFNumber (retained / valid memory) so ARC bookkeeping stays
        // sound even though production never inspects the storage.
        let opaque = UnsafeRawPointer(Unmanaged.passUnretained(syntheticDevice).toOpaque())
        var values: [UnsafeRawPointer?] = [opaque]
        return values.withUnsafeMutableBufferPointer { buf in
            CFSetCreate(kCFAllocatorDefault, buf.baseAddress, 1, nil)
        }
    }

    func hidManagerScheduleWithRunLoop(_ manager: IOHIDManager, runLoop: CFRunLoop, mode: CFString) {}
    func hidManagerUnscheduleFromRunLoop(_ manager: IOHIDManager, runLoop: CFRunLoop, mode: CFString) {}

    func hidDeviceOpen(_ device: IOHIDDevice) -> IOReturn {
        state.withLock { s in
            s.hidDeviceOpenCalls += 1
            if let kr = s.forceDeviceOpenFailure {
                s.forceDeviceOpenFailure = nil
                return kr
            }
            return kIOReturnSuccess
        }
    }

    func hidDeviceClose(_ device: IOHIDDevice) {}

    func hidDeviceMaxReportSize(_ device: IOHIDDevice) -> Int {
        state.withLock { s in
            s.hidDeviceMaxReportSizeCalls += 1
            return s.forceMaxReportSizeZero ? 0 : 64
        }
    }

    func hidDeviceTransport(_ device: IOHIDDevice) -> String? {
        state.withLock { s in
            s.hidDeviceTransportCalls += 1
            return s.forceTransportMismatch ? "WRONG-TRANSPORT" : AccelHardwareConstants.requiredTransport
        }
    }

    func hidDeviceRegisterInputReportCallback(
        _ device: IOHIDDevice,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex,
        callback: IOHIDReportCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        // No-op: the mock does not host a run loop.
    }
}

// Synthetic IOKit handles. The values themselves are opaque —
// production never dereferences `io_object_t`, it only passes them back
// to the driver.
private let fakeIteratorHandle: io_iterator_t = 0xACCE_0001
private let fakeServiceHandle: io_service_t   = 0xACCE_0002

/// Long-lived CF object used as the type-punned `IOHIDDevice` payload
/// in the mock's `hidManagerCopyDevices` return value. `findSPUDevice`
/// reconstructs an `IOHIDDevice` from the CFSet's raw pointers and
/// passes that to `hidDeviceTransport`; the mock never dereferences the
/// pointer, so any retained CF object is safe.
private let syntheticDevice: CFNumber = 1 as CFNumber
