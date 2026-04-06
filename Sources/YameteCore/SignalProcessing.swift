import Foundation

// MARK: - HighPassFilter

/// First-order IIR high-pass filter for 3-axis accelerometer data.
/// Removes DC offset (gravity) and low-frequency vibrations.
public final class HighPassFilter {
    private let alpha: Float
    private var prev: Vec3 = .zero
    private var prevFiltered: Vec3 = .zero

    /// - Parameters:
    ///   - cutoffHz: High-pass cutoff frequency.
    ///   - sampleRate: Effective processing rate after decimation (100 Hz → 50 Hz).
    public init(cutoffHz: Float = 5.0, sampleRate: Float = 50.0) {
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        alpha = rc / (rc + dt)
    }

    public func process(_ sample: Vec3) -> Vec3 {
        let filtered = Vec3(
            x: alpha * (prevFiltered.x + sample.x - prev.x),
            y: alpha * (prevFiltered.y + sample.y - prev.y),
            z: alpha * (prevFiltered.z + sample.z - prev.z)
        )
        prev = sample
        prevFiltered = filtered
        return filtered
    }
}

// MARK: - LowPassFilter

/// First-order IIR low-pass filter for 3-axis accelerometer data.
/// Removes high-frequency noise and electronic interference.
public final class LowPassFilter {
    private let alpha: Float
    private var prevFiltered: Vec3 = .zero

    /// - Parameters:
    ///   - cutoffHz: Low-pass cutoff frequency.
    ///   - sampleRate: Effective processing rate after decimation.
    public init(cutoffHz: Float = 25.0, sampleRate: Float = 50.0) {
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        alpha = dt / (rc + dt)
    }

    public func process(_ sample: Vec3) -> Vec3 {
        let filtered = Vec3(
            x: prevFiltered.x + alpha * (sample.x - prevFiltered.x),
            y: prevFiltered.y + alpha * (sample.y - prevFiltered.y),
            z: prevFiltered.z + alpha * (sample.z - prevFiltered.z)
        )
        prevFiltered = filtered
        return filtered
    }
}
