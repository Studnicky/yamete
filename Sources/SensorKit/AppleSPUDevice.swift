#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import IOKit.hid
import IOHIDPublic
import os

// MARK: - AppleSPUDevice — multi-subscriber broker for the SPU HID device
//
// The Apple SPU bus exposes a single HID device that hosts multiple
// usages: accelerometer, gyro, hinge-angle (lid), ambient-light, etc.
// IOKit's input-report callback is registered ONCE per `IOHIDDevice` and
// receives the entire report buffer on every read — the same callback
// fires for every emitted report regardless of which usage(s) the report
// carries data for. The byte layout puts each usage's fields at fixed
// offsets within the shared buffer; subscribers read their own offsets
// and ignore the rest.
//
// This means we cannot run multiple parallel `IOHIDManager` /
// `IOHIDDevice` opens — the kernel hands out exclusive open semantics
// per device, so only one client at a time can hold the device open.
// `AppleSPUDevice` solves the multi-source problem by being the SOLE
// owner of the open handle and fanning out each report to every
// registered subscriber.
//
// Fan-out model
// -------------
// • Subscribers register with `subscribe(usagePage:usage:dispatch:handler:)`.
//   The `usagePage` and `usage` parameters are stored as METADATA on the
//   subscription record (used for `_testActiveSubscriptionCount`
//   introspection and future per-usage filtering if Apple's wire format
//   ever needs it). They are NOT used to filter which handlers fire on
//   a given report.
// • Every active subscriber's handler runs on every report, with the
//   FULL raw byte buffer + length + capture timestamp. The handler
//   decodes its own bytes from its own offsets and is a no-op if the
//   data it cares about isn't present in this report.
// • The `dispatch` enum is used for diagnostic logging only in Phase 0.
//   Future phases may use it to pick the right service node when
//   activating a specific sensor (e.g., `dispatchGyro = Yes` for gyro
//   activation, mirroring `dispatchAccel = Yes` for accel).
//
// Refcount lifecycle
// ------------------
// • First `subscribe()` while refcount == 0: open IOHIDManager, find
//   the SPU device, open it, register the input-report callback,
//   schedule on a dedicated CFRunLoop thread, activate the sensor via
//   IORegistry property writes.
// • Each subsequent `subscribe()`: increment refcount, no IOKit work.
// • Each `unsubscribe()`: decrement refcount. If it reaches 0:
//   deactivate the sensor, unregister callback, close device, close
//   manager, tear down the run loop thread.
// • The device handle is opened and closed at most once per
//   refcount-zero transition. The kernel does not reference-count
//   IOHIDDevice opens for us; we do that bookkeeping ourselves.
//
// Concurrency
// -----------
// • `AppleSPUDevice` is `@unchecked Sendable`. All mutable state lives
//   behind an `OSAllocatedUnfairLock<State>`. The justification matches
//   the existing `FilterState` pattern (see `MicrophoneAdapter.swift`):
//   non-Sendable framework handles (IOHIDManager, IOHIDDevice, CFRunLoop,
//   UnsafeMutablePointer) are kept lock-protected and never escape
//   without serialization. The HID input-report callback runs on the
//   broker's worker thread — it acquires the lock, snapshots the
//   subscriber list, releases the lock, then invokes handlers. Handlers
//   that need to touch main-actor state marshal via `Task { @MainActor in ... }`
//   themselves, mirroring `EventSources.swift`.
// • `subscribe`, `unsubscribe`, and the static helpers are
//   `nonisolated`. The `shared` singleton is safe to call from any
//   actor.
//
// Test seam
// ---------
// • Production callers reach `AppleSPUDevice.shared`, which is built
//   with `RealSPUKernelDriver`. The singleton's IOKit traffic is
//   byte-identical to the pre-broker build for Direct production.
// • Tests construct an `AppleSPUDevice` instance directly via the
//   `internal init(driver:)` overload, injecting `MockSPUKernelDriver`
//   to make the broker's lifecycle gates reachable from XCTest. The
//   per-source test seam (each source's `kernelDriver:` parameter) is
//   unchanged — sources that subscribe through the broker continue to
//   accept their own driver injection for source-level tests that don't
//   need broker-level fan-out.

private let log = AppLog(category: "AppleSPUDevice")

// MARK: - Public API surfaces

/// Identifier for an active subscription. Returned by `subscribe(...)`,
/// passed to `unsubscribe(...)`. Opaque value type; equality is by
/// embedded UUID.
public struct SPUSubscription: Sendable, Hashable {
    fileprivate let id: UUID
    fileprivate init() { self.id = UUID() }
}

