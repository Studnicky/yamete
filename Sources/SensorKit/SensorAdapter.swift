#if canImport(YameteCore)
import YameteCore
#endif
import Foundation

// MARK: - SensorAdapter Protocol

/// Interface for adapters that stream normalized accelerometer samples.
public protocol SensorAdapter: AnyObject, Sendable {
    /// Stable identifier for this adapter (used as dictionary key in fusion engine).
    var id: SensorID { get }

    /// Human-readable name for logging and UI (e.g., "Apple SPU Accelerometer").
    var name: String { get }

    /// Whether this adapter's hardware is present on this machine.
    /// Called during discovery and should be fast.
    var isAvailable: Bool { get }

    /// Returns a stream of normalized Vec3 samples in g-force.
    /// - Throws on sensor failure (permission denied, device lost, etc.)
    /// - Terminates when the consuming task is cancelled.
    func samples() -> AsyncThrowingStream<Vec3, Error>
}

// MARK: - SensorSample

/// A normalized sample with source and timestamp, ready for fan-in/fusion.
public struct SensorSample: Sendable {
    public init(source: SensorID, timestamp: Date, value: Vec3) { self.source = source; self.timestamp = timestamp; self.value = value }
    public let source: SensorID
    public let timestamp: Date
    public let value: Vec3
}

// MARK: - SensorEvent

/// Events emitted by `SensorManager`.
public enum SensorEvent: Sendable {
    case sample(SensorSample)
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

/// Discovers adapters and fans in all available streams concurrently.
@MainActor
public final class SensorManager {
    private let adapters: [any SensorAdapter]
    private let log = AppLog(category: "SensorManager")

    public init(adapters: [any SensorAdapter]) {
        self.adapters = adapters
    }

    /// Returns a stream of sensor events.
    /// All available adapters are started concurrently and merged into one stream.
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
                            for try await vec in adapter.samples() {
                                continuation.yield(.sample(SensorSample(
                                    source: adapter.id,
                                    timestamp: Date(),
                                    value: vec
                                )))
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

    public init(adapters: [any SensorAdapter]) {
        activeIDs = Set(adapters.map(\.id))
        namesByID = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0.name) })
    }

    func remove(_ adapter: any SensorAdapter) -> (ids: Set<SensorID>, names: [String]) {
        activeIDs.remove(adapter.id)
        namesByID.removeValue(forKey: adapter.id)
        return (activeIDs, Array(namesByID.values))
    }
}
