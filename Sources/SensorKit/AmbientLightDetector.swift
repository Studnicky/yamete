#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import os

// MARK: - AmbientLightDetector — step-change detector over a lux ring buffer
//
// Sister type to `LidAngleStateMachine`, but the ALS channel is a
// CONTINUOUS-STREAM step-change detector rather than a discrete-state
// machine. Three independent detectors share a single 2-second ring
// buffer of `(timestamp, lux)` samples plus a single shared cooldown:
//
// • `.covered` — fast drop suggestive of a hand or object occluding
//   the sensor. Pinned by a RATE constraint (drop crossed within
//   ≤200ms) AND a near-zero floor on the new lux value. Without the
//   rate gate, a slow dim would erroneously fire `.alsCovered`.
//
// • `.off` — sharp drop over the WINDOW (default 2s) AND a low
//   absolute floor on the new lux value. Without the window-rate
//   gate, the slow drift of dusk would fire `.lightsOff`.
//
// • `.on` — sharp rise over the WINDOW AND a high absolute ceiling on
//   the new lux value. The rise comparison is `> 0` (mutated to `< 0`
//   in the matrix cell) — without the comparison being correct, a
//   light-up never fires.
//
// Detectors run in priority order on each sample: covered first
// (fastest event), then off / on. Any single sample emits at most one
// event. After an emission, a `debounceSec`-long cooldown blocks
// further emissions of any kind.
//
// Concurrency
// -----------
//   `@unchecked Sendable` with all mutable state under
//   `OSAllocatedUnfairLock`. Mirrors `LidAngleStateMachine`.

private let log = AppLog(category: "AmbientLightDetector")

/// Discrete event surfaced by the detector. Translates 1:1 to
/// `Reaction` cases at the source layer.
public enum AmbientLightEvent: Sendable, Equatable {
    case covered
    case off
    case on
}

public struct AmbientLightDetectorConfig: Sendable {
    public let coverDropThreshold: Double
    public let offDropPercent: Double
    public let offFloorLux: Double
    public let onRisePercent: Double
    public let onCeilingLux: Double
    public let windowSec: Double
    public let debounceSec: TimeInterval

    public init(coverDropThreshold: Double = Defaults.alsCoverDropThreshold,
                offDropPercent: Double = Defaults.alsOffDropPercent,
                offFloorLux: Double = Defaults.alsOffFloorLux,
                onRisePercent: Double = Defaults.alsOnRisePercent,
                onCeilingLux: Double = Defaults.alsOnCeilingLux,
                windowSec: Double = Defaults.alsWindowSec,
                debounceSec: TimeInterval = ReactionsConfig.alsDebounce) {
        self.coverDropThreshold = coverDropThreshold
        self.offDropPercent = offDropPercent
        self.offFloorLux = offFloorLux
        self.onRisePercent = onRisePercent
        self.onCeilingLux = onCeilingLux
        self.windowSec = windowSec
        self.debounceSec = debounceSec
    }
}

/// Continuous-stream lux step-change detector. Returns at most one
/// `AmbientLightEvent` per sample; nil when the sample does not cross
/// any gate. The very first sample after construction (cold-start /
/// launch-time replay protection) does NOT emit and merely seeds the
/// history buffer.
public final class AmbientLightDetector: @unchecked Sendable {
    private let config: AmbientLightDetectorConfig

    private struct Sample {
        let timestamp: Date
        let lux: Double
    }

    private struct State {
        /// Bounded ring of recent (t, lux) samples. The detector keeps
        /// every sample whose age is ≤ `windowSec` — older entries are
        /// trimmed off the head before each new sample is processed.
        var history: [Sample] = []
        var lastFiredAt: Date?
        var hasInitialized: Bool = false
    }
    private let state: OSAllocatedUnfairLock<State>

