#if canImport(YameteCore)
import YameteCore
#endif
import Foundation

// MARK: - SensorSource Protocol

/// A concrete sensor that produces impact events. Each implementation owns
/// its own preprocessing (filter, decimation), gating (`ImpactDetector`), and
/// hardware lifecycle. The fusion engine subscribes to many sources, runs
/// consensus/rearm, and publishes `Reaction.impact` onto the bus.
public protocol SensorSource: AnyObject, Sendable {
    var id: SensorID { get }
    var name: String { get }
    var isAvailable: Bool { get }

    /// Stream of impacts detected by this source. Intensity is 0–1 relative
    /// to this sensor's detection range.
    func impacts() -> AsyncThrowingStream<SensorImpact, Error>
}

// MARK: - SensorImpact

/// An impact detected by a single sensor source. Internal to the impact
/// pipeline — never reaches output consumers (those see `Reaction.impact`).
public struct SensorImpact: Sendable {
    public let source: SensorID
    public let timestamp: Date
    public let intensity: Float

    public init(source: SensorID, timestamp: Date, intensity: Float) {
        self.source = source; self.timestamp = timestamp; self.intensity = intensity
    }
}

// MARK: - StimulusSource Protocol

/// Observes discrete system events (device attach/detach, power, sleep/wake)
/// and publishes them as `Reaction` values to a `ReactionBus`.
@MainActor
public protocol StimulusSource: AnyObject {
    var id: SensorID { get }
    func start(publishingTo bus: ReactionBus) async
    func stop()
}

// MARK: - SensorError

public enum SensorError: Error, LocalizedError, Sendable {
    case permissionDenied
    case deviceNotFound
    case ioKitError(String)
    case noAdaptersAvailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            NSLocalizedString("Microphone access denied. Grant permission in System Settings > Privacy & Security > Microphone.", comment: "Sensor permission error")
        case .deviceNotFound:
            NSLocalizedString("Accelerometer not found. The built-in accelerometer is only available on MacBook Air and MacBook Pro (Apple Silicon).", comment: "Sensor not found error")
        case .ioKitError(let code):
            String(format: NSLocalizedString("Accelerometer unavailable (IOKit error %@). The built-in accelerometer requires a MacBook Air or MacBook Pro with Apple Silicon.", comment: "IOKit error with code"), code)
        case .noAdaptersAvailable:
            NSLocalizedString("No sensors available. Enable at least one sensor, or connect a microphone.", comment: "No adapters error")
        }
    }
}
