#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import CoreHaptics
import Foundation

// MARK: - Haptic engine driver protocol
//
// Abstracts the CoreHaptics surface used by `HapticResponder`:
// hardware availability, engine lifecycle, and pattern playback.
// `HapticResponder` consults `isHardwareAvailable` in its
// `shouldFire` gate; tests inject a mock to flip the bit without
// owning a Force Touch trackpad.

public protocol HapticEngineDriver: AnyObject, Sendable {
    /// Whether the host has a Force Touch trackpad. The real driver
    /// reads `CHHapticEngine.capabilitiesForHardware().supportsHaptics`.
    var isHardwareAvailable: Bool { get }

    /// Bring the engine up. Must precede any `playPattern` calls.
    /// Throws on engine init failure.
    func start() async throws

    /// Tear the engine down. Idempotent.
    func stop()

    /// Play a `CHHapticPattern`. Throws if playback fails (engine
    /// reset, bad pattern). The caller is responsible for awaiting
    /// the pattern's notional duration.
    func playPattern(_ pattern: CHHapticPattern) async throws
}

// MARK: - Real implementation

/// Production CHHapticEngine-backed driver.
public final class RealHapticEngineDriver: HapticEngineDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: `CHHapticEngine` is not
    // formally `Sendable`. The driver is owned by a single
    // `HapticResponder` confined to the MainActor; concurrent
    // access is therefore not possible.
    private var engine: CHHapticEngine?

    public init() {}

    public var isHardwareAvailable: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    public func start() async throws {
        let e = try CHHapticEngine()
        e.resetHandler = { [weak self] in
            // Best-effort restart on reset. Failures here are logged
            // by the consumer; the next playPattern will retry.
            // CHHapticEngine.start() is sync (the async overload is
            // separate); call the throwing sync variant.
            try? self?.engine?.start()
        }
        try await e.start()
        engine = e
    }

    public func stop() {
        engine?.stop()
        engine = nil
    }

    public func playPattern(_ pattern: CHHapticPattern) async throws {
        guard let engine else { throw HapticDriverError.engineNotStarted }
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
    }
}

public enum HapticDriverError: Error, Sendable {
    case engineNotStarted
}
