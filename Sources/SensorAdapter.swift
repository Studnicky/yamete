import Foundation

// MARK: - SensorAdapter Protocol

/// Normalized sensor interface. Every adapter outputs Vec3 samples in g-force
/// units regardless of the underlying hardware or transport.
///
/// Architecture distinction from prior art:
///   - slapmac: branches in a single start() method, no protocol
///   - spank: hardcoded SPU sensor + POSIX shared memory
///   - yamate: clean protocol boundary — the detection pipeline (ImpactDetector,
///     SignalProcessing, ImpactController) consumes Vec3 without knowing the source.
///     New sensor types (microphone, Intel SMS, external BLE) implement this protocol.
///
/// Each adapter produces an `AsyncThrowingStream<Vec3, Error>`. The stream yields
/// normalized g-force samples. Errors terminate the stream. Cancellation propagates
/// through task cancellation — no callbacks, no weak self, no manual cleanup.
protocol SensorAdapter: AnyObject, Sendable {
    /// Human-readable name for logging and UI (e.g., "Apple SPU Accelerometer").
    var name: String { get }

    /// Whether this adapter's hardware is present on this machine.
    /// Called during discovery — should be fast.
    var isAvailable: Bool { get }

    /// Returns a stream of normalized Vec3 samples in g-force.
    /// - Throws on sensor failure (permission denied, device lost, etc.)
    /// - Terminates when the consuming task is cancelled.
    func samples() -> AsyncThrowingStream<Vec3, Error>
}

// MARK: - SensorEvent

/// Events produced by the sensor manager. Eliminates the need for separate
/// onSample / onError / onAdapterChanged callbacks.
enum SensorEvent: Sendable {
    case sample(Vec3)
    case error(String)
    case adapterChanged(String)
}

// MARK: - SensorError

enum SensorError: Error, LocalizedError, Sendable {
    case permissionDenied
    case deviceNotFound
    case ioKitError(String)
    case noAdaptersAvailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Motion sensor access denied — grant Input Monitoring permission in System Settings > Privacy & Security."
        case .deviceNotFound:
            "No accelerometer found — this Mac may not have a compatible motion sensor."
        case .ioKitError(let code):
            "Accelerometer unavailable (IOKit error \(code)). This Mac may not have a compatible motion sensor."
        case .noAdaptersAvailable:
            "No compatible motion sensor found on this Mac."
        }
    }
}

// MARK: - SensorManager

/// Discovers, selects, and manages sensor adapters with automatic retry on failure.
///
/// Produces an `AsyncStream<SensorEvent>` that the consumer iterates with `for await`.
/// Retry, adapter selection, and cleanup are all handled internally via structured concurrency.
/// Cancelling the consuming task propagates through the entire chain — no manual stop needed.
@MainActor
final class SensorManager {
    private let adapters: [any SensorAdapter]
    private let retryInterval: TimeInterval = 5.0
    private let maxRetries = 3
    private let log = AppLog(category: "SensorManager")

    init(adapters: [any SensorAdapter]) {
        self.adapters = adapters
    }

    /// Returns a stream of sensor events. Handles adapter discovery, error recovery,
    /// and retry internally. Cancel the consuming task to stop everything.
    func events() -> AsyncStream<SensorEvent> {
        let adapters = self.adapters
        let maxRetries = self.maxRetries
        let retryInterval = self.retryInterval
        let log = self.log

        let (stream, continuation) = AsyncStream.makeStream(of: SensorEvent.self)

        let task = Task {
            defer { continuation.finish() }

            for attempt in 0...maxRetries {
                guard !Task.isCancelled else { return }

                guard let adapter = adapters.first(where: { $0.isAvailable }) else {
                    continuation.yield(.error(SensorError.noAdaptersAvailable.localizedDescription))
                    return
                }

                log.info("activity:SensorDiscovery selected entity:Adapter name=\(adapter.name) attempt=\(attempt)")
                continuation.yield(.adapterChanged(adapter.name))

                do {
                    for try await vec in adapter.samples() {
                        continuation.yield(.sample(vec))
                    }
                    // Stream ended without error (normal shutdown via cancellation)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    log.warning("entity:Adapter wasInvalidatedBy activity:SensorError — \(error.localizedDescription)")
                    if attempt < maxRetries {
                        continuation.yield(.error("\(error.localizedDescription) Retrying…"))
                        try? await Task.sleep(for: .seconds(retryInterval))
                    } else {
                        log.error("activity:SensorRetry exhausted after=\(maxRetries) attempts")
                        continuation.yield(.error("\(error.localizedDescription) Retry with the enable toggle."))
                    }
                }
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
