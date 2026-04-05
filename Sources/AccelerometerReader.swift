import Foundation
import IOKit.hid

// MARK: - IOHIDEventSystem bindings (private but stable macOS API)
//
// On macOS 15+, the SPU accelerometer is a motion-restricted HID event service.
// Raw IOHIDManager reports are not delivered for restricted services. Instead,
// we use IOHIDEventSystemClient (type 1/monitor) which:
//   1. Matches the service by UsagePage=0xFF00, Usage=3
//   2. Sets ReportInterval on the service to activate the sensor
//   3. Receives structured IOHIDEvent callbacks with acceleration vectors

private let log = AppLog(category: "Accelerometer")

private typealias IOHIDEventSystemClientRef = OpaquePointer
private typealias IOHIDServiceClientRef = OpaquePointer
private typealias IOHIDEventRef = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func IOHIDEventSystemClientCreateWithType(
    _ allocator: CFAllocator?, _ type: Int32, _ properties: CFDictionary?
) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientScheduleWithDispatchQueue")
private func IOHIDEventSystemClientScheduleWithDispatchQueue(
    _ client: IOHIDEventSystemClientRef, _ queue: DispatchQueue)

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

private typealias IOHIDEventCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?, IOHIDEventRef) -> Void

@_silgen_name("IOHIDEventSystemClientRegisterEventCallback")
private func IOHIDEventSystemClientRegisterEventCallback(
    _ client: IOHIDEventSystemClientRef, _ callback: IOHIDEventCallback,
    _ target: UnsafeMutableRawPointer?, _ refcon: UnsafeMutableRawPointer?)

@_silgen_name("IOHIDEventGetType")
private func IOHIDEventGetType(_ event: IOHIDEventRef) -> Int32

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

// MARK: - SPUAccelerometerAdapter

/// Reads BMI286 accelerometer via IOHIDEventSystemClient and streams Vec3 samples.
/// Callbacks arrive on a dedicated dispatch queue; samples forwarded via continuation.
final class SPUAccelerometerAdapter: SensorAdapter, @unchecked Sendable {

    let name = "Apple SPU Accelerometer"

    private let clientType: Int32 = 1           // monitor
    private let pageAccel:  Int = 0xFF00
    private let usageAccel: Int = 3
    private let reportIntervalUS: Int = 10000   // 10ms = 100Hz
    private let accelEventType: Int32 = 13      // accelerometer event type on macOS 15
    private let decimationFactor = 2
    private let magnitudeMin: Float = 0.3
    private let magnitudeMax: Float = 4.0

    // MARK: - SensorAdapter

    var isAvailable: Bool {
        guard let c = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, clientType, nil) else { return false }
        let matching: [String: Any] = ["PrimaryUsagePage": pageAccel, "PrimaryUsage": usageAccel]
        IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(c) else { return false }
        for i in 0..<CFArrayGetCount(services) {
            let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
            let transport = IOHIDServiceClientCopyProperty(svc, "Transport" as CFString)
            if "\(transport ?? ("" as CFString))" == "SPU" { return true }
        }
        return false
    }

    func samples() -> AsyncThrowingStream<Vec3, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Vec3.self)

        let ctx = EventContext(
            continuation: continuation,
            accelEventType: accelEventType,
            decimationFactor: decimationFactor,
            magnitudeMin: magnitudeMin,
            magnitudeMax: magnitudeMax
        )

        guard let c = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, clientType, nil) else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }
        ctx.client = c

        let matching: [String: Any] = ["PrimaryUsagePage": pageAccel, "PrimaryUsage": usageAccel]
        IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)

        var activated = false
        if let services = IOHIDEventSystemClientCopyServices(c) {
            for i in 0..<CFArrayGetCount(services) {
                let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
                let transport = IOHIDServiceClientCopyProperty(svc, "Transport" as CFString)
                if "\(transport ?? ("" as CFString))" == "SPU" {
                    IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, reportIntervalUS as CFNumber)
                    activated = true
                    let serial = IOHIDServiceClientCopyProperty(svc, "SerialNumber" as CFString) ?? ("" as CFString)
                    log.info("entity:AccelDevice wasAssociatedWith agent:SPUAccelerometerAdapter serial=\(serial) interval=\(reportIntervalUS)us")
                }
            }
        }

        if !activated {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        let ctxPtr = Unmanaged.passRetained(ctx)
        let eventCallback: IOHIDEventCallback = { _, refcon, _, event in
            guard let refcon else { return }
            let ctx = Unmanaged<EventContext>.fromOpaque(refcon).takeUnretainedValue()
            ctx.handleEvent(event)
        }
        IOHIDEventSystemClientRegisterEventCallback(c, eventCallback, nil, ctxPtr.toOpaque())

        let q = DispatchQueue(label: "com.yamete.accelerometer", qos: .userInteractive)
        ctx.queue = q
        IOHIDEventSystemClientScheduleWithDispatchQueue(c, q)

        log.info("activity:SensorReading wasStartedBy agent:SPUAccelerometerAdapter")

        // ctx holds the client reference; use it for cleanup
        continuation.onTermination = { @Sendable _ in
            guard let c = ctx.client else { return }
            if let services = IOHIDEventSystemClientCopyServices(c) {
                for i in 0..<CFArrayGetCount(services) {
                    let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
                    IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, 0 as CFNumber)
                }
            }
            ctxPtr.release()
            log.info("activity:SensorReading wasEndedBy agent:SPUAccelerometerAdapter")
        }

        return stream
    }
}

// MARK: - Event callback context

private final class EventContext: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Vec3, Error>.Continuation
    let accelEventType: Int32
    let decimationFactor: Int
    let magnitudeMin: Float
    let magnitudeMax: Float

    var client: IOHIDEventSystemClientRef?
    var queue: DispatchQueue?
    var sampleCounter = 0
    var peakMag: Float = 0
    var peakVec: Vec3 = .zero

    init(continuation: AsyncThrowingStream<Vec3, Error>.Continuation,
         accelEventType: Int32, decimationFactor: Int,
         magnitudeMin: Float, magnitudeMax: Float) {
        self.continuation = continuation
        self.accelEventType = accelEventType
        self.decimationFactor = decimationFactor
        self.magnitudeMin = magnitudeMin
        self.magnitudeMax = magnitudeMax
    }

    func handleEvent(_ event: IOHIDEventRef) {
        let eventType = IOHIDEventGetType(event)
        if sampleCounter < 5 {
            log.debug("entity:HIDEvent type=\(eventType) expected=\(accelEventType)")
        }
        guard eventType == accelEventType else { return }

        sampleCounter += 1
        guard sampleCounter % decimationFactor == 0 else { return }

        let base = accelEventType << 16
        let x = Float(IOHIDEventGetFloatValue(event, base | 0))
        let y = Float(IOHIDEventGetFloatValue(event, base | 1))
        let z = Float(IOHIDEventGetFloatValue(event, base | 2))

        let vec = Vec3(x: x, y: y, z: z)
        let mag = vec.magnitude
        if mag > peakMag { peakMag = mag; peakVec = vec }
        if sampleCounter % 500 == 0 {
            log.debug("entity:AccelSample n=\(sampleCounter) cur=\(String(format: "%.3f", mag)) peak=\(String(format: "%.3f", peakMag)) peakVec=\(peakVec)")
            peakMag = 0
        }
        guard mag > magnitudeMin && mag < magnitudeMax else { return }

        continuation.yield(vec)
    }
}
