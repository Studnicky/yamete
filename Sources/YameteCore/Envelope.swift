import Foundation

/// Shared fade-in / hold / fade-out envelope used by every output that
/// modulates an effect over time (screen flash opacity, LED pulse brightness).
public struct Envelope: Sendable, Equatable {
    public let fadeIn: TimeInterval
    public let hold: TimeInterval
    public let fadeOut: TimeInterval

    public var total: TimeInterval { fadeIn + hold + fadeOut }

    public init(fadeIn: TimeInterval, hold: TimeInterval, fadeOut: TimeInterval) {
        self.fadeIn = fadeIn; self.hold = hold; self.fadeOut = fadeOut
    }

    /// Builds an envelope from a clip duration and 0–1 intensity. Higher
    /// intensity → snappier attack and decay (more impact-shaped).
    public static func make(clipDuration: TimeInterval, intensity: Float) -> Envelope {
        let t = Double(intensity)
        let attack = 0.10 + (1.0 - t) * 0.20
        let decay  = 0.30 + (1.0 - t) * 0.20
        let hold   = 1.0 - attack - decay
        return Envelope(
            fadeIn:  clipDuration * attack,
            hold:    clipDuration * hold,
            fadeOut: clipDuration * decay
        )
    }

    /// Instantaneous level (0–1) at `t` seconds into the envelope. Used by
    /// the LED PWM dither loop to compute duty cycle per tick.
    public func level(at t: TimeInterval) -> Double {
        if t < 0 { return 0 }
        if t < fadeIn { return fadeIn > 0 ? t / fadeIn : 1.0 }
        if t < fadeIn + hold { return 1.0 }
        if t < total {
            let into = t - fadeIn - hold
            return fadeOut > 0 ? max(0, 1.0 - into / fadeOut) : 0
        }
        return 0
    }
}
