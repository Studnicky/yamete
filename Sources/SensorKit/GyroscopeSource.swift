#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import os

// MARK: - GyroscopeSource — direct-publish reaction source on top of AppleSPUDevice
//
// Subscribes to the SPU HID broker (`AppleSPUDevice.shared`) for usagePage
// 0xFF00 / usage 9. The broker fans every report out to every active
// subscriber irrespective of usage tuple — see the broker file header for
// the rationale. Subscribers decode their own bytes from their own
// offsets.
//
// Wire-format assumption (DOCUMENTED):
//   The BMI286 SPU HID device emits one report layout for the accelerometer
//   subscriber-channel and may emit a parallel layout for the gyro
//   subscriber-channel. The accelerometer reads Int32 LE axes at byte
//   offsets 6/10/14, divide by 65536 → g-force. The gyroscope source
//   uses the SAME offsets, decoded as Int32 LE / 65536 → deg/s, on the
//   assumption that Apple's HID descriptor mirrors the well-known BMI286
//   register file (which packs accel-X/Y/Z and gyro-X/Y/Z as paired Int16
//   triples but is exposed via the SPU bridge as Int32 to match the
//   accel-channel framing). This assumption is gated by:
//     • The same `magnitudeMin` / `magnitudeMax` sanity bracket that
//       `AccelerometerReader` uses, but recalibrated for deg/s.
//     • The `gyro-decode-byte-offset` mutation entry under
//       `Tests/Mutation/mutation-catalog.json`, which CHANGES one of the
//       offsets to a wrong value and asserts the matrix cell catches the
//       deviation. If Apple's wire format differs in production, the
//       hardware integration test (running on real BMI286 silicon) will
//       surface zero-magnitude or saturated readings; revisit the
//       offsets at that point.
//
// Reaction emission: on a confirmed spike the source publishes
// `Reaction.gyroSpike` to the `ReactionBus` it was started against.
// `ReactionsConfig.gyroDebounce = 0.5s` gates publish rate per source.

private let log = AppLog(category: "Gyroscope")

/// Direct-publish reaction source for the BMI286 gyroscope. Does NOT
/// participate in fusion — emits `Reaction.gyroSpike` directly via the
/// reaction bus, mirroring the discrete-stimulus pattern in
/// `TrackpadActivitySource`. Not `@MainActor` because the report handler
/// runs on the broker's HID worker thread and must not hop the main actor
/// per sample.
public final class GyroscopeSource: Sendable {

    public let id = SensorID.gyroscope
    public let name = "Gyroscope"

    private let detectorConfig: GyroDetectorConfig
    private let reportIntervalUS: Int

    /// Broker the source subscribes to. Production callers share the
    /// singleton; tests inject a private broker wired with a mock kernel
    /// driver.
    internal let broker: AppleSPUDevice

    /// Lock-protected subscription / detector state. The detector is
    /// rebuilt on every `start()` so a stop/start cycle does not retain
    /// stale window state.
    private struct State {
        var token: SPUSubscription?
        var detector: GyroDetector?
        var bus: ReactionBus?
        var lastFiredAt: Date?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// Public init (deg/s units).
    public convenience init(spikeThreshold: Double = Defaults.gyroSpikeThreshold,
                            confirmations: Int = Defaults.gyroConfirmations,
                            warmupSamples: Int = Defaults.gyroWarmup,
                            riseRate: Double = Defaults.gyroRiseRate,
                            crestFactor: Double = Defaults.gyroCrestFactor,
                            reportIntervalUS: Int = 10000) {
        let config = GyroDetectorConfig.gyroscope(
            spikeThreshold: Float(spikeThreshold),
            riseRate: Float(riseRate),
            crestFactor: Float(crestFactor),
            confirmations: confirmations,
            warmupSamples: warmupSamples
        )
        self.init(detectorConfig: config, reportIntervalUS: reportIntervalUS, broker: AppleSPUDevice.shared)
    }

    /// Test-overload init: caller supplies a kernel driver and the source
    /// builds a private broker wired with the same driver. Mirrors
    /// `AccelerometerSource(kernelDriver:)` — cells inject a
    /// `MockSPUKernelDriver` and observe every IOKit call routed through
    /// the mock without touching the production singleton.
    internal convenience init(detectorConfig: GyroDetectorConfig,
                              reportIntervalUS: Int = 10000,
                              kernelDriver: SPUKernelDriver) {
        self.init(
            detectorConfig: detectorConfig,
            reportIntervalUS: reportIntervalUS,
            broker: AppleSPUDevice(driver: kernelDriver)
        )
    }

