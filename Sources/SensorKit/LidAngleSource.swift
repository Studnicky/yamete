#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid
import os

// MARK: - LidAngleSource — direct-publish reaction source for lid hinge angle
//
// Apple ships hinge angle on a dedicated HID device, NOT on the SPU
// IMU stream. Two independent open-source decoders agree byte-for-byte
// (samhenrigold/LidAngleSensor, deepakness/LidAngle):
//
//   • IOHID match: VendorID 0x05AC, ProductID 0x8104,
//     UsagePage 0x0020 (HID Sensors), Usage 0x008A.
//   • Transport: Feature report, ReportID = 1, fetched on demand via
//     `IOHIDDeviceGetReport(.., kIOHIDReportTypeFeature, 1, ..)`. Not
//     an Input Report stream — there is no callback, just a poll.
//   • Layout: `[reportID, angle_lo, angle_hi]` (length ≥ 3).
//   • Decode: `UInt16 LE` at bytes [1..2], unsigned, **already in whole
//     degrees** — no Int16, no `÷100`, no sign extension.
//   • Range: 0..~135°, 1° resolution. Physical clamshell limit is well
//     under 180° on every shipping MacBook.
//   • Hardware: present on M2 Pro/Max, M3 family, and M4 family across
//     the line. Absent on M1 and M2 Air — `isAvailable` returns false
//     there and the menu toggle hides.
//
// Earlier revisions of this source subscribed to the SPU broker for
// `usagePage 0xFF00 / usage 8` and decoded an `Int16 LE / 100` at byte
// offset 18 of the 22-byte report. That channel was wrong on every
// count — `0xFF00 / usage 3` is accel, `0xFF00 / usage 9` is gyro, and
// the offsets 6/10/14 (3× Int32 LE) consume the entire IMU payload.
// Bytes 18..21 are uninitialized tail. The old decoder produced
// negative-half garbage that drove the slam state machine into a loop;
// the wire format documented above is the actual source of truth.

private let log = AppLog(category: "LidAngleSource")

// MARK: - HID driver seam

/// Abstraction over the dedicated lid-angle HID device. Polled, not
/// pushed — the macOS lid sensor surfaces hinge angle as a Feature
/// Report fetched via `IOHIDDeviceGetReport`. Production wires
/// `RealLidAngleHIDDriver`; tests inject angle traces directly through
/// the source's `_testInjectAngle` seam and pair it with a no-op
/// driver so no IOKit machinery is touched.
public protocol LidAngleHIDDriver: Sendable {
    /// True when a matching lid-angle device is present in the
    /// IORegistry. Cheap — a `IOServiceGetMatchingServices` walk and
    /// an iterator drain.
    var isHardwarePresent: Bool { get }

    /// Read one Feature Report and return the decoded angle in
    /// degrees. Returns `nil` when no device is open or the read
    /// fails (transient — caller polls again).
    func readAngleDeg() -> Double?
}

/// Production driver. Opens an `IOHIDManager` matching the dedicated
/// lid-angle device, retains the first matched device, and answers
/// `readAngleDeg()` by fetching Feature Report 1.
public final class RealLidAngleHIDDriver: LidAngleHIDDriver, @unchecked Sendable {
    private static let vendorID: Int = 0x05AC
    private static let usagePage: Int = 0x0020
    private static let usage: Int = 0x008A
    private static let reportID: CFIndex = 1
    private static let reportSize: Int = 8

    private struct State {
        var manager: IOHIDManager?
        var device: IOHIDDevice?
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    deinit {
        state.withLock { s in
            if let device = s.device {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            if let manager = s.manager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            s.manager = nil
            s.device = nil
        }
    }

    public var isHardwarePresent: Bool {
        // Productive side-effect: matching, opening, and caching the
        // device here also primes `readAngleDeg()` for the lifetime
        // of the driver.
        return state.withLock { s in
            if s.device != nil { return true }
            return Self.resolveAndOpen(into: &s)
        }
    }

    public func readAngleDeg() -> Double? {
        return state.withLock { s in
            // Lazy resolve — caller may invoke `readAngleDeg()` before
            // ever asking `isHardwarePresent`.
            if s.device == nil {
                _ = Self.resolveAndOpen(into: &s)
            }
            guard let device = s.device else { return nil }

            var buffer = [UInt8](repeating: 0, count: Self.reportSize)
            var length: CFIndex = CFIndex(Self.reportSize)
            let result = buffer.withUnsafeMutableBufferPointer { bp -> IOReturn in
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, Self.reportID, bp.baseAddress!, &length)
            }
            guard result == kIOReturnSuccess, length >= 3 else {
                log.debug("activity:HIDGetReport result=\(String(format:"0x%08X", UInt32(bitPattern: result))) length=\(length)")
                return nil
            }
            // UInt16 LE at bytes [1..2]; unsigned; whole degrees.
            let raw = UInt16(buffer[1]) | (UInt16(buffer[2]) << 8)
            return Double(raw)
        }
    }

