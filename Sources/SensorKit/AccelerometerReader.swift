#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import IOKit.hid

// MARK: - SPUAccelerometerAdapter
//
// Reads the BMI286 accelerometer via a hybrid approach:
//
//   Activation:  IOHIDServiceClientSetProperty("ReportInterval") — this is the only
//                way to wake the SPU sensor. IOHIDDeviceSetProperty does NOT propagate
//                to the SPU service. These bindings use @_silgen_name for the service
//                property functions only.
//
//   Reading:     IOHIDManager + IOHIDDeviceRegisterInputReportCallback — fully public
//                IOKit C API. Works under App Sandbox with device.usb entitlement.
//
// The sensor appears as a vendor-defined HID device:
//   PrimaryUsagePage = 0xFF00, PrimaryUsage = 3, Transport = "SPU"
//
// Raw reports are 22 bytes:
//   Bytes  0–1:  uint16 LE sample counter (increments by 8 per sample at 10ms)
//   Bytes  2–5:  padding (zeros)
//   Bytes  6–9:  int32 LE X acceleration (unit: 1/65536 g)
//   Bytes 10–13: int32 LE Y acceleration (unit: 1/65536 g)
//   Bytes 14–17: int32 LE Z acceleration (unit: 1/65536 g)
//   Bytes 18–21: configuration/status (constant)
//
// App Sandbox: Requires com.apple.security.device.usb entitlement.

private let log = AppLog(category: "Accelerometer")

// MARK: - SPU service activation bindings
//
// The SPU accelerometer requires ReportInterval to be set on the IOHIDServiceClient
// (the kernel-side service), not the user-space IOHIDDevice. These are the minimal
// bindings needed to activate/deactivate the sensor. Everything else uses public API.

private typealias IOHIDEventSystemClientRef = OpaquePointer
private typealias IOHIDServiceClientRef = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func IOHIDEventSystemClientCreateWithType(
    _ allocator: CFAllocator?, _ type: Int32, _ properties: CFDictionary?
) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(
    _ client: IOHIDEventSystemClientRef, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(
    _ client: IOHIDEventSystemClientRef) -> CFArray?

@_silgen_name("IOHIDServiceClientSetProperty")
@discardableResult
private func IOHIDServiceClientSetProperty(
    _ service: IOHIDServiceClientRef, _ key: CFString, _ value: CFTypeRef) -> Bool

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(
    _ service: IOHIDServiceClientRef, _ key: CFString) -> CFTypeRef?

/// Reads BMI286 accelerometer via IOHIDManager (public API) and streams Vec3 samples.
/// Sensor activation uses IOHIDServiceClient to set ReportInterval on the SPU service.
public final class SPUAccelerometerAdapter: SensorAdapter, @unchecked Sendable {

    public let id = SensorID("spu-accelerometer")
    public let name = "Apple SPU Accelerometer"

    public init() {}

    /// HID Usage Page 0xFF00: vendor-defined page used by Apple motion sensors
    private let pageAccel: Int = 0xFF00
    /// HID Usage 3: accelerometer within the vendor motion sensor page
    private let usageAccel: Int = 3
    /// Transport identifier for the SPU (Sensor Processing Unit) accelerometer
    private let requiredTransport = "SPU"
    /// Sensor report interval in microseconds (10000 = 10ms = 100 Hz sample rate)
    private let reportIntervalUS: Int = 10000
    /// IOHIDEventSystemClient type: 1 = monitor mode (can access services)
    private let clientType: Int32 = 1
    /// Skip every other sample (100Hz → 50Hz effective rate)
    private let decimationFactor = 2
    /// Reject samples below 0.3g (sensor noise floor)
    private let magnitudeMin: Float = 0.3
    /// Reject samples above 4.0g (corrupt/impossible data)
    private let magnitudeMax: Float = 4.0
    /// Minimum report length in bytes
    private let minReportLength = 18
    /// Scale factor: raw int32 values are in units of 1/65536 g
    private let rawScale: Float = 65536.0

    // MARK: - SensorAdapter

    public var isAvailable: Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matchingDict)
        guard let devices = IOHIDManagerCopyDevices(manager) else { return false }
        return findSPUDevice(in: devices) != nil
    }

    public func samples() -> AsyncThrowingStream<Vec3, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Vec3.self)

        // Step 1: Activate the SPU sensor via IOHIDServiceClient
        guard let svcClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, clientType, nil) else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }
        let svcMatching: [String: Any] = ["PrimaryUsagePage": pageAccel, "PrimaryUsage": usageAccel]
        IOHIDEventSystemClientSetMatching(svcClient, svcMatching as CFDictionary)

        guard let services = IOHIDEventSystemClientCopyServices(svcClient) else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        var activated = false
        for i in 0..<CFArrayGetCount(services) {
            let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
            let transport = IOHIDServiceClientCopyProperty(svc, "Transport" as CFString)
            if "\(transport ?? ("" as CFString))" == requiredTransport {
                IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, reportIntervalUS as CFNumber)
                activated = true
            }
        }

        guard activated else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        // Step 2: Open the device via public IOHIDManager for report reading
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
        log.info("entity:AccelDevice wasAssociatedWith agent:SPUAccelerometerAdapter serial=\(serial) interval=\(reportIntervalUS)us")

        let maxSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        buffer.initialize(repeating: 0, count: maxSize)

        let ctx = ReportContext(
            continuation: continuation,
            decimationFactor: decimationFactor,
            magnitudeMin: magnitudeMin,
            magnitudeMax: magnitudeMax,
            minReportLength: minReportLength,
            rawScale: rawScale
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

        // Schedule manager on a dedicated run loop thread for report delivery
        let thread = HIDRunLoopThread()
        thread.start()
        while thread.runLoop == nil { Thread.sleep(forTimeInterval: 0.001) }
        let runLoop = thread.runLoop!
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode!.rawValue)

        log.info("activity:SensorReading wasStartedBy agent:SPUAccelerometerAdapter")

        // Wrap cleanup resources for safe @Sendable capture
        let cleanup = CleanupState(
            manager: manager, device: device, buffer: buffer,
            maxSize: maxSize, runLoop: runLoop, thread: thread,
            ctxPtr: ctxPtr, ctx: ctx,
            svcClient: svcClient, services: services
        )

        continuation.onTermination = { @Sendable _ in
            cleanup.perform()
            log.info("activity:SensorReading wasEndedBy agent:SPUAccelerometerAdapter")
        }

        return stream
    }

    // MARK: - Helpers

    private var matchingDict: CFDictionary {
        [
            kIOHIDPrimaryUsagePageKey as String: pageAccel,
            kIOHIDPrimaryUsageKey as String: usageAccel,
        ] as CFDictionary
    }

    private func findSPUDevice(in devices: CFSet) -> IOHIDDevice? {
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)

        for v in values {
            guard let v else { continue }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(v).takeUnretainedValue()
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            if transport == requiredTransport { return device }
        }
        return nil
    }
}

