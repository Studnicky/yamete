#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import IOKit.hid
import IOHIDPublic
import os

// MARK: - BMI286 Accelerometer Adapter
//
// Reads the BMI286 accelerometer on Apple Silicon Macs via IOKit public APIs.
// Runs its own detection pipeline (bandpass → ImpactDetector) and emits
// SensorImpact events with 0–1 intensity.
//
// The sensor appears as a vendor-defined HID device:
//   PrimaryUsagePage = 0xFF00, PrimaryUsage = 3, Transport = "SPU"
//
// Activation (IOHIDEventSystemClient API):
//   IOHIDEventSystemClientCreate          → create event system client
//   IOHIDEventSystemClientCopyServices    → enumerate HID services
//   IOHIDServiceClientSetProperty         → set ReportInterval on SPU service
//   IOHIDServiceClientCopyProperty        → read service properties (Transport, etc.)
//
// Reading (IOHIDManager API):
//   IOHIDManagerCreate / Open / SetDeviceMatching / CopyDevices
//   IOHIDDeviceOpen / RegisterInputReportCallback
//
// App Sandbox: Requires com.apple.security.device.usb entitlement.
//
// Public API documentation:
//   https://developer.apple.com/documentation/iokit/iohidmanager_h
//   https://developer.apple.com/documentation/iokit/iohiddevice_h
//   https://developer.apple.com/documentation/iokit/iohideventsystemclientref
//   https://developer.apple.com/documentation/iokit/iohidserviceclientref
//   https://developer.apple.com/documentation/iokit/2269429-iohidserviceclientsetproperty
//   https://developer.apple.com/documentation/iokit/2269430-iohidserviceclientcopyproperty
//   https://developer.apple.com/documentation/iokit/2269432-iohideventsystemclientcopyservic
//   https://developer.apple.com/documentation/iokit/1588653-iohiddevicesetproperty

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
/// Activation: IOHIDEventSystemClientCreate → IOHIDServiceClientSetProperty("ReportInterval")
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

    public var isAvailable: Bool { AccelHardware.isSPUDevicePresent() }

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let intervalUS = reportIntervalUS

        guard let svcClientUnmanaged = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }
        let svcClient = svcClientUnmanaged.takeRetainedValue()
        let svcMatching: [String: Any] = ["PrimaryUsagePage": pageAccel, "PrimaryUsage": usageAccel]
        IOHIDEventSystemClientSetMatching(svcClient, svcMatching as CFDictionary)

        guard let services = IOHIDEventSystemClientCopyServices(svcClient) else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        var activated = false
        for i in 0..<CFArrayGetCount(services) {
            let svc = unsafeBitCast(
                CFArrayGetValueAtIndex(services, i),
                to: IOHIDServiceClient.self
            )
            let transport = IOHIDServiceClientCopyProperty(svc, "Transport" as CFString)
            if "\(transport ?? ("" as CFString))" == requiredTransport {
                IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, intervalUS as CFNumber)
                activated = true
            }
        }

        guard activated else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        return AccelHardware.openStream(
            adapterID: id, adapterName: name,
            reportIntervalUS: intervalUS,
            bandpassLowHz: bandpassLowHz, bandpassHighHz: bandpassHighHz,
            detectorConfig: detectorConfig,
            svcClient: svcClient, services: services
        )
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
        detectorConfig: ImpactDetectorConfig,
        svcClient: IOHIDEventSystemClient? = nil,
        services: CFArray? = nil
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

        let cleanup = OnceCleanup(AccelResources(
            manager: manager, device: device, buffer: buffer,
            maxSize: maxSize, runLoop: runLoop, runLoopMode: rlMode,
            thread: thread, ctxPtr: ctxPtr, ctx: ctx,
            svcClient: svcClient, services: services
        ))

        continuation.onTermination = { @Sendable _ in
            cleanup.perform { r in
                r.ctx.invalidate()
                if let services = r.services {
                    for i in 0..<CFArrayGetCount(services) {
                        let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClient.self)
                        IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, 0 as CFNumber)
                    }
                }
                IOHIDDeviceRegisterInputReportCallback(r.device, r.buffer, r.maxSize, nil, nil)
                IOHIDManagerUnscheduleFromRunLoop(r.manager, r.runLoop, r.runLoopMode.rawValue)
                CFRunLoopStop(r.runLoop)
                r.thread.cancel()
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

private struct AccelResources {
    let manager: IOHIDManager
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let maxSize: Int
    let runLoop: CFRunLoop
    let runLoopMode: CFRunLoopMode
    let thread: HIDRunLoopThread
    let ctxPtr: Unmanaged<ReportContext>
    let ctx: ReportContext
    let svcClient: IOHIDEventSystemClient?
    let services: CFArray?
}

// MARK: - Report decode + detection context

/// Decodes HID reports, applies bandpass filtering, and runs ImpactDetector.
/// All mutable and non-Sendable state is lock-protected.
private final class ReportContext: Sendable {
    let adapterID: SensorID

    private struct State {
        var running = true
        var sampleCounter = 0
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

    func handleReport(report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length >= minReportLength else { return }

        let rawX = report.advanced(by: 6).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let rawY = report.advanced(by: 10).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let rawZ = report.advanced(by: 14).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

        state.withLock { s in
            guard s.running else { return }
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
private struct HIDRunLoopThread: Sendable {
    private struct State {
        var runLoop: CFRunLoop?
        var thread: Thread?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let ready = DispatchSemaphore(value: 0)

    var runLoop: CFRunLoop? { state.withLock { $0.runLoop } }

    init() {
        state = OSAllocatedUnfairLock(initialState: State())
    }

    func start() {
        let stateRef = state
        let readyRef = ready
        let thread = Thread {
            stateRef.withLock { $0.runLoop = CFRunLoopGetCurrent() }
            readyRef.signal()
            var cancelled = false
            while !cancelled {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false)
                cancelled = stateRef.withLock { $0.thread?.isCancelled ?? true }
            }
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
}
