#if canImport(YameteCore)
import YameteCore
#endif
@preconcurrency import Foundation
import IOKit.hid
import IOHIDPublic
import os

// MARK: - BMI286 Accelerometer Adapter
//
// Reads the BMI286 accelerometer on Apple Silicon Macs via IOKit.
// Runs its own detection pipeline (bandpass → ImpactDetector) and emits
// SensorImpact events with 0–1 intensity.
//
// The sensor appears as a vendor-defined HID device:
//   PrimaryUsagePage = 0xFF00, PrimaryUsage = 3, Transport = "SPU"
//
// Two-phase access pattern (works in both Direct and App Store builds):
//
//   Phase 1 — best-effort activation (Direct builds only)
//     IORegistryEntrySetCFProperty on AppleSPUHIDDriver writing
//     ReportInterval, SensorPropertyReportingState, SensorPropertyPowerState.
//     Direct (unsandboxed) builds: succeeds, ensures the sensor is active
//     at our preferred report interval.
//     App Store (sandboxed) builds: returns kIOReturnNotPermitted because
//     the sandbox blocks IORegistry property writes regardless of which
//     entitlements are granted (no entitlement covers this surface).
//     We log info-level fall-through and continue to phase 2.
//
//   Phase 2 — passive HID subscription (both builds)
//     IOHIDManagerCreate + IOHIDDeviceRegisterInputReportCallback against
//     the SPU device. Receives whatever HID reports the kernel is already
//     producing. The macOS system maintains a baseline reporting state on
//     the SPU services via HIDEventServiceProperties.ReportInterval (set
//     by WindowServer / locationd at boot for orientation, lid sensing,
//     and CoreLocation), so even when phase 1 is blocked the sensor is
//     already streaming at 100Hz and our subscription receives the data.
//
// All IOKit functions called are declared in public SDK headers
// (IOKit/IOKitLib.h, IOKit/hid/IOHIDManager.h, IOKit/hid/IOHIDDevice.h).
// No private API symbols are imported. The driver class name and property
// keys used in phase 1 are Apple-internal implementation details; phase 2
// uses no internal property surface.
//
// Reliability caveats for the App Store path:
//   • This relies on the system having the SPU sensor warm. If a future
//     macOS revision changes WindowServer/locationd behavior to defer
//     activation, the App Store build's accelerometer will go silent.
//     The Direct build is unaffected (it does its own activation).
//   • Sleep/wake and cold-boot behavior should be retested before each
//     App Store release.
//   • If reports stop arriving in production, the controller already
//     supports microphone + headphone-motion fallback via the existing
//     consensus path.
//
// App Sandbox: Requires com.apple.security.device.usb entitlement (allows
// IOHIDManager device matching/open). No additional entitlements needed.

private let log = AppLog(category: "Accelerometer")

// MARK: - Shared constants

private let pageAccel = AccelHardwareConstants.hidUsagePage
private let usageAccel = AccelHardwareConstants.hidUsage
private let requiredTransport = AccelHardwareConstants.requiredTransport
private let decimationFactor = AccelHardwareConstants.decimationFactor
private let magnitudeMin = AccelHardwareConstants.magnitudeMin
private let magnitudeMax = AccelHardwareConstants.magnitudeMax
private let minReportLength = AccelHardwareConstants.minReportLength
private let rawScale = AccelHardwareConstants.rawScale


// MARK: - Accelerometer Adapter

/// Reads BMI286 accelerometer via IOKit public APIs and streams impact events.
///
/// Activation: IORegistryEntrySetCFProperty on AppleSPUHIDDriver (public function, undocumented driver keys)
/// Reading: IOHIDManager → IOHIDDeviceRegisterInputReportCallback → bandpass → ImpactDetector
public final class SPUAccelerometerAdapter: SensorAdapter, Sendable {

    public let id = SensorID.accelerometer
    public let name = "Accelerometer"
    public let reportIntervalUS: Int
    public let detectorConfig: ImpactDetectorConfig
    public let bandpassLowHz: Float
    public let bandpassHighHz: Float

