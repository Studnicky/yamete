#if canImport(YameteCore)
import YameteCore
#endif
@preconcurrency import CoreMotion
import Foundation

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

    /// Headphone detection config: thresholds in g-force (userAcceleration).
    /// Floor: 0.05g (normal head movement). Ceiling: 2.0g (sharp jolt).
    public let detectorConfig: ImpactDetectorConfig

    public init(detectorConfig: ImpactDetectorConfig = .headphoneMotion()) {
        self.detectorConfig = detectorConfig
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let adapterID = self.id
        let detector = ImpactDetector(config: detectorConfig, adapterName: name)

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
