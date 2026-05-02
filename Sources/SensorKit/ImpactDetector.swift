#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
import os

// MARK: - Per-adapter impact detection pipeline
//
// Each sensor adapter creates an ImpactDetector configured for its own physics.
// The detector operates in the sensor's native units (g-force, PCM amplitude, etc.)
// and outputs 0–1 intensity after detection. Gate thresholds are sensor-specific.
//
// Rearm/cooldown is NOT handled here — the fusion engine and controller own timing.

private let log = AppLog(category: "ImpactDetector")

/// Configuration for per-adapter impact detection, in sensor-native units.
public struct ImpactDetectorConfig: Sendable {
    /// Minimum preprocessed magnitude to consider (sensor-native units).
    public let spikeThreshold: Float
    /// Minimum magnitude increase between consecutive samples within the detection window.
    public let minRiseRate: Float
    /// Peak must exceed background RMS by this multiple.
    public let minCrestFactor: Float
    /// Number of above-threshold samples required in the detection window.
    public let minConfirmations: Int
    /// Samples before detection activates (filter settling).
    public let warmupSamples: Int
    /// Detection window duration.
    public let windowDuration: TimeInterval
    /// Preprocessed magnitude at intensity 0 (noise floor in native units).
    public let intensityFloor: Float
    /// Preprocessed magnitude at intensity 1 (maximum expected impact in native units).
    public let intensityCeiling: Float

    public init(spikeThreshold: Float, minRiseRate: Float, minCrestFactor: Float,
                minConfirmations: Int, warmupSamples: Int,
                windowDuration: TimeInterval = Detection.windowDuration,
                intensityFloor: Float, intensityCeiling: Float) {
        self.spikeThreshold = spikeThreshold; self.minRiseRate = minRiseRate
        self.minCrestFactor = minCrestFactor; self.minConfirmations = minConfirmations
        self.warmupSamples = warmupSamples; self.windowDuration = windowDuration
        self.intensityFloor = intensityFloor; self.intensityCeiling = intensityCeiling
    }

    public static func accelerometer(
        spikeThreshold: Float = Float(Defaults.accelSpikeThreshold),
        riseRate: Float = Float(Defaults.accelRiseRate),
        crestFactor: Float = Float(Defaults.accelCrestFactor),
        confirmations: Int = Defaults.accelConfirmations,
        warmupSamples: Int = Defaults.accelWarmup
    ) -> ImpactDetectorConfig {
        ImpactDetectorConfig(spikeThreshold: spikeThreshold, minRiseRate: riseRate,
                             minCrestFactor: crestFactor, minConfirmations: confirmations,
                             warmupSamples: warmupSamples,
                             intensityFloor: Detection.Accel.intensityFloor,
                             intensityCeiling: Detection.Accel.intensityCeiling)
    }

    public static func microphone(
        spikeThreshold: Float = Float(Defaults.micSpikeThreshold),
        riseRate: Float = Float(Defaults.micRiseRate),
        crestFactor: Float = Float(Defaults.micCrestFactor),
        confirmations: Int = Defaults.micConfirmations,
        warmupSamples: Int = Defaults.micWarmup
    ) -> ImpactDetectorConfig {
        ImpactDetectorConfig(spikeThreshold: spikeThreshold, minRiseRate: riseRate,
                             minCrestFactor: crestFactor, minConfirmations: confirmations,
                             warmupSamples: warmupSamples,
                             intensityFloor: Detection.Mic.intensityFloor,
                             intensityCeiling: Detection.Mic.intensityCeiling)
    }

    public static func headphoneMotion(
        spikeThreshold: Float = Float(Defaults.hpSpikeThreshold),
        riseRate: Float = Float(Defaults.hpRiseRate),
        crestFactor: Float = Float(Defaults.hpCrestFactor),
        confirmations: Int = Defaults.hpConfirmations,
        warmupSamples: Int = Defaults.hpWarmup
    ) -> ImpactDetectorConfig {
        ImpactDetectorConfig(spikeThreshold: spikeThreshold, minRiseRate: riseRate,
                             minCrestFactor: crestFactor, minConfirmations: confirmations,
                             warmupSamples: warmupSamples,
                             intensityFloor: Detection.Headphone.intensityFloor,
                             intensityCeiling: Detection.Headphone.intensityCeiling)
    }
}

