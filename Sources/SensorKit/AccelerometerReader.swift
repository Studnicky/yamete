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
// Access model:
//
//   Activation — IORegistryEntrySetCFProperty on AppleSPUHIDDriver writing
//     ReportInterval, SensorPropertyReportingState, SensorPropertyPowerState.
//     Unsandboxed clients (Direct build, external sensor-kickstart helper): the
//     writes reach the driver and start the BMI286 streaming at the
//     requested rate. Note the driver treats these properties as *command*
//     channels — read-back always returns 0 regardless of success, so
//     don't use property read-back as confirmation.
//     Sandboxed clients (App Store build): writes return KERN_SUCCESS
//     via `IORegistryEntrySetCFProperty` but the kernel silently drops
//     them before they reach the driver's `setProperty`, so the sensor
//     is never started by our code.
//
//   Passive HID subscription — IOHIDManagerCreate +
//     IOHIDDeviceRegisterInputReportCallback against the SPU device. Once
//     *something* has warmed the sensor (our own activation in the Direct
//     build, an external helper shipping via support docs for App Store
//     users, or macOS itself via WindowServer / locationd when it
//     subscribes for lid / orientation reasons), the subscription
//     receives the live 100Hz stream regardless of who did the warming.
//
//   Runtime availability probe — `isSensorActivelyReporting()` reads
//     `DebugState._last_event_timestamp` from the driver service and
//     compares against `mach_absolute_time()`. If the delta exceeds
//     500ms the sensor is considered cold and the adapter's `isAvailable`
//     returns false, so `Migration.reconcileSensors` prunes the adapter
//     before pipeline start rather than letting the stream watchdog fire
//     on an empty subscription mid-session.
//
// All IOKit functions called are declared in public SDK headers
// (IOKit/IOKitLib.h, IOKit/hid/IOHIDManager.h, IOKit/hid/IOHIDDevice.h).
// No private API symbols are imported. The driver class name and property
// keys are Apple-internal implementation details used only via the public
// `IOServiceMatching` / `IORegistryEntry*` surface.
//
// App Sandbox: Requires com.apple.security.device.usb entitlement (allows
// IOHIDManager device matching/open). IORegistry reads (the availability
// probe) work from inside sandbox without any additional entitlement.
// IORegistry writes (the activation attempt) are silently rejected, which
// is why the App Store build depends on an external warm-up path.

private let log = AppLog(category: "Accelerometer")

// MARK: - Kernel driver seam
//
// Wraps every IOKit call that AccelerometerReader makes so that fidelity
// gates around `KERN_SUCCESS`, `kIOReturnSuccess`, iterator sentinels and
// `maxSize > 0` are reachable from XCTest.
//
// `RealAccelerometerKernelDriver` is the default and forwards 1:1 to the
// kernel — production behaviour through `AccelerometerSource()` is
// unchanged. `MockAccelerometerKernelDriver` (under Tests/Mocks) lets
// cells force per-call failure codes and short-circuit iterators so the
// success-only branches become observable.
//
// The protocol is `Sendable` because all method results are scalar values
// or framework handles (`IOHIDManager`, `IOHIDDevice`) whose lifecycle
// the surrounding `AccelHardware.openStream` already manages — the
// driver itself holds no mutable state in the production path. The mock
// uses a lock-protected state struct.
public protocol AccelerometerKernelDriver: Sendable {
    // Mach / IOService surface
    func getMatchingServices(matching: CFDictionary?) -> (kr: kern_return_t, iterator: io_iterator_t)
    func iteratorNext(_ iterator: io_iterator_t) -> io_service_t
    func objectRelease(_ object: io_object_t)
    func registrySetCFProperty(_ service: io_service_t, key: CFString, value: CFTypeRef) -> kern_return_t
    func registryCreateCFProperty(_ service: io_service_t, key: CFString) -> CFTypeRef?

    // IOHIDManager surface
    func hidManagerCreate() -> IOHIDManager
    func hidManagerOpen(_ manager: IOHIDManager) -> IOReturn
    func hidManagerClose(_ manager: IOHIDManager)
    func hidManagerSetDeviceMatching(_ manager: IOHIDManager, matching: CFDictionary)
    func hidManagerCopyDevices(_ manager: IOHIDManager) -> CFSet?
    func hidManagerScheduleWithRunLoop(_ manager: IOHIDManager, runLoop: CFRunLoop, mode: CFString)
    func hidManagerUnscheduleFromRunLoop(_ manager: IOHIDManager, runLoop: CFRunLoop, mode: CFString)