    public init(reportIntervalUS: Int = 10000,
                bandpassLowHz: Float = 20.0, bandpassHighHz: Float = 25.0,
                detectorConfig: ImpactDetectorConfig = .accelerometer()) {
        self.reportIntervalUS = reportIntervalUS
        self.bandpassLowHz = bandpassLowHz
        self.bandpassHighHz = bandpassHighHz
        self.detectorConfig = detectorConfig
    }

    /// True when an SPU HID device is physically present. We no longer gate
    /// on activation permission: even when sandbox blocks our IORegistry
    /// writes (App Store build), the system itself keeps the SPU sensor
    /// warm (HIDEventServiceProperties.ReportInterval is set by WindowServer
    /// and locationd) and reports flow passively through IOHIDManager. The
    /// adapter tries to activate first but falls through to a passive open
    /// if activation is denied.
    public var isAvailable: Bool {
        AccelHardware.isSPUDevicePresent()
    }

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let intervalUS = reportIntervalUS

        // Best-effort activation. In Direct (unsandboxed) builds this writes
        // ReportInterval / SensorPropertyReportingState / SensorPropertyPowerState
        // on AppleSPUHIDDriver and returns true. In App Store (sandboxed)
        // builds it returns false because IORegistryEntrySetCFProperty
        // returns kIOReturnNotPermitted — but the system has HID
        // EventServiceProperties.ReportInterval already set, so reports
        // continue to flow through IOHIDManager regardless.
        let activated = SensorActivation.activate(reportIntervalUS: intervalUS)
        if !activated {
            log.info("activity:SensorActivation isPendingOn entity:SystemActivation falling through to passive read")
        }

        return AccelHardware.openStream(
            adapterID: id, adapterName: name,
            reportIntervalUS: intervalUS,
            bandpassLowHz: bandpassLowHz, bandpassHighHz: bandpassHighHz,
            detectorConfig: detectorConfig
        )
    }
}

// MARK: - Sensor activation via IORegistry
//
// Uses public IOKit functions with undocumented Apple-internal driver
// property keys. See file-level comment for rationale.

private enum SensorActivation {
    static func activate(reportIntervalUS: Int) -> Bool {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        var activated = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let r1 = IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, reportIntervalUS as CFNumber)
            let r2 = IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            let r3 = IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)

            if r1 == KERN_SUCCESS && r2 == KERN_SUCCESS && r3 == KERN_SUCCESS {
                activated = true
            }
            // Failures are expected and benign in sandboxed builds where
            // IORegistryEntrySetCFProperty returns kIOReturnNotPermitted.
            // The system maintains HIDEventServiceProperties.ReportInterval
            // independently (set by WindowServer + locationd), so reports
            // continue to flow through IOHIDManager regardless. The caller
            // logs the fall-through once at info level.
        }
        return activated
    }

    static func deactivate() {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 0 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 0 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 0 as CFNumber)
        }
    }
}

// MARK: - Shared hardware access

private enum AccelHardware {