    /// Designated initializer accepting a broker injection. Public
    /// callers reach the convenience overload which builds a real driver
    /// and uses the singleton; tests use the kernel-driver overload
    /// (above) which builds a private broker wired with the test driver.
    internal init(detectorConfig: GyroDetectorConfig,
                  reportIntervalUS: Int = 10000,
                  broker: AppleSPUDevice) {
        self.detectorConfig = detectorConfig
        self.reportIntervalUS = reportIntervalUS
        self.broker = broker
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// True when SPU HID hardware is present in the IORegistry. Mirrors
    /// `AccelerometerSource.isAvailable` for the Direct build path: hardware
    /// presence alone is sufficient because the broker handles activation
    /// transparently. Tests can assert this property mirrors the broker's
    /// `isHardwarePresent` static.
    public var isAvailable: Bool {
        AppleSPUDevice.isHardwarePresent()
    }

    // MARK: - Lifecycle

    /// Subscribe to the broker and begin publishing `.gyroSpike` reactions
    /// onto the supplied bus on detected spikes. Idempotent — calling
    /// while already started is a no-op.
    public func start(publishingTo bus: ReactionBus) {
        let alreadyRunning = state.withLock { s -> Bool in
            return s.token != nil
        }
        if alreadyRunning { return }

        let detector = GyroDetector(config: detectorConfig)

        state.withLock { s in
            s.detector = detector
            s.bus = bus
            s.lastFiredAt = nil
        }

        // Subscribe to the broker. The handler captures self weakly so
        // the source's deinit does not require a forced unsubscribe; the
        // handler bails out if `self` has been released.
        let token = broker.subscribe(
            usagePage: 0xFF00,
            usage: 9,
            dispatch: .gyro,
            reportIntervalUS: reportIntervalUS
        ) { [weak self] report in
            self?.handleReport(bytes: report.bytes, length: report.length, timestamp: report.timestamp)
        }

        state.withLock { s in
            s.token = token
        }

        if token == nil {
            log.warning("entity:GyroscopeSource wasInvalidatedBy activity:Subscribe — broker refused open")
        } else {
            log.info("entity:GyroscopeSource wasGeneratedBy activity:Start")
        }
    }

    /// Cancel the broker subscription and tear down internal state.
    /// Idempotent.
    public func stop() {
        let token = state.withLock { s -> SPUSubscription? in
            let t = s.token
            s.token = nil
            s.detector = nil
            s.bus = nil
            s.lastFiredAt = nil
            return t
        }
        if let token {
            broker.unsubscribe(token)
            log.info("entity:GyroscopeSource wasInvalidatedBy activity:Stop")
        }
    }

    // MARK: - Report handling

    /// Decode one HID report buffer, run it through the detector, and
    /// publish on a confirmed spike. Per-source debounce gates the
    /// publish rate by `ReactionsConfig.gyroDebounce`.
    ///
    /// Exposed `internal` so the matrix mutation cells in
    /// `MatrixGyroscopeSource_Tests` can drive the gate set with
    /// synthesised payloads via the `_testInjectReport` seam.
    internal func handleReport(bytes: UnsafePointer<UInt8>, length: Int, timestamp: Date) {
        // Length floor — same minimum as the accel reader. The Int32
        // axes at offsets 6/10/14 require ≥18 bytes.
        guard length >= AccelHardwareConstants.minReportLength else { return }

        // Int32 axes at byte offsets 6/10/14 are NOT 4-byte aligned.
        // `loadUnaligned` is the sanctioned API for reading Int32 from a
        // non-aligned offset; mirrors the accelerometer reader.
        let raw = UnsafeRawPointer(bytes)
        let rawX = raw.loadUnaligned(fromByteOffset: 6, as: Int32.self)
        let rawY = raw.loadUnaligned(fromByteOffset: 10, as: Int32.self)
        let rawZ = raw.loadUnaligned(fromByteOffset: 14, as: Int32.self)

        // Same fixed-point scaling as the accel reader: Int32 LE / 65536.
        // The gyro channel reports deg/s.
        let scale = AccelHardwareConstants.rawScale
        let x = Float(rawX) / scale
        let y = Float(rawY) / scale
        let z = Float(rawZ) / scale
        let magnitude = sqrtf(x * x + y * y + z * z)

        // Resolve the publish decision under the lock, then perform the
        // bus.publish() outside the lock — `bus.publish` is async and
        // we must not hold an unfair lock across an await.
        struct Pending {
            let bus: ReactionBus
        }
        let pending: Pending? = state.withLock { s in
            guard let detector = s.detector, let bus = s.bus else { return nil }
            guard detector.process(magnitude: magnitude, timestamp: timestamp) != nil else { return nil }
            // Debounce gate.
            if let last = s.lastFiredAt, timestamp.timeIntervalSince(last) < ReactionsConfig.gyroDebounce {
                return nil
            }
            s.lastFiredAt = timestamp
            return Pending(bus: bus)
        }

        if let pending {
            log.info("activity:Publish wasGeneratedBy entity:GyroscopeSource kind=gyroSpike mag=\(String(format: "%.1f", magnitude))deg/s")
            Task { await pending.bus.publish(.gyroSpike) }
        }
    }

    /// Test seam — synthesize a report directly. Lets cells drive the
    /// detector + debounce gate with deterministic payloads without
    /// touching the broker's IOKit machinery.
    #if DEBUG
    internal func _testInjectReport(bytes: UnsafePointer<UInt8>, length: Int, timestamp: Date) {
        handleReport(bytes: bytes, length: length, timestamp: timestamp)
    }
    #endif
}
