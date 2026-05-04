#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
import os

// MARK: - GyroDetector — six-gate consensus pipeline for the BMI286 gyro
//
// Sister to `ImpactDetector` but tuned for angular velocity in deg/s. The
// inputs are sample magnitudes (sqrtf(x²+y²+z²)) decoded from the SPU HID
// report. The output of `process` is a 0–1 intensity when a spike clears
// every gate, or `nil` when a gate rejects the sample. The detector does
// not own debounce — the source layer (`GyroscopeSource`) owns
// `lastFiredAt` since debounce semantics differ between the impact-fusion
// path and the direct-publish reaction path.
//
// Gates (six, in order):
//   1. Sample-count warmup — discards the first `warmupSamples` reports.
//   2. Spike-threshold floor — magnitude must reach `spikeThreshold`.
//   3. Rise-rate gate — peak consecutive-sample increase across the
//      window must reach `minRiseRate`.
//   4. Crest-factor gate — peak magnitude must exceed background RMS by
//      `minCrestFactor` (skipped when background RMS is 0).
//   5. Confirmation gate — at least `minConfirmations` samples in the
//      window must clear the spike threshold.
//   6. Cooldown — the detector itself does not enforce cooldown; that is
//      the source's responsibility (different reactions debounce
//      differently — `ReactionsConfig.gyroDebounce`).
//
// Concurrency: lock-protected mutable state (`OSAllocatedUnfairLock`),
// matching `ImpactDetector`. Runs on the broker's HID worker thread —
// callers must NOT hold any non-Sendable state across the call.

private let log = AppLog(category: "GyroDetector")

public struct GyroDetectorConfig: Sendable {
    public let spikeThreshold: Float
    public let minRiseRate: Float
    public let minCrestFactor: Float
    public let minConfirmations: Int
    public let warmupSamples: Int
    public let windowDuration: TimeInterval
    public let intensityFloor: Float
    public let intensityCeiling: Float

    public init(spikeThreshold: Float, minRiseRate: Float, minCrestFactor: Float,
                minConfirmations: Int, warmupSamples: Int,
                windowDuration: TimeInterval = Detection.windowDuration,
                intensityFloor: Float = Detection.Gyro.intensityFloor,
                intensityCeiling: Float = Detection.Gyro.intensityCeiling) {
        self.spikeThreshold = spikeThreshold
        self.minRiseRate = minRiseRate
        self.minCrestFactor = minCrestFactor
        self.minConfirmations = minConfirmations
        self.warmupSamples = warmupSamples
        self.windowDuration = windowDuration
        self.intensityFloor = intensityFloor
        self.intensityCeiling = intensityCeiling
    }

    public static func gyroscope(
        spikeThreshold: Float = Float(Defaults.gyroSpikeThreshold),
        riseRate: Float = Float(Defaults.gyroRiseRate),
        crestFactor: Float = Float(Defaults.gyroCrestFactor),
        confirmations: Int = Defaults.gyroConfirmations,
        warmupSamples: Int = Defaults.gyroWarmup
    ) -> GyroDetectorConfig {
        GyroDetectorConfig(
            spikeThreshold: spikeThreshold,
            minRiseRate: riseRate,
            minCrestFactor: crestFactor,
            minConfirmations: confirmations,
            warmupSamples: warmupSamples
        )
    }
}

public final class GyroDetector: Sendable {
    private let config: GyroDetectorConfig
    private static let rmsAlpha: Float = Detection.rmsAlpha

    private struct State {
        var window: [(timestamp: Date, magnitude: Float)] = []
        var sampleCount = 0
        var backgroundMeanSq: Float
    }
    private let state: OSAllocatedUnfairLock<State>

    public init(config: GyroDetectorConfig) {
        self.config = config
        self.state = OSAllocatedUnfairLock(initialState: State(
            backgroundMeanSq: config.intensityFloor * config.intensityFloor
        ))
    }

    /// Process one sample. Returns 0–1 intensity if the sample clears every
    /// gate, nil otherwise. Sample-count is bumped FIRST so that the warmup
    /// gate suppresses the initial tail of reports unconditionally.
    public func process(magnitude: Float, timestamp: Date) -> Float? {
        state.withLock { s in
            s.sampleCount += 1

            // Background RMS (slow EMA).
            let magSq = magnitude * magnitude
            s.backgroundMeanSq = Self.rmsAlpha * magSq + (1 - Self.rmsAlpha) * s.backgroundMeanSq
            let backgroundRMS = sqrtf(s.backgroundMeanSq)

            s.window.append((timestamp, magnitude))
            let cutoff = timestamp.addingTimeInterval(-config.windowDuration)
            s.window.removeAll { $0.timestamp < cutoff }

            // Gate 1: warmup.
            guard s.sampleCount >= config.warmupSamples else { return nil }

            // Gate 2: spike threshold floor.
            guard magnitude > config.spikeThreshold else { return nil }

            // Gate 3: rise-rate.
            var windowPeakRise: Float = 0
            for i in 1..<s.window.count {
                let rise = s.window[i].magnitude - s.window[i - 1].magnitude
                if rise > windowPeakRise { windowPeakRise = rise }
            }
            guard windowPeakRise >= config.minRiseRate else {
                log.debug("entity:Gate blocked=riseRate adapter=Gyroscope rise=\(String(format: "%.4f", windowPeakRise)) required=\(config.minRiseRate)")
                return nil
            }

            // Gate 4: crest factor (only when background RMS is non-zero).
            if backgroundRMS > 0 {
                let windowPeak = s.window.map(\.magnitude).max() ?? 0
                let crest = windowPeak / backgroundRMS
                guard crest >= config.minCrestFactor else {
                    log.debug("entity:Gate blocked=crestFactor adapter=Gyroscope crest=\(String(format: "%.2f", crest)) required=\(config.minCrestFactor)")
                    return nil
                }
            }

            // Gate 5: confirmations.
            let confirmed = s.window.filter { $0.magnitude > config.spikeThreshold }.count
            guard confirmed >= config.minConfirmations else {
                log.debug("entity:Gate blocked=confirmations adapter=Gyroscope count=\(confirmed) required=\(config.minConfirmations)")
                return nil
            }

            // All gates clear — compute 0-1 intensity.
            let intensityRange = max(config.intensityCeiling - config.intensityFloor, Detection.intensityEpsilon)
            let intensity = ((magnitude - config.intensityFloor) / intensityRange).clamped(to: 0...1)

            log.debug("entity:GyroSpike intensity=\(String(format: "%.2f", intensity)) mag=\(String(format: "%.2f", magnitude)) deg/s")

            return intensity
        }
    }
}