/// Coarse-grained dispatch label for diagnostic logging in the broker.
/// Future phases may also use this to pick the right service node when
/// activating a specific sensor branch (e.g. `dispatchGyro = Yes`).
public enum SPUDispatchKey: String, Sendable, Hashable {
    case accel
    case gyro
    case lid
    case als
}

/// Snapshot of one HID input report delivered by the broker to every
/// active subscriber. The handler MUST consume `bytes` synchronously
/// (within the handler call); the pointer is invalidated when the
/// callback returns.
///
/// `@unchecked Sendable` is sound because the broker calls every
/// handler in sequence on the same worker thread, and the handler
/// contract forbids retaining the buffer past the call.
public struct SPUReport: @unchecked Sendable {
    public let bytes: UnsafePointer<UInt8>
    public let length: Int
    public let timestamp: Date
}

// MARK: - Subscription record

private struct SubscriberRecord: Sendable {
    let id: UUID
    let usagePage: Int
    let usage: Int
    let dispatch: SPUDispatchKey
    let handler: @Sendable (SPUReport) -> Void
}

// MARK: - Open device handles

/// Framework-handle bundle for the open SPU device. Mirrors the existing
/// `IOKitHandles` pattern in `AccelerometerReader.swift` — every field is
/// a non-Sendable framework type kept inside a narrow `@unchecked Sendable`
/// boundary. Access is serialized by the broker's outer state lock.
private struct OpenDevice: @unchecked Sendable {
    let manager: IOHIDManager
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int
    let runLoop: CFRunLoop
    let runLoopMode: CFRunLoopMode
    let thread: HIDRunLoopThread
    /// Retained pointer to the broker self, used as the C-callback
    /// context. Released on close.
    let contextPtr: UnsafeMutableRawPointer
}

// MARK: - HID run loop thread (broker-owned variant)

/// Dedicated CFRunLoop-hosting thread for the broker's IOHIDManager.
/// Mirrors the existing `HIDRunLoopThread` in `AccelerometerReader.swift`
/// (private file scope there); duplicated here to keep the broker
/// self-contained and avoid widening the existing type's visibility.
private struct HIDRunLoopThread: Sendable {
    private struct State: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var thread: Thread?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let ready = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)

    var runLoop: CFRunLoop? { state.withLock { $0.runLoop } }

    init() { state = OSAllocatedUnfairLock(initialState: State()) }

    func start() {
        let stateRef = state
        let readyRef = ready
        let doneRef = done
        let thread = Thread {
            stateRef.withLock { $0.runLoop = CFRunLoopGetCurrent() }
            readyRef.signal()
            var cancelled = false
            while !cancelled {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false)
                cancelled = stateRef.withLock { $0.thread?.isCancelled ?? true }
            }
            doneRef.signal()
        }
        state.withLockUnchecked { $0.thread = thread }
        thread.start()
    }

    func waitUntilReady() { ready.wait() }

    func cancel() {
        state.withLock { s in
            s.thread?.cancel()
            if let rl = s.runLoop { CFRunLoopStop(rl) }
        }
    }

    func join() { done.wait() }
}

// MARK: - The broker

public final class AppleSPUDevice: @unchecked Sendable {

    /// Production singleton. Always constructed with `RealSPUKernelDriver`.
    /// Tests construct their own instance via the `internal init(driver:)`
    /// overload to inject a mock.
    public static let shared = AppleSPUDevice(driver: RealSPUKernelDriver())

    private struct State {
        var subscribers: [UUID: SubscriberRecord] = [:]
        var openDevice: OpenDevice?
        /// Refcount. Always equals `subscribers.count` in steady state;
        /// tracked separately so the open/close transitions are
        /// expressed as monotonic increments/decrements without
        /// recomputing the dictionary count under the lock.
        var refCount: Int = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let driver: SPUKernelDriver

