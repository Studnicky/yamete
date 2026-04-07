#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import IOKit.hid
import IOHIDPublic

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

private let pageAccel: Int = 0xFF00
private let usageAccel: Int = 3
private let requiredTransport = "SPU"
private let decimationFactor = 2
private let magnitudeMin: Float = 0.3
private let magnitudeMax: Float = 4.0
private let minReportLength = 18
private let rawScale: Float = 65536.0
private let reportIntervalUS: Int = 10000

/// Default accelerometer detection config (bandpass-filtered g-force units).
/// Spike threshold, rise rate, crest factor operate on filtered accelerometer magnitude.
public func defaultAccelDetectorConfig(
    spikeThreshold: Float = 0.020, riseRate: Float = 0.010,
    crestFactor: Float = 1.5, confirmations: Int = 3,
    warmupSamples: Int = 50
) -> ImpactDetectorConfig {
    ImpactDetectorConfig(
        spikeThreshold: spikeThreshold, minRiseRate: riseRate,
        minCrestFactor: crestFactor, minConfirmations: confirmations,
        warmupSamples: warmupSamples,
        intensityFloor: 0.002, intensityCeiling: 0.060
    )
}

// MARK: - Accelerometer Adapter

/// Reads BMI286 accelerometer via IOKit public APIs and streams impact events.
///
/// Activation: IOHIDEventSystemClientCreate → IOHIDServiceClientSetProperty("ReportInterval")
/// Reading: IOHIDManager → IOHIDDeviceRegisterInputReportCallback → bandpass → ImpactDetector
public final class SPUAccelerometerAdapter: SensorAdapter, @unchecked Sendable {

    public let id = SensorID("accelerometer")
    public let name = "Accelerometer"
    public let reportIntervalUS: Int
    public let detectorConfig: ImpactDetectorConfig
    public let bandpassLowHz: Float
    public let bandpassHighHz: Float

    public init(reportIntervalUS: Int = 10000,
                bandpassLowHz: Float = 20.0, bandpassHighHz: Float = 25.0,
                detectorConfig: ImpactDetectorConfig = defaultAccelDetectorConfig()) {
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

        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) ?? ("" as CFString)
        log.info("entity:AccelDevice wasAssociatedWith agent:\(adapterName) serial=\(serial)")

        let maxSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        buffer.initialize(repeating: 0, count: maxSize)

        let ctx = ReportContext(
            adapterID: adapterID,
            continuation: continuation,
            hpFilter: HighPassFilter(cutoffHz: bandpassLowHz, sampleRate: 50.0),
            lpFilter: LowPassFilter(cutoffHz: bandpassHighHz, sampleRate: 50.0),
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

        let cleanup = CleanupState(
            manager: manager, device: device, buffer: buffer,
            maxSize: maxSize, runLoop: runLoop, runLoopMode: rlMode,
            thread: thread, ctxPtr: ctxPtr, ctx: ctx,
            svcClient: svcClient, services: services
        )

        continuation.onTermination = { @Sendable _ in
            cleanup.perform()
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

// MARK: - Cleanup state

private struct CleanupState: @unchecked Sendable {
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

    func perform() {
        ctx.invalidate()
        if let services {
            for i in 0..<CFArrayGetCount(services) {
                let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClient.self)
                IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, 0 as CFNumber)
            }
        }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, maxSize, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, runLoopMode.rawValue)
        CFRunLoopStop(runLoop)
        thread.cancel()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
        ctxPtr.release()
    }
}

// MARK: - Report decode + detection context

/// Decodes HID reports, applies bandpass filtering, and runs ImpactDetector.
/// Emits SensorImpact events when impacts are detected.
private final class ReportContext: @unchecked Sendable {
    let adapterID: SensorID
    let continuation: AsyncThrowingStream<SensorImpact, Error>.Continuation
    let hpFilter: HighPassFilter
    let lpFilter: LowPassFilter
    let detector: ImpactDetector

    private var running = true
    private var sampleCounter = 0

    init(adapterID: SensorID,
         continuation: AsyncThrowingStream<SensorImpact, Error>.Continuation,
         hpFilter: HighPassFilter, lpFilter: LowPassFilter,
         detector: ImpactDetector) {
        self.adapterID = adapterID
        self.continuation = continuation
        self.hpFilter = hpFilter
        self.lpFilter = lpFilter
        self.detector = detector
    }

    func invalidate() { running = false }

    func handleReport(report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard running, length >= minReportLength else { return }

        sampleCounter += 1
        guard sampleCounter % decimationFactor == 0 else { return }

        let rawX = report.advanced(by: 6).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let rawY = report.advanced(by: 10).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let rawZ = report.advanced(by: 14).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

        let raw = Vec3(x: Float(rawX) / rawScale, y: Float(rawY) / rawScale, z: Float(rawZ) / rawScale)
        let rawMag = raw.magnitude
        guard rawMag > magnitudeMin && rawMag < magnitudeMax else { return }

        // Bandpass filter
        let filtered = lpFilter.process(hpFilter.process(raw))
        let filteredMag = filtered.magnitude

        // Run detector — returns 0-1 intensity if impact detected
        let now = Date()
        if let intensity = detector.process(magnitude: filteredMag, timestamp: now) {
            continuation.yield(SensorImpact(source: adapterID, timestamp: now, intensity: intensity))
        }
    }
}

// MARK: - HID run loop thread

private final class HIDRunLoopThread: Thread, @unchecked Sendable {
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        while !isCancelled {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false)
        }
    }

    func waitUntilReady() { ready.wait() }
}
