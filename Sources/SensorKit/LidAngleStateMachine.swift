#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import os

// MARK: - LidAngleStateMachine — discrete-state lid open/close/slam detector
//
// Sister type to `GyroDetector`, but the lid channel is a STATE MACHINE
// over hinge-angle deltas, not a magnitude-spike consensus pipeline. The
// gyro detector debounces tight bursts of one event class via the source
// layer; the lid detector debounces inherently because a state cannot
// re-enter itself without an intervening transition.
//
// State transitions
// -----------------
//   closed  → opening  when angle rises above `closedThresholdDeg`
//                      and the closing rate is gentler than slam-rate
//   opening → open     when angle crosses `openThresholdDeg` upward
//                      → emits `.opened`
//   open    → closing  when angle drops below `openThresholdDeg`
//   closing → closed   when angle drops below `closedThresholdDeg`
//                      gently  → emits `.closed`
//   any     → closed   when EMA Δangle/Δt < `slamRateDegPerSec`
//                      AND the new angle is below `closedThresholdDeg`
//                      → emits `.slammed` (suppresses the parallel
//                        gentle-close emission for this transition)
//
// EMA smoothing
// -------------
//   The slam-rate gate runs against an exponentially-weighted moving
//   average of Δangle / Δt, with the EMA window expressed in
//   milliseconds. A single noisy sample can spike the instantaneous
//   rate without the EMA breaching slam-rate, suppressing false slams.
//   The mutation `lid-ema-smoothing` flips this — dropping the EMA
//   makes a single jitter sample fire `.slammed`.
//
// Concurrency
// -----------
//   `@unchecked Sendable` with all mutable state under
//   `OSAllocatedUnfairLock`. Mirrors `GyroDetector`. Runs on the
//   broker's HID worker thread; callers must NOT hold non-Sendable
//   state across `process(angleDeg:timestamp:)`.

private let log = AppLog(category: "LidAngleStateMachine")

/// Discrete event surfaced by the state machine. Translates 1:1 to
/// `Reaction` cases at the source layer.
public enum LidEvent: Sendable, Equatable {
    case opened
    case closed
    case slammed
}

/// Internal state of the machine. Public so `LidAngleSource` can
/// surface it for diagnostics if needed; the production source does
/// not.
public enum LidState: Sendable, Equatable {
    case closed
    case opening
    case open
    case closing
}

public struct LidAngleStateMachineConfig: Sendable {
    public let openThresholdDeg: Double
    public let closedThresholdDeg: Double
    public let slamRateDegPerSec: Double
    public let smoothingWindowMs: Int

    public init(openThresholdDeg: Double = Defaults.lidOpenThresholdDeg,
                closedThresholdDeg: Double = Defaults.lidClosedThresholdDeg,
                slamRateDegPerSec: Double = Defaults.lidSlamRateDegPerSec,
                smoothingWindowMs: Int = Defaults.lidSmoothingWindowMs) {
        self.openThresholdDeg = openThresholdDeg
        self.closedThresholdDeg = closedThresholdDeg
        self.slamRateDegPerSec = slamRateDegPerSec
        self.smoothingWindowMs = smoothingWindowMs
    }
}

/// Discrete-state hinge-angle detector. Returns at most one
/// `LidEvent` per sample; nil when the sample does not cross a
/// transition boundary. The machine starts in `.closed` and
/// SUPPRESSES the very first sample's emission (cold-start / launch-
/// time replay protection): a host that boots with the lid already
/// open should not fire `.lidOpened` immediately on first report.
public final class LidAngleStateMachine: @unchecked Sendable {
    private let config: LidAngleStateMachineConfig

    private struct State {
        var lidState: LidState = .closed
        var lastAngleDeg: Double?
        var lastSampleAt: Date?
        var smoothedRate: Double = 0
        var hasInitialized: Bool = false
    }
    private let state: OSAllocatedUnfairLock<State>

