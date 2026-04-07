#if canImport(YameteCore)
import YameteCore
#endif
import Foundation

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
                windowDuration: TimeInterval = 0.12,
                intensityFloor: Float, intensityCeiling: Float) {
        self.spikeThreshold = spikeThreshold; self.minRiseRate = minRiseRate
        self.minCrestFactor = minCrestFactor; self.minConfirmations = minConfirmations
        self.warmupSamples = warmupSamples; self.windowDuration = windowDuration
        self.intensityFloor = intensityFloor; self.intensityCeiling = intensityCeiling
    }
}

/// Runs the gate pipeline on preprocessed sensor data and emits 0–1 intensity impacts.
/// One instance per adapter. Runs on the adapter's callback thread (not main thread).
/// Thread safety: each adapter creates its own instance; no shared access.
public final class ImpactDetector: @unchecked Sendable {
    private let config: ImpactDetectorConfig
    private let adapterName: String

    private var window: [(timestamp: Date, magnitude: Float)] = []
    private var sampleCount = 0
    private var backgroundMeanSq: Float
    private static let rmsAlpha: Float = 0.02

    public init(config: ImpactDetectorConfig, adapterName: String) {
        self.config = config
        self.adapterName = adapterName
        self.backgroundMeanSq = config.intensityFloor * config.intensityFloor
    }

    /// Process a preprocessed magnitude (in sensor-native units).
    /// Returns 0–1 intensity if an impact is detected, nil otherwise.
    public func process(magnitude: Float, timestamp: Date) -> Float? {
        sampleCount += 1

        // Background RMS (slow EMA)
        let magSq = magnitude * magnitude
        backgroundMeanSq = Self.rmsAlpha * magSq + (1 - Self.rmsAlpha) * backgroundMeanSq
        let backgroundRMS = sqrtf(backgroundMeanSq)

        // Accumulate in window and prune
        window.append((timestamp, magnitude))
        let cutoff = timestamp.addingTimeInterval(-config.windowDuration)
        window.removeAll { $0.timestamp < cutoff }

        // Warmup gate
        guard sampleCount >= config.warmupSamples else { return nil }

        // Spike threshold
        guard magnitude >= config.spikeThreshold else { return nil }

        // Rise rate gate — computed from the window, not accumulated globally.
        // Peak rise rate = maximum consecutive-sample increase within the window.
        var windowPeakRise: Float = 0
        for i in 1..<window.count {
            let rise = window[i].magnitude - window[i - 1].magnitude
            if rise > windowPeakRise { windowPeakRise = rise }
        }
        guard windowPeakRise >= config.minRiseRate else {
            log.debug("entity:Gate blocked=riseRate adapter=\(adapterName) rise=\(String(format: "%.4f", windowPeakRise)) required=\(config.minRiseRate)")
            return nil
        }

        // Crest factor gate
        if backgroundRMS > 0 {
            let windowPeak = window.map(\.magnitude).max() ?? 0
            let crest = windowPeak / backgroundRMS
            guard crest >= config.minCrestFactor else {
                log.debug("entity:Gate blocked=crestFactor adapter=\(adapterName) crest=\(String(format: "%.2f", crest)) required=\(config.minCrestFactor)")
                return nil
            }
        }

        // Confirmation count
        let confirmed = window.filter { $0.magnitude >= config.spikeThreshold }.count
        guard confirmed >= config.minConfirmations else {
            log.debug("entity:Gate blocked=confirmations adapter=\(adapterName) count=\(confirmed) required=\(config.minConfirmations)")
            return nil
        }

        // Impact detected — compute intensity in 0–1
        let intensityRange = max(config.intensityCeiling - config.intensityFloor, 0.001)
        let intensity = ((magnitude - config.intensityFloor) / intensityRange).clamped(to: 0...1)

        log.debug("entity:Impact adapter=\(adapterName) intensity=\(String(format: "%.2f", intensity)) mag=\(String(format: "%.4f", magnitude)) crest=\(String(format: "%.1f", backgroundRMS > 0 ? magnitude / backgroundRMS : 0))")

        return intensity
    }
}
