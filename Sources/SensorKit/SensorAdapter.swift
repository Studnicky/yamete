#if canImport(YameteCore)
import YameteCore
#endif
import Foundation

// MARK: - API Classification

/// Whether a sensor adapter uses public or private macOS APIs.
public enum APIClassification: String, Sendable, CustomStringConvertible {
    case publicAPI = "Public"
    case privateAPI = "Private"
    public var description: String { rawValue }
}

// MARK: - SensorAdapter Protocol

/// Interface for adapters that detect impacts from a specific sensor.
/// Each adapter runs its own sensor-specific detection pipeline internally
/// (preprocessing, gating, thresholding) and emits impact events with 0–1 intensity.
public protocol SensorAdapter: AnyObject, Sendable {
    var id: SensorID { get }
    var name: String { get }
    var apiClassification: APIClassification { get }
    var isAvailable: Bool { get }

    /// Returns a stream of detected impacts. Each adapter applies its own
    /// sensor-specific preprocessing and detection gates internally.
    /// Intensity is 0–1 where the scale is specific to this sensor type:
    /// 0 = weakest detectable impact, 1 = strongest expected impact.
    func impacts() -> AsyncThrowingStream<SensorImpact, Error>
}

// MARK: - SensorImpact

/// An impact detected by a single sensor adapter.
public struct SensorImpact: Sendable {
    public let source: SensorID
    public let timestamp: Date
    /// 0–1 intensity relative to this sensor's detection range.
    public let intensity: Float

    public init(source: SensorID, timestamp: Date, intensity: Float) {
        self.source = source; self.timestamp = timestamp; self.intensity = intensity
    }
}

// MARK: - SensorEvent

/// Events emitted by `SensorManager`.
public enum SensorEvent: Sendable {
    case impact(SensorImpact)
    case error(String)
    case adaptersChanged(ids: Set<SensorID>, names: [String])
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
            NSLocalizedString("Motion sensor access denied — grant Input Monitoring permission in System Settings > Privacy & Security.", comment: "Sensor permission error")
        case .deviceNotFound:
            NSLocalizedString("No accelerometer found — this Mac may not have a compatible motion sensor.", comment: "Sensor not found error")
        case .ioKitError(let code):
            String(format: NSLocalizedString("Accelerometer unavailable (IOKit error %@). This Mac may not have a compatible motion sensor.", comment: "IOKit error with code"), code)
        case .noAdaptersAvailable:
            NSLocalizedString("No compatible motion sensor found on this Mac.", comment: "No adapters error")
        }
    }
}

// MARK: - SensorManager

/// Discovers adapters and fans in all impact streams concurrently.
@MainActor
public final class SensorManager {
    private let adapters: [any SensorAdapter]
    private let log = AppLog(category: "SensorManager")

    public init(adapters: [any SensorAdapter]) {
        self.adapters = adapters
    }

    public func events() -> AsyncStream<SensorEvent> {
        let adapters = self.adapters.filter { $0.isAvailable }
        let log = self.log

        let (stream, continuation) = AsyncStream.makeStream(of: SensorEvent.self)
        let activeTracker = ActiveAdapterTracker(adapters: adapters)

        let task = Task {
            defer { continuation.finish() }

            guard !adapters.isEmpty else {
                continuation.yield(.error(SensorError.noAdaptersAvailable.localizedDescription))
                return
            }

            continuation.yield(.adaptersChanged(ids: Set(adapters.map(\.id)), names: adapters.map(\.name).sorted()))

            await withTaskGroup(of: Void.self) { group in
                for adapter in adapters {
                    group.addTask {
                        do {
                            log.info("activity:SensorDiscovery selected entity:Adapter name=\(adapter.name)")
                            for try await impact in adapter.impacts() {
                                continuation.yield(.impact(impact))
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            log.warning("entity:Adapter wasInvalidatedBy activity:SensorError name=\(adapter.name) — \(error.localizedDescription)")
                            continuation.yield(.error("\(adapter.name): \(error.localizedDescription)"))
                        }

                        let (remainingIDs, remainingNames) = await activeTracker.remove(adapter)
                        continuation.yield(.adaptersChanged(ids: remainingIDs, names: remainingNames.sorted()))
                    }
                }
                await group.waitForAll()
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

private actor ActiveAdapterTracker {
    private var activeIDs: Set<SensorID>
    private var namesByID: [SensorID: String]

    init(adapters: [any SensorAdapter]) {
        activeIDs = Set(adapters.map(\.id))
        namesByID = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0.name) })
    }

    func remove(_ adapter: any SensorAdapter) -> (ids: Set<SensorID>, names: [String]) {
        activeIDs.remove(adapter.id)
        namesByID.removeValue(forKey: adapter.id)
        return (activeIDs, Array(namesByID.values))
    }
}
