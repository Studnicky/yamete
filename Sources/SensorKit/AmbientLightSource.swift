#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import os

// MARK: - AmbientLightSource — direct-publish reaction source for ALS lux
//
// Subscribes to the SPU HID broker (`AppleSPUDevice.shared`) for
// usagePage 0xFF00 / usage 7 (Apple's ambient-light channel). The
// broker fans every report out to every active subscriber irrespective
// of usage tuple — see the broker file header for the rationale.
// Subscribers decode their own bytes from their own offsets.
//
// Wire-format assumption (UNVERIFIED — see verification note below):
//   The internal SPU report buffer is 22 bytes. Accel/gyro use offsets
//   6/10/14 (Int32 LE / 65536). Lid uses offset 18 (Int16 LE / 100 →
//   degrees). That leaves bytes 20..21 (2 bytes) as the next available
//   slot in a 22-byte report. This source decodes lux as UInt16 LE at
//   byte offset 20 (lux × 1, clamped to 0…65535 lx) on the assumption
//   that:
//     • The ALS channel emits a single scalar (no XYZ triple).
//     • Apple's HID descriptor packs that scalar in the unused tail
//       slot of the shared report layout, with a UInt16 lx encoding.
//   This assumption is gated by:
//     • The matrix mutation cells under
//       `Tests/MatrixAmbientLightSource_Tests.swift`, which drive the
//       gates via the `_testInjectLux` seam — synthetic payloads bypass
//       the wire-decode entirely so the suite is independent of the
//       real byte format.
//     • A hardware integration test on real BMI286 silicon will
//       surface zero or saturated readings if Apple's wire format
//       differs in production. Revisit the offset and scaling at that
//       point — the test seam (`_testInjectReport`) lets us update the
//       decoder without churning the test suite.
//
// Reaction emission: detected step-changes surface as
// `Reaction.alsCovered`, `.lightsOff`, or `.lightsOn` direct
// publications onto the bus. The detector enforces its own cooldown
// gate (`debounceSec`); no per-source debounce window is needed
// beyond the detector itself.

private let log = AppLog(category: "AmbientLightSource")

/// Direct-publish reaction source for the BMI286 ambient-light
/// channel. Does NOT participate in fusion — emits `.alsCovered`,
/// `.lightsOff`, `.lightsOn` directly via the reaction bus, mirroring
/// the discrete-stimulus pattern in `LidAngleSource`. Not `@MainActor`
/// because the report handler runs on the broker's HID worker thread
/// and must not hop the main actor per sample.
public final class AmbientLightSource: Sendable {

    public let id = SensorID.ambientLight
    public let name = "Ambient Light"

    private let detectorConfig: AmbientLightDetectorConfig
    private let reportIntervalUS: Int

    /// Broker the source subscribes to. Production callers share the
    /// singleton; tests inject a private broker wired with a mock kernel
    /// driver.
    internal let broker: AppleSPUDevice

    /// Lock-protected subscription / detector state. The detector is
    /// rebuilt on every `start()` so a stop / start cycle does not
    /// retain stale history.
    private struct State {
        var token: SPUSubscription?
        var detector: AmbientLightDetector?
        var bus: ReactionBus?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// Public init. Defaults match `Defaults.als*`.
    public convenience init(coverDropThreshold: Double = Defaults.alsCoverDropThreshold,
                            offDropPercent: Double = Defaults.alsOffDropPercent,
                            offFloorLux: Double = Defaults.alsOffFloorLux,
                            onRisePercent: Double = Defaults.alsOnRisePercent,
                            onCeilingLux: Double = Defaults.alsOnCeilingLux,
                            windowSec: Double = Defaults.alsWindowSec,
                            debounceSec: TimeInterval = ReactionsConfig.alsDebounce,
                            reportIntervalUS: Int = 10000) {
        let config = AmbientLightDetectorConfig(
            coverDropThreshold: coverDropThreshold,
            offDropPercent: offDropPercent,
            offFloorLux: offFloorLux,
            onRisePercent: onRisePercent,
            onCeilingLux: onCeilingLux,
            windowSec: windowSec,
            debounceSec: debounceSec
        )
        self.init(detectorConfig: config,
                  reportIntervalUS: reportIntervalUS,
                  broker: AppleSPUDevice.shared)
    }

    /// Test-overload init: caller supplies a kernel driver and the
    /// source builds a private broker wired with the same driver.
    /// Mirrors `LidAngleSource(kernelDriver:)`.
    internal convenience init(detectorConfig: AmbientLightDetectorConfig,
                              reportIntervalUS: Int = 10000,
                              kernelDriver: SPUKernelDriver) {
        self.init(
            detectorConfig: detectorConfig,
            reportIntervalUS: reportIntervalUS,
            broker: AppleSPUDevice(driver: kernelDriver)
        )
    }

