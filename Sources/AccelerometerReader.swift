import Foundation
import IOKit.hid

// MARK: - SPUAccelerometerAdapter

/// Reads the BMI286 (Bosch) accelerometer via IOHIDManager on Apple Silicon Macs.
///
/// Device: AppleSPUHIDDriver, page 0xFF00, usage 0x03, Transport=SPU
///
/// Report format (22 bytes):
///   [0-1]  uint16 LE  — sample counter (not acceleration)
///   [2-5]  4 bytes    — padding
///   [6-7]  int16 LE   — accel X
///   [8-9]  int16 LE   — accel Y
///   [10-11] int16 LE  — accel Z
///   [12+]  gyro + other fields
///
/// Thread model: IOKit requires a dedicated CFRunLoop thread for HID callbacks.
/// This adapter bridges that thread into an `AsyncThrowingStream<Vec3>` via a
/// continuation. All cross-thread state is eliminated:
///   - The HID thread owns all mutable sensor state
///   - `Thread.cancel()` provides the cooperative stop signal (no locks)
///   - `continuation.yield()` provides the thread-safe handoff to the consumer
///   - `Unmanaged` is isolated to a small `HIDCallbackContext` (IOKit C-API requirement)

private let log = AppLog(category: "SPUAccelerometer")

final class SPUAccelerometerAdapter: SensorAdapter, @unchecked Sendable {

    let name = "Apple SPU Accelerometer"

    // BMI286 sensor constants
    private let pageAccel:  UInt32 = 0xFF00
    private let usageAccel: UInt32 = 0x0003
    private let accelOffset = 6
    private let reportMinLength = 12
    private let decimationFactor = 2
    private let scale: Float = 1.0 / 16384.0   // ±2g range: 16384 LSB/g
    private let magnitudeMin: Float = 0.3       // Below: sensor noise
    private let magnitudeMax: Float = 4.0       // Above: corrupt data

    // MARK: - SensorAdapter

    var isAvailable: Bool {
        let matching: [String: Any] = [
            "PrimaryUsagePage": pageAccel,
            "PrimaryUsage": usageAccel
        ]
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)
        let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>
        return devices != nil && !devices!.isEmpty
    }

    func samples() -> AsyncThrowingStream<Vec3, Error> {
        let config = HIDConfig(
            pageAccel: pageAccel,
            usageAccel: usageAccel,
            accelOffset: accelOffset,
            reportMinLength: reportMinLength,
            decimationFactor: decimationFactor,
            scale: scale,
            magnitudeMin: magnitudeMin,
            magnitudeMax: magnitudeMax
        )

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Vec3.self)

        let thread = Thread { Self.hidRunLoop(continuation: continuation, config: config) }
        thread.name = "com.yamete.spu-accelerometer"
        thread.qualityOfService = .userInteractive

        let threadRef = ThreadRef(thread)
        continuation.onTermination = { @Sendable _ in threadRef.cancel() }
        thread.start()

        return stream
    }

    // MARK: - HID Thread (static — no self needed)

    /// Runs on a dedicated thread. Owns all mutable HID state. Communicates
    /// with the consumer exclusively through the continuation.
    private static func hidRunLoop(continuation: AsyncThrowingStream<Vec3, Error>.Continuation,
                                   config: HIDConfig) {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: config.pageAccel,
            kIOHIDDeviceUsageKey     as String: config.usageAccel,
            kIOHIDTransportKey       as String: "SPU"
        ]
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)

        // Context bridges Swift state into IOKit C callbacks.
        // passRetained is balanced by exactly one release in the defer block.
        let ctx = HIDCallbackContext(continuation: continuation, config: config)
        let ctxPtr = Unmanaged.passRetained(ctx)

        defer {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
            ctxPtr.release()
            continuation.finish()
        }

        // Device matching: store the device reference when IOKit finds the accelerometer
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let context else { return }
            let ctx = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()
            let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
            log.info("entity:AccelDevice wasAssociatedWith agent:SPUAccelerometerAdapter serial=\(serial)")
            ctx.accelDevice = device
            IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, 10000 as CFNumber)
        }, ctxPtr.toOpaque())

        // Report callback: parse and yield normalized Vec3
        IOHIDManagerRegisterInputReportCallback(m, { context, _, sender, _, _, report, reportLen in
            guard let context, let sender else { return }
            let ctx = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue()

            guard let dev = ctx.accelDevice,
                  Unmanaged.passUnretained(dev).toOpaque() == sender else { return }
            guard reportLen >= ctx.config.reportMinLength else { return }

            ctx.handleReport(report)
        }, ctxPtr.toOpaque())

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))

        if result != kIOReturnSuccess {
            if result == kIOReturnNotPermitted {
                continuation.finish(throwing: SensorError.permissionDenied)
            } else {
                let code = String(format: "0x%08X", result)
                continuation.finish(throwing: SensorError.ioKitError(code))
            }
            return
        }

        // Timeout: if no device matched within 2 seconds, finish with error
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            guard !Thread.current.isCancelled, ctx.accelDevice == nil else { return }
            continuation.finish(throwing: SensorError.deviceNotFound)
        }
        IOHIDEventSystemClientRegisterEventCallback(c, eventCallback, nil, selfPtr.toOpaque())

        // Run until the consuming task cancels us (Thread.cancel sets isCancelled)
        while !Thread.current.isCancelled {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false)
        }
        log.info("activity:SensorReading wasEndedBy agent:SPUAccelerometerAdapter")
    }
}