    static func isSPUDevicePresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matchingDict)
        guard let devices = IOHIDManagerCopyDevices(manager) else { return false }
        return findSPUDevice(in: devices) != nil
    }

    static func openStream(
        adapterID: SensorID,
        adapterName: String,
        reportIntervalUS: Int = 10000,
        bandpassLowHz: Float = 20.0,
        bandpassHighHz: Float = 25.0,
        detectorConfig: ImpactDetectorConfig
    ) -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            let msg = String(format: "0x%08x", openResult)
            log.warning("activity:SensorReading failed IOHIDManagerOpen status=\(msg)")
            continuation.finish(throwing: SensorError.ioKitError(msg))
            return stream
        }

        IOHIDManagerSetDeviceMatching(manager, matchingDict)

        guard let devices = IOHIDManagerCopyDevices(manager),
              let device = findSPUDevice(in: devices) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        let devOpenResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard devOpenResult == kIOReturnSuccess else {
            let msg = String(format: "0x%08x", devOpenResult)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            continuation.finish(throwing: SensorError.ioKitError(msg))
            return stream
        }

        log.info("entity:AccelDevice wasAssociatedWith agent:\(adapterName)")

        let maxSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        buffer.initialize(repeating: 0, count: maxSize)

        let ctx = ReportContext(
            adapterID: adapterID,
            continuation: continuation,
            hpFilter: HighPassFilter(cutoffHz: bandpassLowHz, sampleRate: AccelHardwareConstants.defaultSampleRate),
            lpFilter: LowPassFilter(cutoffHz: bandpassHighHz, sampleRate: AccelHardwareConstants.defaultSampleRate),
            detector: ImpactDetector(config: detectorConfig, adapterName: adapterName)
        )
        let ctxPtr = Unmanaged.passRetained(ctx)

        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, maxSize,
            { context, result, sender, type, reportID, report, reportLength in
                guard let context else { return }
                let ctx = Unmanaged<ReportContext>.fromOpaque(context).takeUnretainedValue()
                ctx.handleReport(report: report, length: reportLength)
            },
            ctxPtr.toOpaque()
        )

        let thread = HIDRunLoopThread()
        thread.start()
        thread.waitUntilReady()
        guard let runLoop = thread.runLoop, let rlMode = CFRunLoopMode.defaultMode else {
            buffer.deallocate()
            ctxPtr.release()
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            continuation.finish(throwing: SensorError.ioKitError("HID thread run loop unavailable"))
            return stream
        }
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, rlMode.rawValue)

        log.info("activity:SensorReading wasStartedBy agent:\(adapterName)")

        // Watchdog: monitors the report stream for stalls. Critical for the
        // App Store sandbox path because activation writes are denied — the
        // sensor only delivers data when macOS happens to keep it warm via
        // HIDEventServiceProperties. If the system goes cold (after sleep,
        // a daemon restart, or an OS revision regression), reports stop
        // arriving and we surface a stall error so the controller can fall
        // back to microphone + headphone-motion via its existing fusion path.
        let watchdogTask = Task.detached(priority: .background) { [ctx] in
            // Allow up to 5s for the first sample to arrive after subscription
            // start, then 5s between samples thereafter. The Direct build
            // typically sees the first sample within ~10ms; 5s is a generous
            // grace period for the worst case.
            let stallThreshold: TimeInterval = 5.0
            let pollInterval: TimeInterval = 1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                let snapshot = ctx.watchdogSnapshot()
                guard snapshot.running else { return }
                let staleness = Date().timeIntervalSince(snapshot.lastReportAt)
                if staleness > stallThreshold {
                    log.warning("activity:SensorReading wasInvalidatedBy entity:Watchdog staleness=\(String(format: "%.1f", staleness))s sampleCount=\(snapshot.sampleCounter)")
                    ctx.surfaceStall(SensorError.ioKitError("accelerometer report stream stalled (\(Int(staleness))s without data)"))
                    return
                }
            }
        }

        let cleanup = OnceCleanup(AccelResources(
            manager: manager, device: device, buffer: buffer,
            maxSize: maxSize, runLoop: runLoop, runLoopMode: rlMode,
            thread: thread, ctxPtr: ctxPtr, ctx: ctx,
            watchdog: WatchdogHandle(task: watchdogTask),
        ))

        continuation.onTermination = { @Sendable _ in
            cleanup.perform { r in
                // Phase 0 — cancel the watchdog so it stops polling and
                // never tries to surfaceStall on a torn-down context.
                r.watchdog.task.cancel()

                // Phase 1 — silence the report callback. From this point on,
                // any in-flight HID callback that fires before the run loop
                // exits is a no-op (running == false).
                r.ctx.invalidate()
                SensorActivation.deactivate()

                // Phase 2 — stop the dedicated HID thread and WAIT for it
                // to exit. CFRunLoopStop is documented thread-safe; the
                // thread.cancel + join pair ensures the worker is no longer
                // inside CFRunLoopRunInMode before we touch any CF objects
                // it had scheduled. Without the join, the next phase races
                // CF data-structure modification (TSAN reports SEGV in
                // CF_IS_OBJC during a worker-thread CF dispatch).
                r.thread.cancel()
                CFRunLoopStop(r.runLoop)
                r.thread.join()

                // Phase 3 — now safe to mutate IOHIDManager state and
                // close the device. The HID worker is fully exited.
                IOHIDDeviceRegisterInputReportCallback(r.device, r.buffer, r.maxSize, nil, nil)
                IOHIDManagerUnscheduleFromRunLoop(r.manager, r.runLoop, r.runLoopMode.rawValue)
                IOHIDDeviceClose(r.device, IOOptionBits(kIOHIDOptionsTypeNone))
                IOHIDManagerClose(r.manager, IOOptionBits(kIOHIDOptionsTypeNone))
                r.buffer.deallocate()
                r.ctxPtr.release()
            }
            log.info("activity:SensorReading wasEndedBy agent:\(adapterName)")
        }

        return stream
    }

    static var matchingDict: CFDictionary {
        [kIOHIDPrimaryUsagePageKey as String: pageAccel, kIOHIDPrimaryUsageKey as String: usageAccel] as CFDictionary
    }

    static func findSPUDevice(in devices: CFSet) -> IOHIDDevice? {
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)
        for v in values {
            guard let v else { continue }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(v).takeUnretainedValue()
            if IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String == requiredTransport {
                return device
            }
        }
        return nil
    }
}