    public init(config: AmbientLightDetectorConfig = AmbientLightDetectorConfig()) {
        self.config = config
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Reset to the initial state. Used by the source when stop() is
    /// called so a stop / start cycle does not retain stale history
    /// (e.g. yesterday's daylight readings firing `.lightsOff` on
    /// the first new sample after restart).
    public func reset() {
        state.withLock { s in
            s = State()
        }
    }

    /// Process one lux sample. Returns the event surfaced by the
    /// highest-priority detector that fired, or nil otherwise.
    public func process(lux: Double, timestamp: Date) -> AmbientLightEvent? {
        state.withLock { s in
            // Cold-start: stamp the first sample but do NOT emit. This
            // protects against firing `.lightsOff` / `.lightsOn` on
            // launch when the host has been running with the lights
            // already a particular way for hours.
            guard s.hasInitialized else {
                s.hasInitialized = true
                s.history = [Sample(timestamp: timestamp, lux: lux)]
                return nil
            }

            // Trim history to the window. We keep one sample older than
            // the window so the windowed comparators always have a
            // baseline to read from when the buffer is otherwise empty.
            let windowAgo = timestamp.addingTimeInterval(-config.windowSec)
            if let firstInsideIdx = s.history.firstIndex(where: { $0.timestamp >= windowAgo }) {
                if firstInsideIdx > 1 {
                    s.history.removeFirst(firstInsideIdx - 1)
                }
            }

            // Cooldown gate. Any single emission blocks further
            // emissions for `debounceSec`. Append the sample first so
            // the buffer reflects the live signal during the gate.
            let cooldownActive: Bool = {
                guard let last = s.lastFiredAt else { return false }
                return timestamp.timeIntervalSince(last) < config.debounceSec
            }()

            // Detector 1 — covered. Pinned by a RATE gate (≤200ms
            // since the most-recent baseline that exceeded the trigger
            // ratio) AND a near-zero floor on the new lux value.
            // Mutating either gate must surface in MatrixAmbientLight
            // cells.
            if !cooldownActive {
                if let recent = s.history.last,
                   timestamp.timeIntervalSince(recent.timestamp) <= 0.2,
                   recent.lux > 0,
                   lux <= config.coverDropThreshold * recent.lux,
                   lux <= 5.0 {
                    s.history.append(Sample(timestamp: timestamp, lux: lux))
                    s.lastFiredAt = timestamp
                    log.info("activity:Detect entity:AlsCovered lux=\(String(format: "%.1f", lux)) baseline=\(String(format: "%.1f", recent.lux))")
                    return .covered
                }
            }

            // Detector 2 — off. Pinned by a window-rate gate (lux
            // dropped by ≥ offDropPercent over windowSec) AND an
            // absolute floor on the new lux. Mutating either gate must
            // surface in MatrixAmbientLight cells.
            // Detector 3 — on. Pinned by a window-rate gate (lux rose
            // by ≥ onRisePercent over windowSec) AND an absolute
            // ceiling on the new lux. The rise comparison `lux > ...`
            // is the mutation target for the rise-percent matrix cell.
            if !cooldownActive, let baseline = s.history.first {
                let elapsed = timestamp.timeIntervalSince(baseline.timestamp)
                if elapsed >= config.windowSec * 0.5 {
                    // Off path
                    if baseline.lux > 0 {
                        let drop = (baseline.lux - lux) / baseline.lux
                        if drop >= config.offDropPercent && lux < config.offFloorLux {
                            s.history.append(Sample(timestamp: timestamp, lux: lux))
                            s.lastFiredAt = timestamp
                            log.info("activity:Detect entity:LightsOff lux=\(String(format: "%.1f", lux)) baseline=\(String(format: "%.1f", baseline.lux))")
                            return .off
                        }
                    }
                    // On path
                    if baseline.lux > 0 {
                        let rise = (lux - baseline.lux) / baseline.lux
                        if rise >= config.onRisePercent && lux > config.onCeilingLux {
                            s.history.append(Sample(timestamp: timestamp, lux: lux))
                            s.lastFiredAt = timestamp
                            log.info("activity:Detect entity:LightsOn lux=\(String(format: "%.1f", lux)) baseline=\(String(format: "%.1f", baseline.lux))")
                            return .on
                        }
                    }
                }
            }

            // No event — append and return.
            s.history.append(Sample(timestamp: timestamp, lux: lux))
            return nil
        }
    }

    /// Test introspection — number of buffered samples.
    public var bufferedSampleCount: Int {
        state.withLock { $0.history.count }
    }
}