    /// Build the IOHIDManager (if missing), match on the lid device,
    /// pick the first hit, and open it for Feature-report I/O. Caches
    /// the manager and device on the state struct. Returns true when
    /// a device was successfully opened.
    ///
    /// `IOHIDManagerOpen` opens the manager scope; it does NOT
    /// implicitly open each matched device for I/O. `IOHIDDeviceGetReport`
    /// against an unopened device returns `kIOReturnNotPermitted`
    /// (0xE00002C2) silently, which is the failure mode that surfaced
    /// on first deploy.
    private static func resolveAndOpen(into s: inout State) -> Bool {
        let manager = s.manager ?? makeManager()
        s.manager = manager
        guard let device = firstMatchedDevice(in: manager) else { return false }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            log.warning("entity:LidAngleHIDDriver wasInvalidatedBy activity:DeviceOpen result=\(String(format:"0x%08X", UInt32(bitPattern: openResult)))")
            return false
        }
        s.device = device
        return true
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDDeviceUsagePageKey: usagePage,
            kIOHIDDeviceUsageKey: usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return manager
    }

    private static func firstMatchedDevice(in manager: IOHIDManager) -> IOHIDDevice? {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        return set.first
    }
}

// MARK: - LidAngleSource

/// Direct-publish reaction source over the dedicated lid-angle HID
/// device. Polls Feature Report 1 at a configurable interval and
/// passes the decoded angle through `LidAngleStateMachine` for
/// open/close/slam classification.
public final class LidAngleSource: Sendable {

    public let id = SensorID.lidAngle
    public var name: String {
        NSLocalizedString("sensor_lid_angle", comment: "Lid angle sensor name")
    }

    private let machineConfig: LidAngleStateMachineConfig
    /// Polling interval in microseconds. 33,333 µs ≈ 30 Hz, matching the
    /// reference open-source decoders. `LidAngleStateMachine` smooths over
    /// `smoothingWindowMs` so the exact rate is not load-bearing.
    private let pollIntervalUS: Int
    private let driver: LidAngleHIDDriver

    private struct State {
        var machine: LidAngleStateMachine?
        var bus: ReactionBus?
        var pollTask: Task<Void, Never>?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// Public init. Defaults match the reference decoders (~30 Hz poll)
    /// and `Defaults.lid*` for the state-machine thresholds.
    public convenience init(openThresholdDeg: Double = Defaults.lidOpenThresholdDeg,
                            closedThresholdDeg: Double = Defaults.lidClosedThresholdDeg,
                            slamRateDegPerSec: Double = Defaults.lidSlamRateDegPerSec,
                            smoothingWindowMs: Int = Defaults.lidSmoothingWindowMs,
                            pollIntervalUS: Int = 33_333) {
        let config = LidAngleStateMachineConfig(
            openThresholdDeg: openThresholdDeg,
            closedThresholdDeg: closedThresholdDeg,
            slamRateDegPerSec: slamRateDegPerSec,
            smoothingWindowMs: smoothingWindowMs
        )
        self.init(machineConfig: config,
                  pollIntervalUS: pollIntervalUS,
                  driver: RealLidAngleHIDDriver())
    }