    /// Designated initializer accepting a kernel-driver injection. Tests
    /// use this to inject `MockSPUKernelDriver`. Production callers reach
    /// the singleton via `AppleSPUDevice.shared`.
    internal init(driver: SPUKernelDriver) {
        self.driver = driver
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - Public API

    /// True when the SPU HID device is present in the IORegistry. Read
    /// only — does not open the device. Default driver is the production
    /// one; tests inject a mock.
    public static func isHardwarePresent(driver: SPUKernelDriver = RealSPUKernelDriver()) -> Bool {
        AccelHardware.isSPUDevicePresent(driver: driver)
    }

    /// Subscribe to SPU HID reports. On the first subscription the broker
    /// opens the device and activates the sensor; every subsequent
    /// subscribe increments the refcount only.
    ///
    /// The `usagePage` and `usage` arguments are stored on the
    /// subscription record for diagnostic introspection but are NOT used
    /// to filter which handlers receive which reports. See the file
    /// header for the fan-out rationale.
    ///
    /// Returns nil when the SPU device cannot be opened (hardware
    /// absent, manager-open denied, device-open denied, etc.). Existing
    /// subscriptions stay valid; the broker's refcount is unchanged.
    public func subscribe(
        usagePage: Int,
        usage: Int,
        dispatch: SPUDispatchKey,
        reportIntervalUS: Int = 10000,
        handler: @escaping @Sendable (SPUReport) -> Void
    ) -> SPUSubscription? {
        let token = SPUSubscription()
        let record = SubscriberRecord(
            id: token.id,
            usagePage: usagePage,
            usage: usage,
            dispatch: dispatch,
            handler: handler
        )

        // Decide under the lock whether this subscribe is the
        // refcount-zero opener, then either open the device (releasing
        // the lock around the IOKit calls) and re-acquire to publish,
        // or simply append the record.
        let needsOpen: Bool = state.withLock { s in
            if s.openDevice == nil {
                return true
            }
            s.subscribers[record.id] = record
            s.refCount += 1
            return false
        }
        if !needsOpen {
            log.info("activity:Subscribe wasGeneratedBy entity:AppleSPUDevice dispatch=\(dispatch.rawValue) refCount=\(currentRefCount())")
            return token
        }

        // Refcount-zero path. Open outside the state lock — IOKit calls
        // can block briefly; we don't want to serialize unrelated
        // subscribers behind that.
        guard let opened = openSPUDevice(reportIntervalUS: reportIntervalUS) else {
            log.warning("entity:AppleSPUDevice wasInvalidatedBy activity:OpenDevice dispatch=\(dispatch.rawValue)")
            return nil
        }

        let installed: Bool = state.withLock { s in
            // Race: a concurrent subscriber may have already opened the
            // device between our `needsOpen=true` decision and arriving
            // here. If so, drop our open and use the winner's.
            if s.openDevice != nil {
                return false
            }
            s.openDevice = opened
            s.subscribers[record.id] = record
            s.refCount += 1
            return true
        }

        if !installed {
            // Lost the open race; tear our open down before returning.
            closeSPUDevice(opened)
            // Retry as a non-opener; the winner's open is now live.
            state.withLock { s in
                s.subscribers[record.id] = record
                s.refCount += 1
            }
        }

        log.info("activity:Subscribe wasGeneratedBy entity:AppleSPUDevice dispatch=\(dispatch.rawValue) refCount=\(currentRefCount()) wasOpener=\(installed)")
        return token
    }

    /// Unsubscribe. On the last unsubscribe the broker closes the device
    /// and deactivates the sensor. Idempotent — unsubscribing an already-
    /// removed token is a no-op.
    public func unsubscribe(_ token: SPUSubscription) {
        let toClose: OpenDevice? = state.withLock { s in
            guard s.subscribers.removeValue(forKey: token.id) != nil else {
                return nil
            }
            s.refCount -= 1
            if s.refCount == 0, let d = s.openDevice {
                s.openDevice = nil
                return d
            }
            return nil
        }
        if let d = toClose {
            closeSPUDevice(d)
            log.info("activity:Unsubscribe wasGeneratedBy entity:AppleSPUDevice wasCloser=true")
        } else {
            log.info("activity:Unsubscribe wasGeneratedBy entity:AppleSPUDevice wasCloser=false refCount=\(currentRefCount())")
        }
    }

    /// Test introspection — number of currently active subscriptions.
    /// Used by `Tests/AppleSPUDevice_Tests.swift` to assert refcount
    /// transitions.
    public func _testActiveSubscriptionCount() -> Int {
        state.withLock { $0.subscribers.count }
    }

    /// Test introspection — whether the underlying device is currently
    /// open. Distinct from `_testActiveSubscriptionCount` because in the
    /// failed-open path the subscription would not be installed (returns
    /// nil) but the test wants to verify the device handle was released.
    public func _testIsDeviceOpen() -> Bool {
        state.withLock { $0.openDevice != nil }
    }

    private func currentRefCount() -> Int {
        state.withLock { $0.refCount }
    }

    // MARK: - Device open / close

    private func openSPUDevice(reportIntervalUS: Int) -> OpenDevice? {
        let manager = driver.hidManagerCreate()
        guard driver.hidManagerOpen(manager) == kIOReturnSuccess else {
            return nil
        }

        driver.hidManagerSetDeviceMatching(manager, matching: AccelHardware.matchingDict)

        guard let devices = driver.hidManagerCopyDevices(manager),
              let device = AccelHardware.findSPUDevice(in: devices, driver: driver) else {
            driver.hidManagerClose(manager)
            return nil
        }

        guard driver.hidDeviceOpen(device) == kIOReturnSuccess else {
            driver.hidManagerClose(manager)
            return nil
        }

        let maxSize = driver.hidDeviceMaxReportSize(device)
        guard maxSize > 0 else {
            driver.hidDeviceClose(device)
            driver.hidManagerClose(manager)
            return nil
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        buffer.initialize(repeating: 0, count: maxSize)

        // Best-effort sensor activation. In sandboxed builds this is
        // kernel-rejected and reports only flow when something else has
        // warmed the sensor; we let the watchdog (per-subscriber) deal
        // with that case.
        _ = SensorActivation.activate(reportIntervalUS: reportIntervalUS, driver: driver)

        // Retain self for the C-callback context. Released in
        // `closeSPUDevice` along with the unregister.
        let contextPtr = Unmanaged.passRetained(self).toOpaque()
        driver.hidDeviceRegisterInputReportCallback(
            device,
            report: buffer,
            reportLength: maxSize,
            callback: { context, _, _, _, _, report, reportLength in
                guard let context else { return }
                let broker = Unmanaged<AppleSPUDevice>.fromOpaque(context).takeUnretainedValue()
                broker.dispatchReport(bytes: report, length: reportLength)
            },
            context: contextPtr
        )

        let thread = HIDRunLoopThread()
        thread.start()
        thread.waitUntilReady()
        guard let runLoop = thread.runLoop, let rlMode = CFRunLoopMode.defaultMode else {
            driver.hidDeviceRegisterInputReportCallback(
                device, report: buffer, reportLength: maxSize, callback: nil, context: nil
            )
            Unmanaged<AppleSPUDevice>.fromOpaque(contextPtr).release()
            buffer.deallocate()
            driver.hidDeviceClose(device)
            driver.hidManagerClose(manager)
            return nil
        }
        driver.hidManagerScheduleWithRunLoop(manager, runLoop: runLoop, mode: rlMode.rawValue)

        log.info("entity:AppleSPUDevice wasGeneratedBy activity:OpenDevice maxSize=\(maxSize)")

        return OpenDevice(
            manager: manager,
            device: device,
            buffer: buffer,
            bufferSize: maxSize,
            runLoop: runLoop,
            runLoopMode: rlMode,
            thread: thread,
            contextPtr: contextPtr
        )
    }

    private func closeSPUDevice(_ d: OpenDevice) {
        // Phase 1 — stop the run loop thread before mutating any CF state.
        // Mirrors the existing teardown contract in
        // `AccelHardware.openStream` (see ordering doc there for why
        // join() must precede CF mutation; CF_IS_OBJC SEGV otherwise).
        d.thread.cancel()
        CFRunLoopStop(d.runLoop)
        d.thread.join()

        // Phase 2 — best-effort deactivate. Sandboxed builds will see
        // KERN_FAILURE / kIOReturnNotPermitted; that's expected and
        // benign because the sensor is shared with macOS.
        SensorActivation.deactivate(driver: driver)

        // Phase 3 — unregister callback + close handles.
        driver.hidDeviceRegisterInputReportCallback(
            d.device, report: d.buffer, reportLength: d.bufferSize, callback: nil, context: nil
        )
        driver.hidManagerUnscheduleFromRunLoop(d.manager, runLoop: d.runLoop, mode: d.runLoopMode.rawValue)
        driver.hidDeviceClose(d.device)
        driver.hidManagerClose(d.manager)
        d.buffer.deallocate()
        Unmanaged<AppleSPUDevice>.fromOpaque(d.contextPtr).release()

        log.info("entity:AppleSPUDevice wasInvalidatedBy activity:CloseDevice")
    }

    // MARK: - Report dispatch

    /// Called from the C callback on the broker's HID worker thread.
    /// Snapshots the subscriber list under the lock, then invokes every
    /// handler with the same `SPUReport`. Handlers must consume the
    /// pointer synchronously.
    fileprivate func dispatchReport(bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        let now = Date()
        let snapshot: [SubscriberRecord] = state.withLock { Array($0.subscribers.values) }
        let report = SPUReport(bytes: UnsafePointer(bytes), length: length, timestamp: now)
        for sub in snapshot {
            sub.handler(report)
        }
    }

    /// Test seam — synthesize an input report to all current subscribers
    /// without involving real IOKit. Used by `AppleSPUDevice_Tests` to
    /// validate fan-out behaviour with a mock driver where no real
    /// hardware emits reports.
    internal func _testInjectReport(bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        dispatchReport(bytes: bytes, length: length)
    }
}