// MARK: - Accelerometer resource bundle (consumed by OnceCleanup on stream teardown)

private struct AccelResources: @unchecked Sendable {
    let manager: IOHIDManager
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let maxSize: Int
    let runLoop: CFRunLoop
    let runLoopMode: CFRunLoopMode
    let thread: HIDRunLoopThread
    let ctxPtr: Unmanaged<ReportContext>
    let ctx: ReportContext
    let watchdog: WatchdogHandle
}

/// Sendable wrapper around the watchdog Task so AccelResources can satisfy
/// `OnceCleanup<T: Sendable>`. The task is `Task<Void, Never>` which is
/// already Sendable; this struct exists for symmetry with the other handles.
private struct WatchdogHandle: Sendable {
    let task: Task<Void, Never>
}

// MARK: - Report decode + detection context

/// Decodes HID reports, applies bandpass filtering, and runs ImpactDetector.
/// All mutable and non-Sendable state is lock-protected.
private final class ReportContext: Sendable {
    let adapterID: SensorID

    private struct State: @unchecked Sendable {
        var running = true
        var sampleCounter = 0
        /// Wall-clock time of the most recent successful report. The watchdog
        /// reads this to detect stalled HID streams (e.g., system stopped
        /// keeping the SPU sensor warm in the App Store sandbox after sleep).
        var lastReportAt: Date = Date()
        let continuation: AsyncThrowingStream<SensorImpact, Error>.Continuation
        let hpFilter: HighPassFilter
        let lpFilter: LowPassFilter
        let detector: ImpactDetector
    }
    private let state: OSAllocatedUnfairLock<State>

    init(adapterID: SensorID,
         continuation: AsyncThrowingStream<SensorImpact, Error>.Continuation,
         hpFilter: HighPassFilter, lpFilter: LowPassFilter,
         detector: ImpactDetector) {
        self.adapterID = adapterID
        self.state = OSAllocatedUnfairLock(initialState: State(
            continuation: continuation, hpFilter: hpFilter,
            lpFilter: lpFilter, detector: detector))
    }

    func invalidate() { state.withLock { $0.running = false } }

    /// Snapshot of (running, lastReportAt, sampleCounter) for the watchdog.
    /// Returns nil for lastReportAt if the stream has already been invalidated.
    func watchdogSnapshot() -> (running: Bool, lastReportAt: Date, sampleCounter: Int) {
        state.withLock { ($0.running, $0.lastReportAt, $0.sampleCounter) }
    }