    /// Designated initializer accepting an HID driver injection. Tests
    /// pair this with a no-op driver and drive the state machine via
    /// `_testInjectAngle`; production callers reach the convenience
    /// overload which builds a real driver.
    internal init(machineConfig: LidAngleStateMachineConfig,
                  pollIntervalUS: Int = 33_333,
                  driver: LidAngleHIDDriver) {
        self.machineConfig = machineConfig
        self.pollIntervalUS = pollIntervalUS
        self.driver = driver
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// True when a dedicated lid-angle HID device is matched in the
    /// IORegistry. Returns false on M1 and M2 Air; true on M2 Pro/Max,
    /// M3, and M4 family Macs.
    public var isAvailable: Bool { driver.isHardwarePresent }

    // MARK: - Lifecycle

    public func start(publishingTo bus: ReactionBus) {
        let alreadyRunning = state.withLock { $0.pollTask != nil }
        if alreadyRunning { return }

        let machine = LidAngleStateMachine(config: machineConfig)
        let driver = self.driver
        let intervalNs = UInt64(pollIntervalUS) * 1_000

        // One-shot probe: emit the first successful angle read so the
        // log proves the device decode works on this host. Without
        // this, a host where the lid never moves leaves the source
        // silent — indistinguishable from a broken decoder.
        if let probe = driver.readAngleDeg() {
            log.info("activity:Probe wasGeneratedBy entity:LidAngleSource angle=\(String(format: "%.1f", probe))°")
        } else {
            log.warning("entity:LidAngleSource wasInvalidatedBy activity:Probe — initial read returned nil")
        }

        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                if let angle = driver.readAngleDeg() {
                    self?.handleAngle(angle, timestamp: Date())
                }
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }

        state.withLock { s in
            s.machine = machine
            s.bus = bus
            s.pollTask = task
        }
        log.info("entity:LidAngleSource wasGeneratedBy activity:Start pollHz=\(String(format: "%.0f", 1_000_000.0 / Double(pollIntervalUS)))")
    }

    public func stop() {
        let task: Task<Void, Never>? = state.withLock { s in
            let t = s.pollTask
            s.pollTask = nil
            s.machine = nil
            s.bus = nil
            return t
        }
        if let task {
            task.cancel()
            log.info("entity:LidAngleSource wasInvalidatedBy activity:Stop")
        }
    }

    // MARK: - Sample handling

    /// Run one decoded angle sample through the state machine and
    /// publish any emitted transition onto the bus. Same publish
    /// pattern as the prior SPU-broker implementation — resolve
    /// under-lock, publish outside the lock so we never await with
    /// an unfair lock held.
    internal func handleAngle(_ angleDeg: Double, timestamp: Date) {
        // Defensive sanity gate. Even with the correct decoder, a
        // misbehaving device or an unmapped variant could surface
        // out-of-range values; the state machine assumes physical
        // angles, so reject anything outside the clamshell envelope.
        guard (0...180).contains(angleDeg) else { return }

        struct Pending {
            let bus: ReactionBus
            let event: LidEvent
        }
        let pending: Pending? = state.withLock { s in
            guard let machine = s.machine, let bus = s.bus else { return nil }
            guard let event = machine.process(angleDeg: angleDeg, timestamp: timestamp) else { return nil }
            return Pending(bus: bus, event: event)
        }

        if let pending {
            let reaction: Reaction
            switch pending.event {
            case .opened:  reaction = .lidOpened
            case .closed:  reaction = .lidClosed
            case .slammed: reaction = .lidSlammed
            }
            log.info("activity:Publish wasGeneratedBy entity:LidAngleSource event=\(pending.event) angle=\(String(format: "%.1f", angleDeg))°")
            Task { await pending.bus.publish(reaction) }
        }
    }

    // MARK: - Test seams

    #if DEBUG
    /// Inject a single decoded angle, bypassing the HID driver.
    /// Drives the state machine directly so cells can author
    /// deterministic angle traces with no IOKit involvement.
    internal func _testInjectAngle(_ angleDeg: Double, at timestamp: Date) {
        handleAngle(angleDeg, timestamp: timestamp)
    }

    /// True while the polling task is alive. Replaces the prior
    /// broker subscription-count assertion in lifecycle cells.
    internal var _testIsRunning: Bool {
        state.withLock { $0.pollTask != nil }
    }
    #endif
}

// MARK: - Test no-op driver

#if DEBUG
/// Driver that reports no hardware and never returns a sample. Tests
/// pair this with `_testInjectAngle` so the source's state machine
/// runs deterministically without IOKit traffic.
public final class NoOpLidAngleHIDDriver: LidAngleHIDDriver, @unchecked Sendable {
    private let presenceState: OSAllocatedUnfairLock<Bool>

    public init(isPresent: Bool = false) {
        self.presenceState = OSAllocatedUnfairLock(initialState: isPresent)
    }

    public var isHardwarePresent: Bool { presenceState.withLock { $0 } }
    public func _setPresent(_ value: Bool) { presenceState.withLock { $0 = value } }
    public func readAngleDeg() -> Double? { nil }
}
#endif
