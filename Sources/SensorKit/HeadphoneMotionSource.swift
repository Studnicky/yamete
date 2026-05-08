#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import CoreMotion
import Foundation
import os

private let log = AppLog(category: "HeadphoneMotion")

// MARK: - Headphone Motion Adapter
//
// Detects impact vibrations via AirPods/Beats IMU using CMHeadphoneMotionManager.
// Reads userAcceleration (gravity-subtracted) and runs the standard gate pipeline.
// Only active when compatible headphones with motion sensors are connected.
//
// Hardware boundary: `HeadphoneMotionDriver`. The default produces a
// `RealHeadphoneMotionDriver` backed by `CMHeadphoneMotionManager`. Tests
// inject a mock driver that exposes simulate-connect / simulate-disconnect
// hooks plus a synchronous sample emitter.
//
// Public API documentation:
//   https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager
//   https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/3552067-startdevicemotionupdates
//   https://developer.apple.com/documentation/coremotion/cmdevicemotion/1616149-useracceleration
//
// macOS gate: `CMHeadphoneMotionManager` is macOS 14.0+ (Sonoma). Yamete's
// minimum deployment target is macOS 14, so the symbol is always
// available — no `@available` guard needed at the source level.
// `NSMotionUsageDescription` is supplied in `App/Config/Info.plist` and
// localized across all 40 lproj bundles; first call to
// `startDeviceMotionUpdates` triggers the consent prompt on macOS.
//
// Per-model coverage. `CMHeadphoneMotionManager` surfaces motion only
// for headphones whose firmware exposes the IMU stream over Bluetooth —
// the same set Apple labels "Personalized Spatial Audio with dynamic
// head tracking." Audio-only routing (AirPods 1/2, EarPods, Beats W1
// devices, third-party) does not produce motion.
//
//   ╭─────────────────────────────────────────╥─────────────────────╮
//   │  Model                                  ║  Motion via CMHM    │
//   ╞═════════════════════════════════════════╬═════════════════════╡
//   │  AirPods (1st gen)                      ║  no — no IMU        │
//   │  AirPods (2nd gen)                      ║  no — no IMU        │
//   │  AirPods (3rd gen)                      ║  yes                │
//   │  AirPods (4th gen) / 4 with ANC         ║  yes (INFERRED)     │
//   │  AirPods Pro (1st gen)                  ║  yes                │
//   │  AirPods Pro (2nd gen, Lightning)       ║  yes                │
//   │  AirPods Pro (2nd gen, USB-C)           ║  yes (INFERRED)     │
//   │  AirPods Max (Lightning)                ║  yes                │
//   │  AirPods Max (USB-C)                    ║  yes (INFERRED)     │
//   │  EarPods (Lightning / USB-C, wired)     ║  no — no IMU        │
//   │  Beats Solo Pro / Studio3 / Solo3       ║  no — W1 era        │
//   │  Beats Solo 4                           ║  yes                │
//   │  Beats Studio Pro                       ║  yes                │
//   │  Beats Studio Buds                      ║  no                 │
//   │  Beats Studio Buds+                     ║  yes                │
//   │  Beats Fit Pro                          ║  yes                │
//   │  Powerbeats Pro (1st gen)               ║  no — H1 era        │
//   │  Powerbeats Pro 2                       ║  yes                │
//   │  Sony / Bose / 3rd-party                ║  no — Apple-protocol│
//   │                                         ║  only               │
//   ╰─────────────────────────────────────────╨─────────────────────╯
//
// Runtime detection nuance: `manager.isDeviceMotionAvailable` is
// framework-level and returns true on every macOS 14+ host. A real
// "is the IMU streaming" answer requires a sample or a `didConnect`
// delegate callback — the framework only fires `didConnect` for
// IMU-capable headphones. `HeadphoneConnectionTracker` (in
// `HeadphoneMotionDriver.swift`) flips its flag only on either of those
// two signals, so `isHeadphonesConnected` is capability-based — false
// for AirPods 1/2 paired audio-only, true for an active AirPods Pro.
// The startup probe holds the manager open for ~400ms so a paired
// motion-capable device can deliver the first sample before any
// `impacts()` consumer arrives.

/// Detects impact vibrations via AirPods/Beats accelerometer using CoreMotion.
/// Requires connected headphones with motion sensors.
/// Thresholds calibrated for userAcceleration (gravity-subtracted) in g-force.
public final class HeadphoneMotionSource: SensorSource, Sendable {

    public let id = SensorID.headphoneMotion
    public let name = "Headphone Motion"

    private let driver: HeadphoneMotionDriver
    private let probeStage = OSAllocatedUnfairLock<ProbeStage>(initialState: .pending)

    /// Tracks whether the startup connection probe is owning the
    /// underlying motion driver and whether `impacts()` has taken it
    /// over. Required because connection state callbacks only fire on
    /// state CHANGES while updates are active — we have to engage the
    /// device briefly to learn its current connection state, but we
    /// must not stomp on a real consumer that started impacts() during
    /// the probe window.
    public enum ProbeStage: Sendable, Equatable {
        case pending     // init done, probe not started
        case running     // probe holds the manager
        case complete    // probe finished naturally and stopped the manager
        case takenOver   // impacts() took the manager from the probe
    }