    public init(config: LidAngleStateMachineConfig = LidAngleStateMachineConfig()) {
        self.config = config
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Reset to the initial state. Used by the source when stop() is
    /// called so a stop / start cycle does not retain stale lid-state
    /// (e.g. mid-`.opening` when stopped, then a fresh start should
    /// not fire `.opened` on the first new sample).
    public func reset() {
        state.withLock { s in
            s = State()
        }
    }

    /// Process one hinge-angle sample.
    public func process(angleDeg: Double, timestamp: Date) -> LidEvent? {
        state.withLock { s in
            // Cold-start: stamp the first sample but do NOT emit. This
            // protects against firing `.lidOpened` on launch when the
            // host has been running with the lid open for hours.
            guard s.hasInitialized else {
                s.hasInitialized = true
                s.lastAngleDeg = angleDeg
                s.lastSampleAt = timestamp
                // Seed the lid-state from the cold-start angle so the
                // machine's first transition lines up with the user's
                // physical reality. If the lid is opened on boot, we
                // start in `.open` — an opening transition won't
                // re-fire (already open), but a closing transition
                // will surface correctly.
                if angleDeg >= config.openThresholdDeg {
                    s.lidState = .open
                } else if angleDeg <= config.closedThresholdDeg {
                    s.lidState = .closed
                } else {
                    // Mid-range cold-start: pessimistic toward `.opening`
                    // so a continued upward trend fires `.opened`.
                    s.lidState = .opening
                }
                return nil
            }

            guard let lastAngle = s.lastAngleDeg, let lastAt = s.lastSampleAt else {
                s.lastAngleDeg = angleDeg
                s.lastSampleAt = timestamp
                return nil
            }

            let dt = timestamp.timeIntervalSince(lastAt)
            // Δt sign: must be positive — a non-monotonic timestamp
            // (e.g. NTP jump) yields no instantaneous rate this tick.
            // The mutation `lid-time-delta-sign` flips this to allow
            // negative dt, which makes the slam test (negative-rate
            // computation) collapse and slam never fires.
            guard dt > 0 else {
                s.lastAngleDeg = angleDeg
                s.lastSampleAt = timestamp
                return nil
            }
            let instantaneousRate = (angleDeg - lastAngle) / dt

            // EMA over Δangle/Δt. Alpha derived from the configured
            // window length: alpha = dt / (windowSec + dt). At
            // dt=10ms / window=100ms this yields alpha≈0.09, which
            // attenuates a single-sample spike by ~11x.
            let windowSec = max(Double(config.smoothingWindowMs) / 1000.0, 0.001)
            let alpha = dt / (windowSec + dt)
            s.smoothedRate = alpha * instantaneousRate + (1 - alpha) * s.smoothedRate

            // Update tracking state.
            s.lastAngleDeg = angleDeg
            s.lastSampleAt = timestamp

            // Slam path takes precedence over the gentle-close path so
            // a single transition cannot emit both `.lidSlammed` AND
            // `.lidClosed`. The slam check uses the EMA so single-
            // sample jitter does not falsely fire.
            if s.smoothedRate < config.slamRateDegPerSec
                && angleDeg < config.closedThresholdDeg {
                s.lidState = .closed
                log.info("activity:Detect entity:LidSlammed angle=\(String(format: "%.1f", angleDeg))° rate=\(String(format: "%.1f", s.smoothedRate))°/s")
                return .slammed
            }

            // Discrete state transitions.
            switch s.lidState {
            case .closed:
                if angleDeg > config.closedThresholdDeg {
                    s.lidState = .opening
                }
            case .opening:
                if angleDeg >= config.openThresholdDeg {
                    s.lidState = .open
                    log.info("activity:Detect entity:LidOpened angle=\(String(format: "%.1f", angleDeg))°")
                    return .opened
                }
                // Reverted closure during opening — drop back to
                // `.closed` without emitting.
                if angleDeg <= config.closedThresholdDeg {
                    s.lidState = .closed
                }
            case .open:
                if angleDeg < config.openThresholdDeg {
                    s.lidState = .closing
                }
            case .closing:
                if angleDeg <= config.closedThresholdDeg {
                    s.lidState = .closed
                    log.info("activity:Detect entity:LidClosed angle=\(String(format: "%.1f", angleDeg))°")
                    return .closed
                }
                // Reverted opening during closing — bounce back to
                // `.open` without emitting.
                if angleDeg >= config.openThresholdDeg {
                    s.lidState = .open
                }
            }
            return nil
        }
    }

    /// Test introspection — current internal state. Tests use this
    /// to assert the cold-start seeding behaviour.
    public var currentState: LidState {
        state.withLock { $0.lidState }
    }
}