// MARK: - Cleanup state

/// Bundles all resources needed for teardown into a single @unchecked Sendable value.
private struct CleanupState: @unchecked Sendable {
    let manager: IOHIDManager
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let maxSize: Int
    let runLoop: CFRunLoop
    let thread: HIDRunLoopThread
    let ctxPtr: Unmanaged<ReportContext>
    let ctx: ReportContext
    let svcClient: IOHIDEventSystemClientRef
    let services: CFArray

    func perform() {
        ctx.invalidate()

        // Deactivate SPU sensor via service property
        for i in 0..<CFArrayGetCount(services) {
            let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
            IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, 0 as CFNumber)
        }

        IOHIDDeviceRegisterInputReportCallback(device, buffer, maxSize, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode!.rawValue)
        CFRunLoopStop(runLoop)
        thread.cancel()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
        ctxPtr.release()
    }
}

// MARK: - Report decode context

/// Bridges IOHIDDevice input report callbacks to the AsyncThrowingStream continuation.
/// All mutable state is confined to the run loop thread that IOHIDManager delivers on.
private final class ReportContext: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Vec3, Error>.Continuation
    let decimationFactor: Int
    let magnitudeMin: Float
    let magnitudeMax: Float
    let minReportLength: Int
    let rawScale: Float

    private var running = true
    private var sampleCounter = 0
    #if DEBUG
    private var peakMag: Float = 0
    private var peakVec: Vec3 = .zero
    #endif

    init(continuation: AsyncThrowingStream<Vec3, Error>.Continuation,
         decimationFactor: Int, magnitudeMin: Float, magnitudeMax: Float,
         minReportLength: Int, rawScale: Float) {
        self.continuation = continuation
        self.decimationFactor = decimationFactor
        self.magnitudeMin = magnitudeMin
        self.magnitudeMax = magnitudeMax
        self.minReportLength = minReportLength
        self.rawScale = rawScale
    }

    func invalidate() { running = false }

    func handleReport(report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard running, length >= minReportLength else { return }

        sampleCounter += 1
        guard sampleCounter % decimationFactor == 0 else { return }

        // Decode int32 LE at byte offsets 6, 10, 14 and scale to g-force
        let rawX = report.advanced(by: 6).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let rawY = report.advanced(by: 10).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        let rawZ = report.advanced(by: 14).withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

        let vec = Vec3(
            x: Float(rawX) / rawScale,
            y: Float(rawY) / rawScale,
            z: Float(rawZ) / rawScale
        )
        let mag = vec.magnitude

        #if DEBUG
        if mag > peakMag { peakMag = mag; peakVec = vec }
        if sampleCounter % 500 == 0 {
            log.debug("entity:AccelSample n=\(sampleCounter) cur=\(String(format: "%.3f", mag)) peak=\(String(format: "%.3f", peakMag)) peakVec=\(peakVec)")
            peakMag = 0
        }
        #endif

        guard mag > magnitudeMin && mag < magnitudeMax else { return }
        continuation.yield(vec)
    }
}

// MARK: - HID run loop thread

/// Dedicated thread with its own CFRunLoop for IOHIDManager callbacks.
private final class HIDRunLoopThread: Thread, @unchecked Sendable {
    private(set) var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        while !isCancelled {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false)
        }
    }
}