    /// Headphone detection config: thresholds in g-force (userAcceleration).
    /// Floor: 0.05g (normal head movement). Ceiling: 2.0g (sharp jolt).
    public let detectorConfig: ImpactDetectorConfig

    public convenience init(detectorConfig: ImpactDetectorConfig = .headphoneMotion()) {
        self.init(detectorConfig: detectorConfig, driver: RealHeadphoneMotionDriver())
    }

    public init(
        detectorConfig: ImpactDetectorConfig = .headphoneMotion(),
        driver: HeadphoneMotionDriver,
        runProbe: Bool = true
    ) {
        self.detectorConfig = detectorConfig
        self.driver = driver
        if runProbe {
            startConnectionProbe()
        }
    }

    /// True only when the framework supports headphone motion AND a
    /// motion-capable device (AirPods Pro/Max, Beats with H-chips) is
    /// currently connected. State is initialized by the startup probe,
    /// then maintained by the delegate callbacks while the probe or
    /// impacts() keep updates active.
    public var isAvailable: Bool {
        driver.isDeviceMotionAvailable && driver.isHeadphonesConnected
    }

    /// Briefly starts motion updates to detect AirPods/Beats already
    /// connected at app launch. The probe runs once per adapter lifetime
    /// via a temporary update window — the manager's first motion sample
    /// (or didConnect delegate callback) marks `isConnected = true`. After
    /// the window expires the probe stops the manager so the device is
    /// released back to the system. If `impacts()` is called during the
    /// window it takes over the manager and the probe's deferred stop is
    /// suppressed via the `ProbeStage.takenOver` transition.
    private func startConnectionProbe() {
        guard driver.isDeviceMotionAvailable else { return }
        probeStage.withLock { $0 = .running }

        driver.startUpdates { _, _ in
            // The driver's real implementation flips its tracker whenever
            // a non-nil sample arrives. We just need to keep the channel
            // open during the probe window.
        }

        // Wait long enough for the first sample to arrive on connected
        // hardware (typically <100ms) without holding the device for too
        // long if nothing's there. 400ms is a comfortable margin.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.finishProbeIfRunning()
        }
    }

    /// Body of the deferred probe-stop closure, extracted so tests can
    /// drive it deterministically (no waiting on DispatchQueue.global()
    /// 400ms timer). The `guard stage == .running` gate must let the
    /// stop proceed only when the probe is still active; if `impacts()`
    /// took over the manager (`.takenOver`), the deferred stop must
    /// no-op so the in-flight consumer keeps the manager.
    fileprivate func finishProbeIfRunning() {
        let shouldStop = probeStage.withLock { stage -> Bool in
            guard stage == .running else { return false }
            stage = .complete
            return true
        }
        if shouldStop {
            driver.stopUpdates()
            log.info("activity:HeadphoneProbe wasEndedBy agent:HeadphoneMotionSource connected=\(driver.isHeadphonesConnected)")
        }
    }

    #if DEBUG
    /// Test seam — current probe-stage observation.
    public var _testCurrentProbeStage: ProbeStage {
        probeStage.withLock { $0 }
    }

    /// Test seam — drives the deferred probe-stop closure body
    /// synchronously so cells can assert the `stage == .running` gate
    /// without waiting 400ms.
    public func _testRunDeferredProbeStop() {
        finishProbeIfRunning()
    }
    #endif

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let sourceID = self.id
        let detector = ImpactDetector(config: detectorConfig, sourceName: name)

        // If a probe is in progress, take over the manager. This both
        // suppresses the probe's deferred stop and lets us cleanly restart
        // motion updates with the impact handler instead of the probe's
        // sentinel handler.
        let wasProbeRunning = probeStage.withLock { stage -> Bool in
            let running = (stage == .running)
            stage = .takenOver
            return running
        }
        if wasProbeRunning {
            driver.stopUpdates()
        }

        guard driver.isDeviceMotionAvailable else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        driver.startUpdates { [driver] sample, error in
            if let error {
                log.warning("activity:SensorReading wasInvalidatedBy agent:HeadphoneMotionSource — \(error.localizedDescription)")
                continuation.finish(throwing: error)
                return
            }
            guard let sample else { return }

            // Mid-stream disconnect detection — the driver's tracker
            // may flip to disconnected while we still get tail-end
            // samples. Drop them so the adapter behaves like the
            // device went away.
            guard driver.isHeadphonesConnected else { return }

            let mag = sqrtf(Float(
                sample.userAccelerationX * sample.userAccelerationX
              + sample.userAccelerationY * sample.userAccelerationY
              + sample.userAccelerationZ * sample.userAccelerationZ
            ))

            let now = Date()
            if let intensity = detector.process(magnitude: mag, timestamp: now) {
                continuation.yield(SensorImpact(source: sourceID, timestamp: now, intensity: intensity))
            }
        }

        log.info("activity:SensorReading wasStartedBy agent:HeadphoneMotionSource")

        continuation.onTermination = { @Sendable [driver] _ in
            driver.stopUpdates()
            log.info("activity:SensorReading wasEndedBy agent:HeadphoneMotionSource")
        }

        return stream
    }
}