    /// Designated initializer accepting a broker injection.
    internal init(detectorConfig: AmbientLightDetectorConfig,
                  reportIntervalUS: Int = 10000,
                  broker: AppleSPUDevice) {
        self.detectorConfig = detectorConfig
        self.reportIntervalUS = reportIntervalUS
        self.broker = broker
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// True when SPU HID hardware is present in the IORegistry.
    public var isAvailable: Bool {
        AppleSPUDevice.isHardwarePresent()
    }

    // MARK: - Lifecycle

    /// Subscribe to the broker and begin publishing ALS Reactions
    /// onto the supplied bus on detected step-changes. Idempotent —
    /// calling while already started is a no-op.
    public func start(publishingTo bus: ReactionBus) {
        let alreadyRunning = state.withLock { s -> Bool in
            return s.token != nil
        }
        if alreadyRunning { return }

        let detector = AmbientLightDetector(config: detectorConfig)

        state.withLock { s in
            s.detector = detector
            s.bus = bus
        }

        let token = broker.subscribe(
            usagePage: 0xFF00,
            usage: 7,
            dispatch: .als,
            reportIntervalUS: reportIntervalUS
        ) { [weak self] report in
            self?.handleReport(bytes: report.bytes, length: report.length, timestamp: report.timestamp)
        }

        state.withLock { s in
            s.token = token
        }

        if token == nil {
            log.warning("entity:AmbientLightSource wasInvalidatedBy activity:Subscribe — broker refused open")
        } else {
            log.info("entity:AmbientLightSource wasGeneratedBy activity:Start")
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
            return t
        }
        if let token {
            broker.unsubscribe(token)
            log.info("entity:AmbientLightSource wasInvalidatedBy activity:Stop")
        }
    }

    // MARK: - Report handling

    /// Decode one HID report buffer, run it through the detector, and
    /// publish on a detected step-change. The detector enforces its own
    /// cooldown; no per-source debounce gate is needed.
    ///
    /// Exposed `internal` so the matrix mutation cells in
    /// `MatrixAmbientLightSource_Tests` can drive the gate set with
    /// synthesised payloads via the `_testInjectLux` seam.
    internal func handleReport(bytes: UnsafePointer<UInt8>, length: Int, timestamp: Date) {
        // Length floor — UInt16 lux at offset 20 needs ≥22 bytes.
        guard length >= 22 else { return }

        // UInt16 LE at byte offset 20 is NOT 2-byte aligned in
        // general; `loadUnaligned` is the sanctioned API.
        let raw = UnsafeRawPointer(bytes)
        let rawLux = raw.loadUnaligned(fromByteOffset: 20, as: UInt16.self)
        let lux = Double(rawLux)

        // Resolve the publish decision under the lock, then perform
        // bus.publish() outside the lock — `bus.publish` is async and
        // we must not hold an unfair lock across an await.
        struct Pending {
            let bus: ReactionBus
            let event: AmbientLightEvent
        }
        let pending: Pending? = state.withLock { s in
            guard let detector = s.detector, let bus = s.bus else { return nil }
            guard let event = detector.process(lux: lux, timestamp: timestamp) else { return nil }
            return Pending(bus: bus, event: event)
        }

        if let pending {
            let reaction: Reaction
            switch pending.event {
            case .covered: reaction = .alsCovered
            case .off:     reaction = .lightsOff
            case .on:      reaction = .lightsOn
            }
            log.info("activity:Publish wasGeneratedBy entity:AmbientLightSource event=\(pending.event) lux=\(String(format: "%.1f", lux))")
            Task { await pending.bus.publish(reaction) }
        }
    }

    /// Test seam — synthesize a report directly. Lets cells drive the
    /// detector with deterministic payloads without touching the
    /// broker's IOKit machinery.
    #if DEBUG
    internal func _testInjectReport(bytes: UnsafePointer<UInt8>, length: Int, timestamp: Date) {
        handleReport(bytes: bytes, length: length, timestamp: timestamp)
    }

    /// Test seam — synthesize a lux value directly without composing
    /// the raw byte buffer. Equivalent to `_testInjectReport` of a
    /// payload whose offset-20 UInt16 decodes to `lux`.
    internal func _testInjectLux(_ lux: Double, at timestamp: Date) {
        let clamped = max(0.0, min(Double(UInt16.max), lux))
        var rawLux = UInt16(clamped).littleEndian
        let length = 22
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: length)
        withUnsafeBytes(of: &rawLux) { bytes in
            let p = bytes.bindMemory(to: UInt8.self).baseAddress!
            buf[20] = p[0]
            buf[21] = p[1]
        }
        handleReport(bytes: UnsafePointer(buf), length: length, timestamp: timestamp)
    }
    #endif
}
