import Foundation

private let log = AppLog(category: "ImpactDetection")

/// Impact detection engine with multi-stage filtering to reject non-impact vibrations.
///
/// Pipeline:
///   1. Bandpass filter (HP + LP) removes gravity, floor vibrations, and electronic noise
///   2. Spike threshold gates minimum filtered magnitude
///   3. Crest factor requires peak >> background RMS (rejects sustained vibration)
///   4. Rise rate requires fast signal onset (rejects slow transmitted vibrations)
///   5. Confirmation count requires multiple above-threshold samples in the window
///   6. Time-based rearm prevents retriggering from filter ringing
/// Configurable detection parameters for the impact detection engine.
struct DetectionConfig: Equatable {
    var spikeThreshold: Float = 0.020
    var minCrestFactor: Float = 4.0
    var minRiseRate: Float = 0.010
    var minConfirmations: Int = 3
    var minRearmDuration: TimeInterval = 0.50
    var minWarmupSamples: Int = 50
    var bandpassLowHz: Float = 20.0
    var bandpassHighHz: Float = 25.0
}

@MainActor
final class ImpactDetectionEngine {
    struct FusedImpact {
        let timestamp: Date
        let amplitude: Vec3
        let confidence: Float
    }

    private struct SamplePoint {
        let timestamp: Date
        let value: Vec3
    }

    private let windowDuration: TimeInterval
    private(set) var config: DetectionConfig

    private var bySource: [SensorID: [SamplePoint]] = [:]
    private var hpFiltersBySource: [SensorID: HighPassFilter] = [:]
    private var lpFiltersBySource: [SensorID: LowPassFilter] = [:]
    private var sampleCountBySource: [SensorID: Int] = [:]
    private var prevFilteredMagBySource: [SensorID: Float] = [:]
    private var peakRiseRateBySource: [SensorID: Float] = [:]
    private var lastTriggerAt: Date = .distantPast
    private var hpCutoffHz: Float = 18.0
    private var lpCutoffHz: Float = 25.0
    #if DEBUG
    private var diagCounter = 0
    private var diagPeakFiltered: Float = 0
    private var diagPeakRise: Float = 0
    #endif

    init(windowDuration: TimeInterval = 0.12, config: DetectionConfig = DetectionConfig()) {
        self.windowDuration = windowDuration
        self.config = config
    }

    /// Atomically update detection parameters. Recreates bandpass filters only if cutoffs changed.
    func configure(_ newConfig: DetectionConfig) {
        let oldConfig = config
        config = newConfig
        if newConfig.bandpassLowHz != oldConfig.bandpassLowHz {
            hpCutoffHz = newConfig.bandpassLowHz
            hpFiltersBySource.removeAll()
        }
        if newConfig.bandpassHighHz != oldConfig.bandpassHighHz {
            lpCutoffHz = newConfig.bandpassHighHz
            lpFiltersBySource.removeAll()
        }
    }