    // IOHIDDevice surface
    func hidDeviceOpen(_ device: IOHIDDevice) -> IOReturn
    func hidDeviceClose(_ device: IOHIDDevice)
    func hidDeviceMaxReportSize(_ device: IOHIDDevice) -> Int
    func hidDeviceTransport(_ device: IOHIDDevice) -> String?
    func hidDeviceRegisterInputReportCallback(
        _ device: IOHIDDevice,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex,
        callback: IOHIDReportCallback?,
        context: UnsafeMutableRawPointer?
    )
}

/// Production driver. Each method forwards 1:1 to the kernel API so the
/// default-arg path through `AccelerometerSource()` produces byte-identical
/// IOKit traffic to the pre-seam build.
public struct RealAccelerometerKernelDriver: AccelerometerKernelDriver {
    public init() {}

    public func getMatchingServices(matching: CFDictionary?) -> (kr: kern_return_t, iterator: io_iterator_t) {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        return (kr, iterator)
    }

    public func iteratorNext(_ iterator: io_iterator_t) -> io_service_t {
        IOIteratorNext(iterator)
    }

    public func objectRelease(_ object: io_object_t) {
        IOObjectRelease(object)
    }

    public func registrySetCFProperty(_ service: io_service_t, key: CFString, value: CFTypeRef) -> kern_return_t {
        IORegistryEntrySetCFProperty(service, key, value)
    }