    /// Surfaces a recoverable error to the consuming AsyncThrowingStream.
    /// Used by the watchdog when no reports arrive for the stall threshold.
    /// Marks the context invalid first so any in-flight callback no-ops.
    func surfaceStall(_ error: Error) {
        state.withLock { s in
            guard s.running else { return }
            s.running = false
            s.continuation.finish(throwing: error)
        }
    }

    func handleReport(report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length >= minReportLength else { return }

        // Int32 axes at byte offsets 6/10/14 are NOT 4-byte aligned. Using
        // `withMemoryRebound` on a misaligned pointer is undefined behavior
        // per the Swift memory model, even if it happens to work on Apple
        // Silicon. `loadUnaligned` is the sanctioned API for this case.
        let rawBuffer = UnsafeRawPointer(report)
        let rawX = rawBuffer.loadUnaligned(fromByteOffset: 6, as: Int32.self)
        let rawY = rawBuffer.loadUnaligned(fromByteOffset: 10, as: Int32.self)
        let rawZ = rawBuffer.loadUnaligned(fromByteOffset: 14, as: Int32.self)

        state.withLock { s in
            guard s.running else { return }
            // Watchdog timestamp — bumped on every accepted report so the
            // stall detector can tell live from frozen.
            s.lastReportAt = Date()
            // Diagnostic: log first sample, then every 1000 samples
            // thereafter. 100Hz = 1000 samples per 10 seconds; sustained
            // logging proves the passive HID subscription works long-term,
            // not just for an initial burst.
            if s.sampleCounter == 0 {
                log.info("activity:SensorReading wasGeneratedBy entity:FirstReport adapter=\(self.adapterID) length=\(length)")
            } else if s.sampleCounter % 1000 == 0 {
                log.info("activity:SensorReading wasGeneratedBy entity:Report adapter=\(self.adapterID) sampleCount=\(s.sampleCounter)")
            }
            s.sampleCounter += 1
            guard s.sampleCounter % decimationFactor == 0 else { return }

            let raw = Vec3(x: Float(rawX) / rawScale, y: Float(rawY) / rawScale, z: Float(rawZ) / rawScale)
            let rawMag = raw.magnitude
            guard rawMag > magnitudeMin && rawMag < magnitudeMax else { return }

            let filtered = s.lpFilter.process(s.hpFilter.process(raw))
            let filteredMag = filtered.magnitude

            let now = Date()
            if let intensity = s.detector.process(magnitude: filteredMag, timestamp: now) {
                s.continuation.yield(SensorImpact(source: self.adapterID, timestamp: now, intensity: intensity))
            }
        }
    }
}

// MARK: - HID run loop thread

/// Manages a dedicated thread hosting a CFRunLoop for HID report callbacks.
/// Lock-protected state; the underlying Thread is not exposed.
///
/// Lifecycle: `start()` → `waitUntilReady()` → use → `cancel()` → `join()`.
/// `join()` MUST be called before tearing down any CF objects scheduled on
/// the run loop (e.g. `IOHIDManagerUnscheduleFromRunLoop`, `IOHIDManagerClose`).
/// Calling those from outside the HID thread while the HID thread is still
/// inside `CFRunLoopRunInMode` modifies CF data structures concurrently and
/// causes SEGV in `CF_IS_OBJC` (caught by ThreadSanitizer).
private struct HIDRunLoopThread: Sendable {
    private struct State: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var thread: Thread?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let ready = DispatchSemaphore(value: 0)
    /// Signaled by the worker thread when its run loop has exited.
    /// `join()` waits on this; cleanup must wait before touching CF objects.
    private let done = DispatchSemaphore(value: 0)

    var runLoop: CFRunLoop? { state.withLock { $0.runLoop } }

    init() {
        state = OSAllocatedUnfairLock(initialState: State())
    }

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

    /// Blocks the calling thread until the HID worker has fully exited its
    /// run loop. Combined with `cancel()` first, guarantees no CF callbacks
    /// or run-loop state changes can race teardown of the IOHIDManager.
    func join() { done.wait() }
}
