#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import os

// MARK: - LidAngleSource — direct-publish reaction source for lid hinge angle
//
// Subscribes to the SPU HID broker (`AppleSPUDevice.shared`) for
// usagePage 0xFF00 / usage 8 (Apple's lid-angle channel). The broker
// fans every report out to every active subscriber irrespective of
// usage tuple — see the broker file header for the rationale.
// Subscribers decode their own bytes from their own offsets.
//
// Wire-format assumption (UNVERIFIED — see verification note below):
//   The internal SPU report buffer is 22 bytes. The accelerometer
//   reader reads Int32 LE axes at byte offsets 6 / 10 / 14 (4 bytes
//   each), and the gyro reader reuses those same offsets. That leaves
//   bytes 18..21 (4 bytes) as the next available slot in a 22-byte
//   report. This source decodes the lid hinge angle as Int16 LE at
//   byte offset 18, divided by 100 to yield degrees, on the assumption
//   that:
//     • The lid-angle channel emits a single scalar (no XYZ triple).
//     • Apple's HID descriptor packs that scalar in the unused tail
//       slot of the shared report layout, with a fixed-point
//       Int16-by-100 encoding (matches the BMI286 register-file
//       angle precision of ±327.67° / 0.01° resolution).
//   This assumption is gated by:
//     • The `lid-decode-byte-offset` mutation entry under
//       `Tests/Mutation/mutation-catalog.json` (changes offset 18 to
//       0; decoded angle collapses to zero degrees, no transitions
//       fire, the matrix cell catches it).
//     • A hardware integration test on real BMI286 silicon will
//       surface zero-magnitude or saturated readings if Apple's wire
//       format differs in production. Revisit the offset and scaling
//       at that point — the test seam (`_testInjectReport`) lets us
//       update the decoder without churning the test suite.
//
// Reaction emission: state-machine transitions surface as
// `Reaction.lidOpened`, `.lidClosed`, or `.lidSlammed` direct
// publications onto the bus. The state machine inherently dedupes
// emissions (a state cannot re-enter itself without an intervening
// transition), so no per-source debounce window is needed beyond the
// state model itself.

private let log = AppLog(category: "LidAngleSource")

/// Direct-publish reaction source for the BMI286 lid hinge angle.
/// Does NOT participate in fusion — emits `.lidOpened`, `.lidClosed`,
/// `.lidSlammed` directly via the reaction bus, mirroring the
/// discrete-stimulus pattern in `GyroscopeSource`. Not `@MainActor`
/// because the report handler runs on the broker's HID worker thread
/// and must not hop the main actor per sample.
public final class LidAngleSource: Sendable {

    public let id = SensorID.lidAngle
    /// Localized display name. Resolved at access time via
    /// `NSLocalizedString` so the menu UI surfaces the user's
    /// preferred-locale string. The source's `id` (raw "lidAngle")
    /// remains the persisted identifier — only the name varies.
    public var name: String {
        NSLocalizedString("sensor_lid_angle", comment: "Lid angle sensor name")
    }

    private let machineConfig: LidAngleStateMachineConfig
    private let reportIntervalUS: Int

    /// Broker the source subscribes to. Production callers share the
    /// singleton; tests inject a private broker wired with a mock kernel
    /// driver.
    internal let broker: AppleSPUDevice

    /// Lock-protected subscription / detector state. The state machine
    /// is rebuilt on every `start()` so a stop / start cycle does not
    /// retain stale lid-state.
    private struct State {
        var token: SPUSubscription?
        var machine: LidAngleStateMachine?
        var bus: ReactionBus?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// Public init. Defaults match `Defaults.lid*`.
    public convenience init(openThresholdDeg: Double = Defaults.lidOpenThresholdDeg,
                            closedThresholdDeg: Double = Defaults.lidClosedThresholdDeg,
                            slamRateDegPerSec: Double = Defaults.lidSlamRateDegPerSec,
                            smoothingWindowMs: Int = Defaults.lidSmoothingWindowMs,
                            reportIntervalUS: Int = 10000) {
        let config = LidAngleStateMachineConfig(
            openThresholdDeg: openThresholdDeg,
            closedThresholdDeg: closedThresholdDeg,
            slamRateDegPerSec: slamRateDegPerSec,
            smoothingWindowMs: smoothingWindowMs
        )
        self.init(machineConfig: config,
                  reportIntervalUS: reportIntervalUS,
                  broker: AppleSPUDevice.shared)
    }

    /// Test-overload init: caller supplies a kernel driver and the
    /// source builds a private broker wired with the same driver.
    /// Mirrors `GyroscopeSource(kernelDriver:)` — cells inject a
    /// `MockSPUKernelDriver` and observe every IOKit call routed
    /// through the mock without touching the production singleton.
    internal convenience init(machineConfig: LidAngleStateMachineConfig,
                              reportIntervalUS: Int = 10000,
                              kernelDriver: SPUKernelDriver) {
        self.init(
            machineConfig: machineConfig,
            reportIntervalUS: reportIntervalUS,
            broker: AppleSPUDevice(driver: kernelDriver)
        )
    }

