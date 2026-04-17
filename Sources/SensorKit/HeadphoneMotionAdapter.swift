#if canImport(YameteCore)
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
// Public API documentation:
//   https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager
//   https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/3552067-startdevicemotionupdates
//   https://developer.apple.com/documentation/coremotion/cmdevicemotion/1616149-useracceleration

/// Detects impact vibrations via AirPods/Beats accelerometer using CoreMotion.
/// Requires connected headphones with motion sensors.
/// Thresholds calibrated for userAcceleration (gravity-subtracted) in g-force.
public final class HeadphoneMotionAdapter: SensorAdapter, Sendable {

    public let id = SensorID.headphoneMotion
    public let name = "Headphone Motion"

    private let manager = CMHeadphoneMotionManager()
    private let connectionTracker: HeadphoneConnectionTracker
    private let probeStage = OSAllocatedUnfairLock<ProbeStage>(initialState: .pending)

    /// Tracks whether the startup connection probe is owning the
    /// underlying `CMHeadphoneMotionManager` and whether `impacts()` has
    /// taken it over. Required because `CMHeadphoneMotionManagerDelegate`
    /// only fires didConnect/didDisconnect on state CHANGES while updates
    /// are active — we have to engage the device briefly to learn its
    /// current connection state, but we must not stomp on a real consumer
    /// that started impacts() during the probe window.
    private enum ProbeStage: Sendable {
        case pending     // init done, probe not started
        case running     // probe holds the manager
        case complete    // probe finished naturally and stopped the manager
        case takenOver   // impacts() took the manager from the probe
    }

    /// Headphone detection config: thresholds in g-force (userAcceleration).
    /// Floor: 0.05g (normal head movement). Ceiling: 2.0g (sharp jolt).
    public let detectorConfig: ImpactDetectorConfig

    public init(detectorConfig: ImpactDetectorConfig = .headphoneMotion()) {
        self.detectorConfig = detectorConfig
        self.connectionTracker = HeadphoneConnectionTracker()
        manager.delegate = connectionTracker
        startConnectionProbe()
    }

    /// True only when the framework supports headphone motion AND a
    /// motion-capable device (AirPods Pro/Max, Beats with H-chips) is
    /// currently connected. State is initialized by the startup probe,
    /// then maintained by the delegate callbacks while the probe or
    /// impacts() keep updates active.
    public var isAvailable: Bool {
        manager.isDeviceMotionAvailable && connectionTracker.isConnected
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
        guard manager.isDeviceMotionAvailable else { return }
        probeStage.withLock { $0 = .running }

        let tracker = connectionTracker
        manager.startDeviceMotionUpdates(to: OperationQueue()) { motion, _ in
            // Any non-nil sample means the headphones are physically streaming
            // motion data, which means they're connected. The delegate's
            // didConnect should also fire — both paths set the same flag.
            if motion != nil { tracker.markConnected() }
        }

        // Wait long enough for the first sample to arrive on connected
        // hardware (typically <100ms) without holding the device for too
        // long if nothing's there. 400ms is a comfortable margin.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [self] in
            let shouldStop = probeStage.withLock { stage -> Bool in
                guard stage == .running else { return false }
                stage = .complete
                return true
            }
            if shouldStop {
                manager.stopDeviceMotionUpdates()
                log.info("activity:HeadphoneProbe wasEndedBy agent:HeadphoneMotionAdapter connected=\(tracker.isConnected)")
            }
        }
    }

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let adapterID = self.id
        let detector = ImpactDetector(config: detectorConfig, adapterName: name)

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
            manager.stopDeviceMotionUpdates()
        }

        guard manager.isDeviceMotionAvailable else {
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        manager.startDeviceMotionUpdates(to: OperationQueue()) { motion, error in
            if let error {
                log.warning("activity:SensorReading wasInvalidatedBy agent:HeadphoneMotionAdapter — \(error.localizedDescription)")
                continuation.finish(throwing: error)
                return
            }
            guard let accel = motion?.userAcceleration else { return }

            let mag = sqrtf(Float(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z))

            let now = Date()
            if let intensity = detector.process(magnitude: mag, timestamp: now) {
                continuation.yield(SensorImpact(source: adapterID, timestamp: now, intensity: intensity))
            }
        }

        log.info("activity:SensorReading wasStartedBy agent:HeadphoneMotionAdapter")

        continuation.onTermination = { @Sendable [manager] _ in
            manager.stopDeviceMotionUpdates()
            log.info("activity:SensorReading wasEndedBy agent:HeadphoneMotionAdapter")
        }

        return stream
    }
}

// MARK: - Connection state tracker

/// Tracks whether motion-capable headphones are currently connected by
/// observing `CMHeadphoneMotionManagerDelegate` callbacks. The adapter
/// owns one of these and the menu bar UI's sensor list reflects its state.
///
/// `CMHeadphoneMotionManager.isDeviceMotionAvailable` only reports framework
/// support — it returns true on every Apple Silicon Mac regardless of whether
/// AirPods are paired/connected. Real connection state requires the delegate.
///
/// Sendable: the only stored state is an `OSAllocatedUnfairLock<Bool>`.
/// `OSAllocatedUnfairLock` is Sendable when its state type is Sendable, and
/// `Bool` is Sendable. No unchecked escape required.
private final class HeadphoneConnectionTracker: NSObject, CMHeadphoneMotionManagerDelegate, Sendable {
    private let state = OSAllocatedUnfairLock<Bool>(initialState: false)

    var isConnected: Bool { state.withLock { $0 } }

    /// Set by the startup probe (in `HeadphoneMotionAdapter.startConnectionProbe`)
    /// when motion data starts flowing. The delegate's didConnect callback
    /// is also expected to fire — both paths land in the same flag.
    func markConnected() {
        state.withLock { $0 = true }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        state.withLock { $0 = true }
        log.info("activity:HeadphoneConnection wasStartedBy entity:Headphones")
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        state.withLock { $0 = false }
        log.info("activity:HeadphoneConnection wasEndedBy entity:Headphones")
    }
}
