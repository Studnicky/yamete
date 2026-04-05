import Foundation

private let log = AppLog(category: "SensorFusion")

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
    var minCrestFactor: Float = 6.0
    var minRiseRate: Float = 0.010
    var minConfirmations: Int = 3
    var minRearmDuration: TimeInterval = 0.50
    var minWarmupSamples: Int = 50
    var bandpassLowHz: Float = 20.0
    var bandpassHighHz: Float = 25.0
}

@MainActor
final class SensorFusionEngine {
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

    private var bySource: [String: [SamplePoint]] = [:]
    private var hpFiltersBySource: [String: HighPassFilter] = [:]
    private var lpFiltersBySource: [String: LowPassFilter] = [:]
    private var sampleCountBySource: [String: Int] = [:]
    private var rmsBySource: [String: Float] = [:]
    private var prevFilteredMagBySource: [String: Float] = [:]
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

    func ingest(_ sample: SensorSample, activeSources: Set<String>) -> FusedImpact? {
        let now = sample.timestamp

        let hp = hpFilterForSource(sample.source)
        let lp = lpFilterForSource(sample.source)
        let filtered = lp.process(hp.process(sample.value))
        sampleCountBySource[sample.source, default: 0] += 1
        let filteredMag = filtered.magnitude

        // Rise rate: how fast the signal magnitude increased from previous sample
        let prevMag = prevFilteredMagBySource[sample.source, default: 0]
        let riseRate = filteredMag - prevMag
        prevFilteredMagBySource[sample.source] = filteredMag

        // Slow-tracking RMS of all samples. Brief impacts barely move it;
        // sustained vibrations raise it, lowering the crest factor.
        let rmsAlpha: Float = 0.005
        let prevRmsSq = rmsBySource[sample.source, default: 0]
        let rmsSq = prevRmsSq + rmsAlpha * (filteredMag * filteredMag - prevRmsSq)
        rmsBySource[sample.source] = rmsSq
        let rms = sqrtf(max(rmsSq, 1e-12))

        #if DEBUG
        if filteredMag > diagPeakFiltered { diagPeakFiltered = filteredMag }
        if riseRate > diagPeakRise { diagPeakRise = riseRate }
        diagCounter += 1
        if diagCounter % 250 == 0 {
            log.debug("entity:FusionDiag n=\(diagCounter) peak=\(String(format: "%.4f", diagPeakFiltered)) rms=\(String(format: "%.4f", rms)) rise=\(String(format: "%.4f", diagPeakRise)) thr=\(config.spikeThreshold) crest=\(config.minCrestFactor) riseReq=\(config.minRiseRate)")
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

        let peakMag = participating.map(\.magnitude).max() ?? 0

        // Gate 1: Crest factor — peak must be well above background
        let crestFactor = peakMag / rms
        guard crestFactor >= config.minCrestFactor else {
            log.debug("entity:FusionGate blocked=crest peak=\(String(format: "%.4f", peakMag)) rms=\(String(format: "%.4f", rms)) crest=\(String(format: "%.1f", crestFactor))")
            return nil
        }

        // Gate 2: Rise rate — direct impacts rise faster than transmitted vibrations
        guard riseRate >= config.minRiseRate else {
            log.debug("entity:FusionGate blocked=riseRate rise=\(String(format: "%.4f", riseRate)) required=\(config.minRiseRate)")
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

    private func hpFilterForSource(_ source: String) -> HighPassFilter {
        if let existing = hpFiltersBySource[source] { return existing }
        let filter = HighPassFilter(cutoffHz: hpCutoffHz, sampleRate: 50.0)
        hpFiltersBySource[source] = filter
        return filter
    }

    private func lpFilterForSource(_ source: String) -> LowPassFilter {
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

    private func candidatePeaks(activeSources: Set<String>) -> [(source: String, vector: Vec3, magnitude: Float)] {
        activeSources.compactMap { source in
            guard sampleCountBySource[source, default: 0] >= config.minWarmupSamples else { return nil }
            guard let peak = bySource[source]?.max(by: { $0.value.magnitude < $1.value.magnitude }) else {
                return nil
            }
            return (source: source, vector: peak.value, magnitude: peak.value.magnitude)
        }
    }
}