    /// Designated initializer accepting a broker injection. Public
    /// callers reach the convenience overload which builds a real
    /// driver and uses the singleton; tests use the kernel-driver
    /// overload (above) which builds a private broker wired with the
    /// test driver.
    internal init(machineConfig: LidAngleStateMachineConfig,
                  reportIntervalUS: Int = 10000,
                  broker: AppleSPUDevice) {
        self.machineConfig = machineConfig
        self.reportIntervalUS = reportIntervalUS
        self.broker = broker
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// True when SPU HID hardware is present in the IORegistry.
    /// Mirrors `GyroscopeSource.isAvailable` — surface parity, no
    /// per-source override.
    public var isAvailable: Bool {
        AppleSPUDevice.isHardwarePresent()
    }

    // MARK: - Lifecycle

    /// Subscribe to the broker and begin publishing lid Reactions
    /// onto the supplied bus on detected transitions. Idempotent —
    /// calling while already started is a no-op.
    public func start(publishingTo bus: ReactionBus) {
        let alreadyRunning = state.withLock { s -> Bool in
            return s.token != nil
        }
        if alreadyRunning { return }

        let machine = LidAngleStateMachine(config: machineConfig)

        state.withLock { s in
            s.machine = machine
            s.bus = bus
        }

        let token = broker.subscribe(
            usagePage: 0xFF00,
            usage: 8,
            dispatch: .lid,
            reportIntervalUS: reportIntervalUS
        ) { [weak self] report in
            self?.handleReport(bytes: report.bytes, length: report.length, timestamp: report.timestamp)
        }

        state.withLock { s in
            s.token = token
        }

        if token == nil {
            log.warning("entity:LidAngleSource wasInvalidatedBy activity:Subscribe — broker refused open")
        } else {
            log.info("entity:LidAngleSource wasGeneratedBy activity:Start")
        }
    }

    /// Cancel the broker subscription and tear down internal state.
    /// Idempotent.
    public func stop() {
        let token = state.withLock { s -> SPUSubscription? in
            let t = s.token
            s.token = nil
            s.machine = nil
            s.bus = nil
            return t
        }
        if let token {
            broker.unsubscribe(token)
            log.info("entity:LidAngleSource wasInvalidatedBy activity:Stop")
        }
    }

    // MARK: - Report handling

    /// Decode one HID report buffer, run it through the state
    /// machine, and publish on a transition. The state machine
    /// inherently dedupes — no per-source debounce window.
    ///
    /// Exposed `internal` so the matrix mutation cells in
    /// `MatrixLidAngleSource_Tests` can drive the gate set with
    /// synthesised payloads via the `_testInjectReport` seam.
    internal func handleReport(bytes: UnsafePointer<UInt8>, length: Int, timestamp: Date) {
        // Length floor — same minimum as the accel reader. Lid angle
        // sits at byte offset 18 (Int16 LE / 100 → degrees), so we
        // need at least 20 bytes. The accel min (18) is too tight;
        // gate explicitly.
        guard length >= 20 else { return }

        // Int16 LE at byte offset 18 is NOT 2-byte aligned in
        // general; `loadUnaligned` is the sanctioned API.
        let raw = UnsafeRawPointer(bytes)
        let rawAngle = raw.loadUnaligned(fromByteOffset: 18, as: Int16.self)

        // Fixed-point decode: Int16 LE / 100 → degrees. ±327.67°
        // resolution at 0.01° step matches the BMI286 register-file
        // precision for hinge sensors.
        let angleDeg = Double(rawAngle) / 100.0

        // Resolve the publish decision under the lock, then perform
        // bus.publish() outside the lock — `bus.publish` is async and
        // we must not hold an unfair lock across an await.
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

    /// Test seam — synthesize a report directly. Lets cells drive
    /// the state machine with deterministic angle traces without
    /// touching the broker's IOKit machinery.
    #if DEBUG
    internal func _testInjectReport(bytes: UnsafePointer<UInt8>, length: Int, timestamp: Date) {
        handleReport(bytes: bytes, length: length, timestamp: timestamp)
    }

    /// Test seam — synthesize an angle directly without composing the
    /// raw byte buffer. Equivalent to `_testInjectReport` of a payload
    /// whose offset-18 Int16 decodes to `angleDeg * 100`.
    internal func _testInjectAngle(_ angleDeg: Double, at timestamp: Date) {
        var rawAngle = Int16(max(-327.67, min(327.67, angleDeg)) * 100).littleEndian
        withUnsafeMutableBytes(of: &rawAngle) { _ in }
        let length = 22
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: length)
        withUnsafeBytes(of: rawAngle) { bytes in
            let p = bytes.bindMemory(to: UInt8.self).baseAddress!
            buf[18] = p[0]
            buf[19] = p[1]
        }
        handleReport(bytes: UnsafePointer(buf), length: length, timestamp: timestamp)
    }
    #endif
}