    public func registryCreateCFProperty(_ service: io_service_t, key: CFString) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    public func hidManagerCreate() -> IOHIDManager {
        IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func hidManagerOpen(_ manager: IOHIDManager) -> IOReturn {
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func hidManagerClose(_ manager: IOHIDManager) {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func hidManagerSetDeviceMatching(_ manager: IOHIDManager, matching: CFDictionary) {
        IOHIDManagerSetDeviceMatching(manager, matching)
    }

    public func hidManagerCopyDevices(_ manager: IOHIDManager) -> CFSet? {
        IOHIDManagerCopyDevices(manager)
    }

    public func hidManagerScheduleWithRunLoop(_ manager: IOHIDManager, runLoop: CFRunLoop, mode: CFString) {
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, mode)
    }

    public func hidManagerUnscheduleFromRunLoop(_ manager: IOHIDManager, runLoop: CFRunLoop, mode: CFString) {
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, mode)
    }

    public func hidDeviceOpen(_ device: IOHIDDevice) -> IOReturn {
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func hidDeviceClose(_ device: IOHIDDevice) {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func hidDeviceMaxReportSize(_ device: IOHIDDevice) -> Int {
        IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
    }

    public func hidDeviceTransport(_ device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    }

    public func hidDeviceRegisterInputReportCallback(
        _ device: IOHIDDevice,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex,
        callback: IOHIDReportCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        IOHIDDeviceRegisterInputReportCallback(device, report, reportLength, callback, context)
    }
}

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
public final class AccelerometerSource: SensorSource, Sendable {

    public let id = SensorID.accelerometer
    public let name = "Accelerometer"
    public let reportIntervalUS: Int
    public let detectorConfig: ImpactDetectorConfig
    public let bandpassLowHz: Float
    public let bandpassHighHz: Float
    /// Kernel-call seam. Default `RealAccelerometerKernelDriver` forwards
    /// 1:1 to IOKit, so `AccelerometerSource()` produces byte-identical
    /// kernel traffic to the pre-seam build. Tests inject
    /// `MockAccelerometerKernelDriver` to make kernel-fidelity gates
    /// reachable from XCTest.
    internal let kernelDriver: AccelerometerKernelDriver

    public convenience init(reportIntervalUS: Int = 10000,
                            bandpassLowHz: Float = 20.0, bandpassHighHz: Float = 25.0,
                            detectorConfig: ImpactDetectorConfig = .accelerometer()) {
        self.init(
            reportIntervalUS: reportIntervalUS,
            bandpassLowHz: bandpassLowHz, bandpassHighHz: bandpassHighHz,
            detectorConfig: detectorConfig,
            kernelDriver: RealAccelerometerKernelDriver()
        )
    }

    /// Designated initializer accepting a kernel-driver injection. Public
    /// callers reach the convenience overload which selects
    /// `RealAccelerometerKernelDriver`; tests use this overload to inject a
    /// mock.
    internal init(reportIntervalUS: Int = 10000,
                  bandpassLowHz: Float = 20.0, bandpassHighHz: Float = 25.0,
                  detectorConfig: ImpactDetectorConfig = .accelerometer(),
                  kernelDriver: AccelerometerKernelDriver) {
        self.reportIntervalUS = reportIntervalUS
        self.bandpassLowHz = bandpassLowHz
        self.bandpassHighHz = bandpassHighHz
        self.detectorConfig = detectorConfig
        self.kernelDriver = kernelDriver
    }

    /// Whether the adapter should be offered to the pipeline.
    ///
    /// **Direct build**: `SPU HID hardware is present`. The Direct build
    /// runs unsandboxed and `SensorActivation.activate()` succeeds at
    /// pipeline start, so we do not need to probe runtime activity ahead
    /// of time — we can always start the sensor ourselves on demand.
    /// Gating on `isSensorActivelyReporting()` here would be a
    /// chicken-and-egg deadlock: the UI would hide the adapter because
    /// it's not reporting, `impacts()` would never be called, and so
    /// the sensor would never start reporting. This is how issue #15
    /// manifested on M5 MacBooks where macOS does not keep the sensor
    /// warm at boot.
    ///
    /// **App Store build**: `SPU HID hardware is present AND the kernel
    /// driver has emitted a report in the last 500ms`. The runtime probe
    /// is honest about sandbox reality: `SensorActivation.activate()`
    /// calls are kernel-rejected (writes require an unsandboxed client),
    /// so whether the adapter can actually produce impacts depends on
    /// whether *something else* has warmed the sensor this boot — either
    /// macOS itself (WindowServer / locationd, when the system happens
    /// to subscribe for its own reasons) or the sensor-kickstart helper
    /// shipping via support docs. If neither is true, the sensor is
    /// cold and `isAvailable` returns false so
    /// `Migration.reconcileSensors` prunes the adapter before pipeline
    /// start instead of letting the watchdog fire on an empty stream
    /// mid-session.
    public var isAvailable: Bool {
        #if DIRECT_BUILD
        return AccelHardware.isSPUDevicePresent(driver: kernelDriver)
        #else
        return AccelHardware.isSPUDevicePresent(driver: kernelDriver) && AccelHardware.isSensorActivelyReporting(driver: kernelDriver)
        #endif
    }

    /// Device-presence check only (skips the runtime-activity probe).
    /// Tests that exercise stream lifecycle need to run on any Apple
    /// Silicon host with the BMI286 hardware, whether or not the sensor
    /// is currently warm — the tests don't depend on report delivery,
    /// they stress open/close cleanup paths.
    internal var hardwarePresent: Bool {
        AccelHardware.isSPUDevicePresent(driver: kernelDriver)
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
        let activated = SensorActivation.activate(reportIntervalUS: intervalUS, driver: kernelDriver)
        if !activated {
            log.info("activity:SensorActivation isPendingOn entity:SystemActivation falling through to passive read")
        }

        return AccelHardware.openStream(
            adapterID: id, adapterName: name,
            reportIntervalUS: intervalUS,
            bandpassLowHz: bandpassLowHz, bandpassHighHz: bandpassHighHz,
            detectorConfig: detectorConfig,
            driver: kernelDriver
        )
    }
}

// MARK: - Sensor activation via IORegistry
//
// Uses public IOKit functions with undocumented Apple-internal driver
// property keys. See file-level comment for rationale.

internal enum SensorActivation {
    static func activate(reportIntervalUS: Int, driver: AccelerometerKernelDriver) -> Bool {
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        let (kr, iterator) = driver.getMatchingServices(matching: matching)
        guard kr == KERN_SUCCESS else { return false }
        defer { driver.objectRelease(iterator) }

        var activated = false
        while true {
            let service = driver.iteratorNext(iterator)
            guard service != 0 else { break }
            defer { driver.objectRelease(service) }

            let r1 = driver.registrySetCFProperty(service, key: "ReportInterval" as CFString, value: reportIntervalUS as CFNumber)
            let r2 = driver.registrySetCFProperty(service, key: "SensorPropertyReportingState" as CFString, value: 1 as CFNumber)
            let r3 = driver.registrySetCFProperty(service, key: "SensorPropertyPowerState" as CFString, value: 1 as CFNumber)

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

    static func deactivate(driver: AccelerometerKernelDriver) {
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        let (kr, iterator) = driver.getMatchingServices(matching: matching)
        guard kr == KERN_SUCCESS else { return }
        defer { driver.objectRelease(iterator) }

        while true {
            let service = driver.iteratorNext(iterator)
            guard service != 0 else { break }
            defer { driver.objectRelease(service) }
            #if DIRECT_BUILD
            let kr1 = driver.registrySetCFProperty(service, key: "ReportInterval" as CFString, value: 0 as CFNumber)
            if kr1 != KERN_SUCCESS {
                log.warning("activity:SensorDeactivate wasInvalidatedBy entity:IORegistry kr=0x\(String(kr1, radix: 16))")
            }
            let kr2 = driver.registrySetCFProperty(service, key: "SensorPropertyReportingState" as CFString, value: 0 as CFNumber)
            if kr2 != KERN_SUCCESS {
                log.warning("activity:SensorDeactivate wasInvalidatedBy entity:IORegistry kr=0x\(String(kr2, radix: 16))")
            }
            let kr3 = driver.registrySetCFProperty(service, key: "SensorPropertyPowerState" as CFString, value: 0 as CFNumber)
            if kr3 != KERN_SUCCESS {
                log.warning("activity:SensorDeactivate wasInvalidatedBy entity:IORegistry kr=0x\(String(kr3, radix: 16))")
            }
            #else
            _ = driver.registrySetCFProperty(service, key: "ReportInterval" as CFString, value: 0 as CFNumber)
            _ = driver.registrySetCFProperty(service, key: "SensorPropertyReportingState" as CFString, value: 0 as CFNumber)
            _ = driver.registrySetCFProperty(service, key: "SensorPropertyPowerState" as CFString, value: 0 as CFNumber)
            #endif
        }
    }
}

// MARK: - Shared hardware access

internal enum AccelHardware {

    static func isSPUDevicePresent(driver: AccelerometerKernelDriver = RealAccelerometerKernelDriver()) -> Bool {
        let manager = driver.hidManagerCreate()
        guard driver.hidManagerOpen(manager) == kIOReturnSuccess else { return false }
        defer { driver.hidManagerClose(manager) }
        driver.hidManagerSetDeviceMatching(manager, matching: matchingDict)
        guard let devices = driver.hidManagerCopyDevices(manager) else { return false }
        return findSPUDevice(in: devices, driver: driver) != nil
    }

    /// Reads `DebugState._last_event_timestamp` on the `AppleSPUHIDDriver`
    /// service with `dispatchAccel = Yes` and compares it to
    /// `mach_absolute_time()`. Returns true when the most recent emitted
    /// report is within 500ms, meaning the kernel driver is actively
    /// streaming.
    ///
    /// Why this signal and not `ReportInterval` or `_num_events`:
    ///   • `ReportInterval` on the IOKit property dict is a write-only
    ///     command channel — the driver's `setProperty` accepts the write
    ///     as a "start streaming at this rate" command but never stores
    ///     the value, so reads always return 0 regardless of state.
    ///   • `_num_events` is a monotonic counter that freezes on
    ///     deactivation and doesn't reset until reboot, so a non-zero
    ///     value doesn't mean "currently streaming" — only "has ever
    ///     streamed this boot".
    ///   • `_last_event_timestamp` (mach_absolute_time units) updates
    ///     every report and is the only field that decays correctly when
    ///     the sensor goes cold. A 500ms staleness threshold is ~50
    ///     missed samples at 100Hz — well outside normal scheduler jitter.
    ///
    /// Read-only IORegistry lookup. Works from inside App Sandbox
    /// (sandbox blocks property WRITES, not reads).
    static func isSensorActivelyReporting(driver: AccelerometerKernelDriver = RealAccelerometerKernelDriver()) -> Bool {
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        let (kr, iterator) = driver.getMatchingServices(matching: matching)
        guard kr == KERN_SUCCESS else {
            return false
        }
        defer { driver.objectRelease(iterator) }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        while true {
            let service = driver.iteratorNext(iterator)
            guard service != 0 else { break }
            defer { driver.objectRelease(service) }

            // The SPU bus also hosts gyro, temperature, and hinge-angle
            // services. Only the one carrying `dispatchAccel = Yes` is
            // ours.
            let dispatchAccel = driver.registryCreateCFProperty(
                service, key: "dispatchAccel" as CFString
            ) as? Bool ?? false
            let debug = driver.registryCreateCFProperty(
                service, key: "DebugState" as CFString
            ) as? [String: Any]
            let lastTsRaw = debug?["_last_event_timestamp"] as? Int
            let now = mach_absolute_time()

            switch evaluateActivity(
                dispatchAccel: dispatchAccel,
                lastTsRaw: lastTsRaw,
                now: now,
                timebaseNumer: timebase.numer,
                timebaseDenom: timebase.denom,
                stalenessNs: AccelHardwareConstants.sensorActivityStalenessNs
            ) {
            case .skip: continue
            case .unreporting, .clockNonMonotonic, .stale: return false
            case .reporting: return true
            }
        }
        return false
    }

    static func openStream(
        adapterID: SensorID,
        adapterName: String,
        reportIntervalUS: Int = 10000,
        bandpassLowHz: Float = 20.0,
        bandpassHighHz: Float = 25.0,
        detectorConfig: ImpactDetectorConfig,
        driver: AccelerometerKernelDriver = RealAccelerometerKernelDriver()
    ) -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)

        let manager = driver.hidManagerCreate()
        let openResult = driver.hidManagerOpen(manager)
        guard openResult == kIOReturnSuccess else {
            let msg = String(format: "0x%08x", openResult)
            log.warning("activity:SensorReading failed IOHIDManagerOpen status=\(msg)")
            continuation.finish(throwing: SensorError.ioKitError(msg))
            return stream
        }

        driver.hidManagerSetDeviceMatching(manager, matching: matchingDict)

        guard let devices = driver.hidManagerCopyDevices(manager),
              let device = findSPUDevice(in: devices, driver: driver) else {
            driver.hidManagerClose(manager)
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        let devOpenResult = driver.hidDeviceOpen(device)
        guard devOpenResult == kIOReturnSuccess else {
            let msg = String(format: "0x%08x", devOpenResult)
            driver.hidManagerClose(manager)
            continuation.finish(throwing: SensorError.ioKitError(msg))
            return stream
        }

        log.info("entity:AccelDevice wasAssociatedWith agent:\(adapterName)")

        let maxSize = driver.hidDeviceMaxReportSize(device)
        guard maxSize > 0 else {
            log.error("entity:ReportBuffer wasInvalidatedBy activity:Allocate — maxSize is 0 or invalid")
            driver.hidDeviceClose(device)
            driver.hidManagerClose(manager)
            continuation.finish(throwing: SensorError.ioKitError(String(format: "0x%08x", kIOReturnInternalError)))
            return stream
        }
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

        driver.hidDeviceRegisterInputReportCallback(
            device, report: buffer, reportLength: maxSize,
            callback: { context, result, sender, type, reportID, report, reportLength in
                guard let context else { return }
                let ctx = Unmanaged<ReportContext>.fromOpaque(context).takeUnretainedValue()
                ctx.handleReport(report: report, length: reportLength)
            },
            context: ctxPtr.toOpaque()
        )

        let thread = HIDRunLoopThread()
        thread.start()
        thread.waitUntilReady()
        guard let runLoop = thread.runLoop, let rlMode = CFRunLoopMode.defaultMode else {
            buffer.deallocate()
            ctxPtr.release()
            driver.hidDeviceClose(device)
            driver.hidManagerClose(manager)
            continuation.finish(throwing: SensorError.ioKitError("HID thread run loop unavailable"))
            return stream
        }
        driver.hidManagerScheduleWithRunLoop(manager, runLoop: runLoop, mode: rlMode.rawValue)

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
                let now = Date()
                switch AccelHardware.evaluateWatchdogTick(snapshot: snapshot, now: now, stallThreshold: stallThreshold) {
                case .invalidated:
                    return
                case .alive:
                    continue
                case .stalled(let staleness):
                    log.warning("activity:SensorReading wasInvalidatedBy entity:Watchdog staleness=\(String(format: "%.1f", staleness))s sampleCount=\(snapshot.sampleCounter)")
                    ctx.surfaceStall(SensorError.ioKitError("accelerometer report stream stalled (\(Int(staleness))s without data)"))
                    return
                }
            }
        }

        let cleanup = OnceCleanup(AccelResources(
            iokit: IOKitHandles(
                manager: manager, device: device, buffer: buffer,
                maxSize: maxSize, runLoop: runLoop, runLoopMode: rlMode,
                ctxPtr: ctxPtr
            ),
            thread: thread, ctx: ctx,
            watchdog: WatchdogHandle(task: watchdogTask)
        ))

        continuation.onTermination = { @Sendable [driver] _ in
            cleanup.perform { r in
                // Phase 0 — cancel the watchdog so it stops polling and
                // never tries to surfaceStall on a torn-down context.
                r.watchdog.task.cancel()

                // Phase 1 — silence the report callback. Invalidating the
                // context sets running = false under the state lock. Any
                // HID callback that is in-flight at this moment will exit
                // early at the `guard s.running` check in handleReport,
                // guaranteeing it produces no further side effects. From
                // this point on the callback is a documented no-op even
                // while the HID run loop is still spinning.
                r.ctx.invalidate()
                SensorActivation.deactivate(driver: driver)

                // Phase 2 — stop the dedicated HID thread and WAIT for it
                // to exit. CFRunLoopStop is documented thread-safe; the
                // thread.cancel + join pair ensures the worker is no longer
                // inside CFRunLoopRunInMode before we touch any CF objects
                // it had scheduled. Without the join, the next phase races
                // CF data-structure modification (TSAN reports SEGV in
                // CF_IS_OBJC during a worker-thread CF dispatch).
                //
                // Teardown phase ordering contract:
                //   (1) ctx.invalidate() is called before the HID callback
                //       is unregistered and before the run loop stops.
                //       Invalidation is the primary guard: the callback
                //       checks running == false and returns immediately,
                //       so no new SensorImpact events are produced after
                //       Phase 1 regardless of whether a callback fires
                //       during the join window.
                //   (2) r.thread.join() is called before ctxPtr.release()
                //       and before any IOKit/CF handle mutation. The join
                //       guarantees the HID worker thread has fully exited
                //       CFRunLoopRunInMode, so no callback can be executing
                //       when Phase 3 modifies IOHIDManager state.
                //   (3) No callback can fire after ctxPtr.release() because
                //       Phase 3 unregisters the callback (nil handler, nil
                //       context) only after the join, ensuring the C-level
                //       IOHIDDevice callback pointer is cleared while no
                //       thread is inside the callback body. The invalidation
                //       in Phase 1 is the invariant; the nil-registration is
                //       belt-and-suspenders cleanup for IOKit internal state.
                r.thread.cancel()
                CFRunLoopStop(r.iokit.runLoop)
                r.thread.join()

                // Phase 3 — now safe to mutate IOHIDManager state and
                // close the device. The HID worker is fully exited.
                let k = r.iokit
                driver.hidDeviceRegisterInputReportCallback(k.device, report: k.buffer, reportLength: k.maxSize, callback: nil, context: nil)
                driver.hidManagerUnscheduleFromRunLoop(k.manager, runLoop: k.runLoop, mode: k.runLoopMode.rawValue)
                driver.hidDeviceClose(k.device)
                driver.hidManagerClose(k.manager)
                k.buffer.deallocate()
                k.ctxPtr.release()
            }
            log.info("activity:SensorReading wasEndedBy agent:\(adapterName)")
        }

        return stream
    }

    /// Watchdog poll-tick decision. Pure function so the gate at the
    /// `running` check is unit-testable: removing it must produce a
    /// `.stalled` outcome on an invalidated snapshot, which a behavioural
    /// cell can pin without spinning a real HID stream.
    enum WatchdogDecision: Equatable, Sendable {
        case invalidated              // running == false → bail out of poll loop
        case alive                    // staleness within budget → keep polling
        case stalled(TimeInterval)    // exceeded stall threshold → surface error
    }

    static func evaluateWatchdogTick(
        snapshot: (running: Bool, lastReportAt: Date, sampleCounter: Int),
        now: Date,
        stallThreshold: TimeInterval
    ) -> WatchdogDecision {
        guard snapshot.running else { return .invalidated }
        let staleness = now.timeIntervalSince(snapshot.lastReportAt)
        if staleness > stallThreshold { return .stalled(staleness) }
        return .alive
    }

    /// Activity-probe decision derived from a single SPU service reading.
    /// Pure helper extracted from `isSensorActivelyReporting()` so the
    /// `dispatchAccel` filter and the monotonic-clock guard can be
    /// exercised by direct unit calls — `IORegistryEntryCreateCFProperty`
    /// itself remains untestable, but everything downstream of "we got
    /// these properties back" is now mock-driven.
    enum ActivityDecision: Equatable, Sendable {
        case skip                     // service is gyro / temp / hinge — keep iterating
        case unreporting              // dispatchAccel matched but no usable timestamp
        case stale                    // timestamp older than freshness window
        case clockNonMonotonic        // mach_absolute_time reading went backwards
        case reporting                // sensor actively delivering reports
    }

    static func evaluateActivity(
        dispatchAccel: Bool,
        lastTsRaw: Int?,
        now: UInt64,
        timebaseNumer: UInt32,
        timebaseDenom: UInt32,
        stalenessNs: UInt64
    ) -> ActivityDecision {
        guard dispatchAccel else { return .skip }
        guard let raw = lastTsRaw, raw > 0 else { return .unreporting }
        let lastTs = UInt64(raw)
        guard now > lastTs else { return .clockNonMonotonic }
        // `&-` is wrap-on-underflow. The `now > lastTs` gate above is the
        // primary defense; the wrapping subtraction means a mutation that
        // removes the gate produces a `.stale` decode (the wrapped delta
        // is enormous, far past `stalenessNs`) rather than trapping the
        // process. That keeps the gate observable from a unit test
        // without a process crash.
        let deltaNs = (now &- lastTs) &* UInt64(timebaseNumer) / UInt64(timebaseDenom)
        return deltaNs < stalenessNs ? .reporting : .stale
    }

    static var matchingDict: CFDictionary {
        [kIOHIDPrimaryUsagePageKey as String: pageAccel, kIOHIDPrimaryUsageKey as String: usageAccel] as CFDictionary
    }

    static func findSPUDevice(in devices: CFSet, driver: AccelerometerKernelDriver = RealAccelerometerKernelDriver()) -> IOHIDDevice? {
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)
        for v in values {
            guard let v else { continue }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(v).takeUnretainedValue()
            if driver.hidDeviceTransport(device) == requiredTransport {
                return device
            }
        }
        return nil
    }
}

// MARK: - Accelerometer resource bundle (consumed by OnceCleanup on stream teardown)

/// Opaque handle bundle over the IOKit/CoreFoundation objects plus the raw
/// report buffer and retained `Unmanaged<ReportContext>`. Every field here is
/// a framework-owned type that does not (and cannot) participate in Swift
/// concurrency's Sendable graph: `IOHIDManager`, `IOHIDDevice`, `CFRunLoop`,
/// and `CFRunLoopMode` are CoreFoundation classes imported without Sendable
/// conformance; `UnsafeMutablePointer` is never Sendable; `Unmanaged` is a
/// retain-count wrapper with no concurrency semantics.
///
/// `@unchecked Sendable` is sound here because these handles participate in
/// a strictly-phased lifecycle that rules out concurrent access:
///
/// 1. Construction (on the thread that called `openStream`): all handles are
///    fetched / allocated / opened before the struct is built. Nothing else
///    in the process has a reference yet.
/// 2. Publish: the struct is moved once into `OnceCleanup(AccelResources)`
///    and then into the `continuation.onTermination` closure. No mutation
///    happens after publish; every field is `let`.
/// 3. Teardown: the cleanup closure is guaranteed to run at most once
///    (`OnceCleanup` uses an `OSAllocatedUnfairLock` around a consumed
///    optional). The teardown order is phase-sequenced:
///     - cancel the watchdog Task (waits for in-flight snapshot to finish)
///     - invalidate the ReportContext (subsequent HID callbacks no-op)
///     - cancel the HID thread and `join()` it so the run loop is fully
///       exited before we mutate CF state
///     - only then touch `manager`, `device`, `runLoop`, `runLoopMode`
///     - only then deallocate the buffer and release `ctxPtr`
///    After this closure returns, nothing in the program holds a live
///    reference to any of these handles.
///
/// The boundary is limited to the framework handles. The project-owned
/// `HIDRunLoopThread`, `ReportContext`, and `WatchdogHandle` live in the
/// enclosing `AccelResources` and participate in the Sendable graph
/// normally (they are real `Sendable`).
private struct IOKitHandles: @unchecked Sendable {
    let manager: IOHIDManager
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let maxSize: Int
    let runLoop: CFRunLoop
    let runLoopMode: CFRunLoopMode
    let ctxPtr: Unmanaged<ReportContext>
}

/// Resource bundle consumed by `OnceCleanup` on stream teardown. Sendable
/// because every field is either project-owned Sendable (`HIDRunLoopThread`,
/// `ReportContext`, `WatchdogHandle`) or wrapped in the narrow
/// `IOKitHandles` framework-boundary escape hatch above.
private struct AccelResources: Sendable {
    let iokit: IOKitHandles
    let thread: HIDRunLoopThread
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
///
/// Exposed as `internal` (rather than `private`) so mutation-coverage cells
/// in `Tests/MatrixAccelerometerReader_Tests.swift` can drive
/// `handleReport(report:length:)` with synthesised payloads. This is the
/// minimum surface needed to make the four behavioural gates inside
/// `handleReport` (length floor, running guard, decimation, magnitude
/// bounds) directly catchable by `make mutate`.
internal final class ReportContext: Sendable {
    let adapterID: SensorID

