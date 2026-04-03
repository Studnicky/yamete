import Foundation
import IOKit.hid

// Reads the BMI286 (Bosch) accelerometer via IOHIDEventSystemClient.
//
// On macOS 15+, the SPU accelerometer is a motion-restricted HID event service.
// Raw IOHIDManager reports are not delivered for restricted services. Instead,
// we use IOHIDEventSystemClient (type 1/monitor) which:
//   1. Matches the service by UsagePage=0xFF00, Usage=3
//   2. Sets ReportInterval on the service to activate the sensor
//   3. Receives structured IOHIDEvent callbacks with acceleration vectors
//
// Thread safety: callbacks arrive on a private dispatch queue. Samples are
// forwarded to MainActor via DispatchQueue.main.

private let log = AppLog(category: "Accelerometer")

// MARK: - IOHIDEventSystem bindings (private but stable macOS API)

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

// MARK: - AccelerometerReader

final class AccelerometerReader: @unchecked Sendable {
    // IOHIDEventSystem client type: 1 = monitor (can read events from services)
    private let clientType: Int32 = 1

    // Accelerometer service matching
    private let pageAccel:  Int = 0xFF00
    private let usageAccel: Int = 3

    // Sensor activation: report interval in microseconds (10000 = 10ms = 100Hz)
    private let reportIntervalUS: Int = 10000

    // IOHIDEvent type for accelerometer (empirically confirmed on macOS 15)
    private let accelEventType: Int32 = 13

    private let decimationFactor = 2
    private var sampleCounter = 0

    private var client: IOHIDEventSystemClientRef?
    private var queue: DispatchQueue?
    private var running = false

    var onSample: (@Sendable (Vec3) -> Void)?
    var onError:  (@Sendable (String) -> Void)?

    func start() {
        guard !running else { return }

        guard let c = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, clientType, nil) else {
            log.error("activity:SensorReading wasInvalidatedBy entity:EventSystemClient — failed to create")
            let callback = onError
            callback?("Failed to create HID event system client. This Mac may not support accelerometer access.")
            return
        }
        client = c

        let matching: [String: Any] = [
            "PrimaryUsagePage": pageAccel,
            "PrimaryUsage": usageAccel
        ]
        IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)

        // Activate the sensor by setting ReportInterval on matched services
        var activated = false
        if let services = IOHIDEventSystemClientCopyServices(c) {
            for i in 0..<CFArrayGetCount(services) {
                let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
                let transport = IOHIDServiceClientCopyProperty(svc, "Transport" as CFString)
                if "\(transport ?? ("" as CFString))" == "SPU" {
                    IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, reportIntervalUS as CFNumber)
                    activated = true
                    let serial = IOHIDServiceClientCopyProperty(svc, "SerialNumber" as CFString) ?? ("" as CFString)
                    log.info("entity:AccelDevice wasAssociatedWith agent:AccelerometerReader serial=\(serial) interval=\(reportIntervalUS)us")
                }
            }
        }

        if !activated {
            log.warning("entity:AccelDevice wasInvalidatedBy activity:ServiceDiscovery — no SPU accelerometer found")
            let callback = onError
            callback?("No accelerometer found — this Mac may not have a compatible motion sensor.")
            return
        }

        // Register event callback
        let selfPtr = Unmanaged.passRetained(self)
        let eventCallback: IOHIDEventCallback = { _, refcon, _, event in
            guard let refcon else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(refcon).takeUnretainedValue()
            reader.handleEvent(event)
        }
        IOHIDEventSystemClientRegisterEventCallback(c, eventCallback, nil, selfPtr.toOpaque())

        // Schedule on a dedicated high-priority queue
        let q = DispatchQueue(label: "com.yamete.accelerometer", qos: .userInteractive)
        queue = q
        IOHIDEventSystemClientScheduleWithDispatchQueue(c, q)

        running = true
        log.info("activity:SensorReading wasStartedBy agent:AccelerometerReader")
    }

    func stop() {
        guard running else { return }
        running = false

        // Deactivate sensor
        if let c = client, let services = IOHIDEventSystemClientCopyServices(c) {
            for i in 0..<CFArrayGetCount(services) {
                let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
                IOHIDServiceClientSetProperty(svc, "ReportInterval" as CFString, 0 as CFNumber)
            }
        }
        client = nil
        queue = nil
        log.info("activity:SensorReading wasEndedBy agent:AccelerometerReader")
    }

    private func handleEvent(_ event: IOHIDEventRef) {
        guard running else { return }

        let eventType = IOHIDEventGetType(event)
        guard eventType == accelEventType else { return }

        sampleCounter += 1
        guard sampleCounter % decimationFactor == 0 else { return }

        // Extract acceleration: field = (eventType << 16) | fieldIndex
        let base = accelEventType << 16
        let x = Float(IOHIDEventGetFloatValue(event, base | 0))
        let y = Float(IOHIDEventGetFloatValue(event, base | 1))
        let z = Float(IOHIDEventGetFloatValue(event, base | 2))

        let vec = Vec3(x: x, y: y, z: z)
        let mag = vec.magnitude
        guard mag > 0.3 && mag < 4.0 else { return }

        let callback = onSample
        DispatchQueue.main.async { callback?(vec) }
    }
}