// MARK: - Thread wrapper

/// Sendable wrapper for Thread (which Apple hasn't marked Sendable).
/// Thread.cancel() is documented as thread-safe.
private final class ThreadRef: @unchecked Sendable {
    private let thread: Thread
    init(_ thread: Thread) { self.thread = thread }
    func cancel() { thread.cancel() }
}

// MARK: - HID callback bridge

/// Immutable sensor configuration passed into the HID thread.
private struct HIDConfig: Sendable {
    let pageAccel:  UInt32
    let usageAccel: UInt32
    let accelOffset: Int
    let reportMinLength: Int
    let decimationFactor: Int
    let scale: Float
    let magnitudeMin: Float
    let magnitudeMax: Float
}

/// Mutable state owned exclusively by the HID thread. Bridges IOKit C callbacks
/// to the AsyncThrowingStream continuation. The only `Unmanaged` usage in the codebase
/// lives here — required by IOKit's C-function-pointer callback API.
private final class HIDCallbackContext: @unchecked Sendable {
    let continuation: AsyncThrowingStream<Vec3, Error>.Continuation
    let config: HIDConfig

    // HID-thread-only state — no synchronization needed
    var accelDevice: IOHIDDevice?
    var sampleCounter = 0

    init(continuation: AsyncThrowingStream<Vec3, Error>.Continuation, config: HIDConfig) {
        self.continuation = continuation
        self.config = config
    }

    func handleReport(_ report: UnsafeMutablePointer<UInt8>) {
        sampleCounter += 1
        guard sampleCounter % config.decimationFactor == 0 else { return }

        let o = config.accelOffset
        let x = Int16(bitPattern: UInt16(report[o])   | UInt16(report[o+1]) << 8)
        let y = Int16(bitPattern: UInt16(report[o+2]) | UInt16(report[o+3]) << 8)
        let z = Int16(bitPattern: UInt16(report[o+4]) | UInt16(report[o+5]) << 8)

        let vec = Vec3(x: Float(x) * config.scale,
                       y: Float(y) * config.scale,
                       z: Float(z) * config.scale)

        let vec = Vec3(x: x, y: y, z: z)
        let mag = vec.magnitude
        guard mag > config.magnitudeMin && mag < config.magnitudeMax else { return }

        continuation.yield(vec)
    }
}