    /// Every field is now Sendable on its own: the continuation, filters,
    /// and detector are all Sendable value- or lock-protected types, so the
    /// state struct is genuinely Sendable without `@unchecked`. The filters
    /// are value types and must be `var` so we can call their mutating
    /// `process(_:)` methods inside `state.withLock { s in ... }`.
    private struct State: Sendable {
        var running = true
        var sampleCounter = 0
        /// Wall-clock time of the most recent successful report. The watchdog
        /// reads this to detect stalled HID streams (e.g., system stopped
        /// keeping the SPU sensor warm in the App Store sandbox after sleep).
        var lastReportAt: Date = Date()
        let continuation: AsyncThrowingStream<SensorImpact, Error>.Continuation
        var hpFilter: HighPassFilter
        var lpFilter: LowPassFilter
        let detector: ImpactDetector
    }
    private let state: OSAllocatedUnfairLock<State>

    internal init(adapterID: SensorID,
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
    internal func watchdogSnapshot() -> (running: Bool, lastReportAt: Date, sampleCounter: Int) {
        state.withLock { ($0.running, $0.lastReportAt, $0.sampleCounter) }
    }

    /// Surfaces a recoverable error to the consuming AsyncThrowingStream.
    /// Used by the watchdog when no reports arrive for the stall threshold.
    /// Marks the context invalid first so any in-flight callback no-ops.
    internal func surfaceStall(_ error: Error) {
        let cont = state.withLock { s -> AsyncThrowingStream<SensorImpact, Error>.Continuation? in
            // Double-stall guard: once we've finished the continuation no
            // second error must reach the consumer.
            guard s.running else { return nil /* already-stalled */ }
            s.running = false
            return s.continuation
        }
        cont?.finish(throwing: error)
    }

    internal func handleReport(report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length >= minReportLength else { return }

        // Int32 axes at byte offsets 6/10/14 are NOT 4-byte aligned. Using
        // `withMemoryRebound` on a misaligned pointer is undefined behavior
        // per the Swift memory model, even if it happens to work on Apple
        // Silicon. `loadUnaligned` is the sanctioned API for this case.
        let rawBuffer = UnsafeRawPointer(report)
        let rawX = rawBuffer.loadUnaligned(fromByteOffset: 6, as: Int32.self)
        let rawY = rawBuffer.loadUnaligned(fromByteOffset: 10, as: Int32.self)
        let rawZ = rawBuffer.loadUnaligned(fromByteOffset: 14, as: Int32.self)

        // Resolve any pending yield outside the lock. Calling continuation.yield()
        // while holding state.lock would cause a recursive os_unfair_lock abort
        // because AsyncThrowingStream._Storage acquires the same lock internally.
        typealias Pending = (cont: AsyncThrowingStream<SensorImpact, Error>.Continuation, impact: SensorImpact)
        let pending: Pending? = state.withLock { s in
            guard s.running else { return nil }
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
            guard s.sampleCounter % decimationFactor == 0 else { return nil }

            let raw = Vec3(x: Float(rawX) / rawScale, y: Float(rawY) / rawScale, z: Float(rawZ) / rawScale)
            let rawMag = raw.magnitude
            guard rawMag > magnitudeMin && rawMag < magnitudeMax else { return nil }

            let filtered = s.lpFilter.process(s.hpFilter.process(raw))
            let filteredMag = filtered.magnitude

            let now = Date()
            guard let intensity = s.detector.process(magnitude: filteredMag, timestamp: now) else { return nil }
            return (s.continuation, SensorImpact(source: self.adapterID, timestamp: now, intensity: intensity))
        }
        if let pending { pending.cont.yield(pending.impact) }
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
    /// Framework-handle bundle for the HID worker thread. Both fields fall
    /// outside Swift concurrency's Sendable graph: `Thread` is explicitly
    /// marked `@_nonSendable` in the Foundation overlay, and `CFRunLoop`
    /// is a CoreFoundation class imported without Sendable conformance.
    ///
    /// This is the minimal possible `@unchecked Sendable` boundary: the
    /// struct holds only the two framework handles with no other state.
    /// Access is sound because:
    ///
    /// 1. Every read and write goes through the enclosing
    ///    `OSAllocatedUnfairLock<State>`, serializing observation order.
    /// 2. The handles' mutating operations are independently thread-safe
    ///    by Apple design:
    ///      - `Thread.cancel()` and `Thread.isCancelled` are documented
    ///        thread-safe.
    ///      - `CFRunLoopStop(_:)` is documented thread-safe — the canonical
    ///        cross-thread way to wake a run loop and exit
    ///        `CFRunLoopRunInMode`.
    ///      - `CFRunLoopGetCurrent()` is called only inside the Thread
    ///        block, on the worker thread itself, and the result is
    ///        published under the lock before any external observer can
    ///        read `runLoop`.
    /// 3. The lifecycle is phased — `start()` → `waitUntilReady()` → use →
    ///    `cancel()` → `join()`. Teardown callers must `join()` before
    ///    touching CF objects the worker scheduled, or they race
    ///    `CF_IS_OBJC` (TSAN-caught SEGV). The outer `AccelResources`
    ///    teardown closure enforces this ordering.
    ///
    /// What would break if we dropped the lock: after `start()` returns,
    /// two threads can legally race `state.thread?.isCancelled` (worker
    /// thread reads in its poll loop) against the main thread's
    /// `cancel()` write to `state.thread` or `state.runLoop`. The lock
    /// prevents that data race on the `Optional<Thread>` / `Optional<CFRunLoop>`
    /// storage slots themselves, which is separate from the thread-safety
    /// of the pointees' own APIs.
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