/// Runs the gate pipeline on preprocessed sensor data and emits 0–1 intensity impacts.
/// One instance per adapter. Runs on the adapter's callback thread (not main thread).
/// Thread safety: mutable state protected by OSAllocatedUnfairLock.
public final class ImpactDetector: Sendable {
    private let config: ImpactDetectorConfig
    private let adapterName: String
    private static let rmsAlpha: Float = Detection.rmsAlpha

    private struct State {
        var window: [(timestamp: Date, magnitude: Float)] = []
        var sampleCount = 0
        var backgroundMeanSq: Float
    }
    private let state: OSAllocatedUnfairLock<State>

    public init(config: ImpactDetectorConfig, adapterName: String) {
        self.config = config
        self.adapterName = adapterName
        self.state = OSAllocatedUnfairLock(initialState: State(
            backgroundMeanSq: config.intensityFloor * config.intensityFloor
        ))
    }

    /// Process a preprocessed magnitude (in sensor-native units).
    /// Returns 0–1 intensity if an impact is detected, nil otherwise.
    public func process(magnitude: Float, timestamp: Date) -> Float? {
        state.withLock { s in
            s.sampleCount += 1

            // Background RMS (slow EMA)
            let magSq = magnitude * magnitude
            s.backgroundMeanSq = Self.rmsAlpha * magSq + (1 - Self.rmsAlpha) * s.backgroundMeanSq
            let backgroundRMS = sqrtf(s.backgroundMeanSq)

            // Accumulate in window and prune
            s.window.append((timestamp, magnitude))
            let cutoff = timestamp.addingTimeInterval(-config.windowDuration)
            s.window.removeAll { $0.timestamp < cutoff }

            // Warmup gate
            guard s.sampleCount >= config.warmupSamples else { return nil }

            // Spike threshold
            guard magnitude >= config.spikeThreshold else { return nil }

            // Rise rate gate — computed from the window, not accumulated globally.
            // Peak rise rate = maximum consecutive-sample increase within the window.
            var windowPeakRise: Float = 0
            for i in 1..<s.window.count {
                let rise = s.window[i].magnitude - s.window[i - 1].magnitude
                if rise > windowPeakRise { windowPeakRise = rise }
            }
            guard windowPeakRise >= config.minRiseRate else {
                log.debug("entity:Gate blocked=riseRate adapter=\(adapterName) rise=\(String(format: "%.4f", windowPeakRise)) required=\(config.minRiseRate)")
                return nil
            }

            // Crest factor gate
            if backgroundRMS > 0 {
                let windowPeak = s.window.map(\.magnitude).max() ?? 0
                let crest = windowPeak / backgroundRMS
                guard crest >= config.minCrestFactor else {
                    log.debug("entity:Gate blocked=crestFactor adapter=\(adapterName) crest=\(String(format: "%.2f", crest)) required=\(config.minCrestFactor)")
                    return nil
                }
            }

            // Confirmation count
            let confirmed = s.window.filter { $0.magnitude >= config.spikeThreshold }.count
            guard confirmed >= config.minConfirmations else {
                log.debug("entity:Gate blocked=confirmations adapter=\(adapterName) count=\(confirmed) required=\(config.minConfirmations)")
                return nil
            }

            // Impact detected — compute intensity in 0–1
            let intensityRange = max(config.intensityCeiling - config.intensityFloor, Detection.intensityEpsilon)
            let intensity = ((magnitude - config.intensityFloor) / intensityRange).clamped(to: 0...1)

            log.debug("entity:Impact adapter=\(adapterName) intensity=\(String(format: "%.2f", intensity)) mag=\(String(format: "%.4f", magnitude)) crest=\(String(format: "%.1f", backgroundRMS > 0 ? magnitude / backgroundRMS : 0))")

            return intensity
        }
    }
}
