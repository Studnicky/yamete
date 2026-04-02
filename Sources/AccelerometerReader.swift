import Foundation
import IOKit.hid

// Reads the BMI286 (Bosch) accelerometer via IOHIDManager.
// Device: AppleSPUHIDDriver, page 0xFF00, usage 0x03, Transport=SPU
//
// Report format (22 bytes, confirmed via diagnostic):
//   [0-1]  uint16 LE  — sample counter (not acceleration)
//   [2-5]  4 bytes    — zeros / padding
//   [6-7]  int16 LE   — accel X
//   [8-9]  int16 LE   — accel Y
//   [10-11] int16 LE  — accel Z
//   [12+]  gyro + other fields
//
// Scale: 1/16384 per LSB (BMI286 ±2g default range)
//
// Thread safety: manages its own HID thread internally. Public API (start/stop)
// is called from MainActor. Callbacks are dispatched to MainActor before invocation.

private let log = AppLog(category: "Accelerometer")

final class AccelerometerReader: @unchecked Sendable {
    private let pageAccel:  UInt32 = 0xFF00
    private let usageAccel: UInt32 = 0x0003
    private let accelOffset = 6

    private let decimationFactor = 2
    private var sampleCounter = 0
    private let scale: Float = 1.0 / 16384.0

    private var manager: IOHIDManager?
    private var accelDevice: IOHIDDevice?
    private var running = false
    private var generation = 0

    var onSample: (@Sendable (Vec3) -> Void)?
    var onError:  (@Sendable (String) -> Void)?

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let gen = generation
        log.info("activity:SensorReading wasStartedBy agent:AccelerometerReader")
        let t = Thread { [weak self] in self?.runLoop(generation: gen) }
        t.name = "com.yamete.accelerometer"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        running = false
        log.info("activity:SensorReading wasEndedBy agent:AccelerometerReader")
    }

    private func runLoop(generation gen: Int) {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: pageAccel,
            kIOHIDDeviceUsageKey     as String: usageAccel,
            kIOHIDTransportKey       as String: "SPU"
        ]
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)

        let selfPtr = Unmanaged.passRetained(self)

        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let ctx = context else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()
            let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
            log.info("entity:AccelDevice wasAssociatedWith agent:AccelerometerReader serial=\(serial)")
            reader.accelDevice = device
            IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, 10000 as CFNumber)
        }, selfPtr.toOpaque())

        IOHIDManagerRegisterInputReportCallback(m, { context, _, sender, _, _, report, reportLen in
            guard let ctx = context, let sender else { return }
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()

            guard let dev = reader.accelDevice,
                  Unmanaged.passUnretained(dev).toOpaque() == sender else { return }
            guard reportLen >= reader.accelOffset + 6 else { return }

            reader.handleReport(report: report)
        }, selfPtr.toOpaque())

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))

        if result != kIOReturnSuccess {
            let userMsg: String
            if result == kIOReturnNotPermitted {
                log.error("activity:SensorReading wasInvalidatedBy entity:PermissionDenial")
                userMsg = "Motion sensor access denied — grant Input Monitoring permission in System Settings > Privacy & Security."
            } else {
                let code = String(format: "0x%08X", result)
                log.error("activity:SensorReading wasInvalidatedBy entity:IOKitError code=\(code)")
                userMsg = "Accelerometer unavailable (IOKit error \(code)). This Mac may not have a compatible motion sensor."
            }
            let callback = onError
            DispatchQueue.main.async { callback?(userMsg) }
            selfPtr.release()
            return
        }

        let errorCallback = onError
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.generation == gen, self.accelDevice == nil else { return }
            log.warning("entity:AccelDevice wasInvalidatedBy activity:DeviceDiscovery — no compatible sensor found")
            errorCallback?("No accelerometer found — this Mac may not have a compatible motion sensor.")
        }

        while running {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)
        }

        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        selfPtr.release()
    }

    private func handleReport(report: UnsafeMutablePointer<UInt8>) {
        sampleCounter += 1
        guard sampleCounter % decimationFactor == 0 else { return }

        let o = accelOffset
        let x = Int16(bitPattern: UInt16(report[o])   | UInt16(report[o+1]) << 8)
        let y = Int16(bitPattern: UInt16(report[o+2]) | UInt16(report[o+3]) << 8)
        let z = Int16(bitPattern: UInt16(report[o+4]) | UInt16(report[o+5]) << 8)

        let vec = Vec3(x: Float(x) * scale,
                       y: Float(y) * scale,
                       z: Float(z) * scale)

        let mag = vec.magnitude
        guard mag > 0.3 && mag < 4.0 else { return }

        let callback = onSample
        DispatchQueue.main.async { callback?(vec) }
    }
}