    func ingest(_ sample: SensorSample, activeSources: Set<SensorID>) -> FusedImpact? {
        let now = sample.timestamp

        let hp = hpFilterForSource(sample.source)
        let lp = lpFilterForSource(sample.source)
        let filtered = lp.process(hp.process(sample.value))
        sampleCountBySource[sample.source, default: 0] += 1
        let filteredMag = filtered.magnitude

        // Rise rate: track peak rise rate in the detection window.
        // The instantaneous rise rate on the current sample may be negative (downslope)
        // even during a valid impact — the sharp rise happened earlier in the window.
        let prevMag = prevFilteredMagBySource[sample.source, default: 0]
        let riseRate = filteredMag - prevMag
        prevFilteredMagBySource[sample.source] = filteredMag
        if riseRate > (peakRiseRateBySource[sample.source] ?? 0) {
            peakRiseRateBySource[sample.source] = riseRate
        }

        #if DEBUG
        if filteredMag > diagPeakFiltered { diagPeakFiltered = filteredMag }
        if riseRate > diagPeakRise { diagPeakRise = riseRate }
        diagCounter += 1
        if diagCounter % 250 == 0 {
            log.debug("entity:FusionDiag n=\(diagCounter) peak=\(String(format: "%.4f", diagPeakFiltered)) rise=\(String(format: "%.4f", diagPeakRise)) thr=\(config.spikeThreshold) riseReq=\(config.minRiseRate)")
            diagPeakFiltered = 0
            diagPeakRise = 0
        }
        #endif

        // Accumulate filtered samples in rolling window
        var sourceSamples = bySource[sample.source] ?? []
        sourceSamples.append(SamplePoint(timestamp: now, value: filtered))
        bySource[sample.source] = sourceSamples

        prune(before: now.addingTimeInterval(-windowDuration))

        let required = requiredConsensusCount(activeSourceCount: activeSources.count)
        let candidates = candidatePeaks(activeSources: activeSources)

        let participating = candidates.filter { $0.magnitude >= config.spikeThreshold }
        let hasConsensus = participating.count >= required
        let timeSinceLastTrigger = now.timeIntervalSince(lastTriggerAt)

        guard hasConsensus, timeSinceLastTrigger >= config.minRearmDuration else { return nil }

        // Gate 1: Rise rate — peak rise rate within the window, not instantaneous.
        // A direct impact's sharp onset is captured even if the current sample is on the downslope.
        let windowPeakRise = peakRiseRateBySource[sample.source] ?? 0
        guard windowPeakRise >= config.minRiseRate else {
            log.debug("entity:FusionGate blocked=riseRate rise=\(String(format: "%.4f", windowPeakRise)) required=\(config.minRiseRate)")
            return nil
        }

        // Gate 3: Confirmation count — require multiple above-threshold samples in window
        // Direct impacts produce a cluster of high samples; single-jolt events produce fewer
        let aboveThreshold = bySource[sample.source]?.filter { $0.value.magnitude >= config.spikeThreshold }.count ?? 0
        guard aboveThreshold >= config.minConfirmations else {
            log.debug("entity:FusionGate blocked=confirmations count=\(aboveThreshold) required=\(config.minConfirmations)")
            return nil
        }

        lastTriggerAt = now
        peakRiseRateBySource[sample.source] = 0

        let sum = participating.reduce(Vec3.zero) { partial, entry in
            Vec3(
                x: partial.x + entry.vector.x,
                y: partial.y + entry.vector.y,
                z: partial.z + entry.vector.z
            )
        }
        let count = Float(max(1, participating.count))
        let fused = Vec3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
        let confidence = Float(participating.count) / Float(max(required, 1))

        return FusedImpact(timestamp: now, amplitude: fused, confidence: confidence)
    }

    private func hpFilterForSource(_ source: SensorID) -> HighPassFilter {
        if let existing = hpFiltersBySource[source] { return existing }
        let filter = HighPassFilter(cutoffHz: hpCutoffHz, sampleRate: 50.0)
        hpFiltersBySource[source] = filter
        return filter
    }

    private func lpFilterForSource(_ source: SensorID) -> LowPassFilter {
        if let existing = lpFiltersBySource[source] { return existing }
        let filter = LowPassFilter(cutoffHz: lpCutoffHz, sampleRate: 50.0)
        lpFiltersBySource[source] = filter
        return filter
    }

    private func prune(before cutoff: Date) {
        for key in bySource.keys {
            bySource[key]?.removeAll { $0.timestamp < cutoff }
            if bySource[key]?.isEmpty == true {
                bySource.removeValue(forKey: key)
            }
        }
    }

    private func requiredConsensusCount(activeSourceCount: Int) -> Int {
        switch activeSourceCount {
        case ..<2:
            return 1
        case 2...3:
            return 2
        default:
            return max(2, Int(ceil(Double(activeSourceCount) * 0.6)))
        }
    }

    private func candidatePeaks(activeSources: Set<SensorID>) -> [(source: SensorID, vector: Vec3, magnitude: Float)] {
        activeSources.compactMap { source in
            guard sampleCountBySource[source, default: 0] >= config.minWarmupSamples else { return nil }
            guard let peak = bySource[source]?.max(by: { $0.value.magnitude < $1.value.magnitude }) else {
                return nil
            }
            return (source: source, vector: peak.value, magnitude: peak.value.magnitude)
        }
    }
}
