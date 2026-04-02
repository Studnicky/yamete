import Foundation

private let log = AppLog(category: "ImpactDetector")

final class ImpactDetector {
    private let filter = HighPassFilter()
    private let config: DetectorConfig
    private let detectors: [any SignalDetector]
    private var recentSamples: [Vec3] = []
    private let windowSize = 10
    private let requiredVotes = 2

    var sensitivity: Double = 0.6 {
        didSet {
            guard sensitivity != oldValue else { return }
            applyThresholds()
        }
    }

    init(config: DetectorConfig = DetectorConfig()) {
        self.config = config
        detectors = [
            STALTADetector(config: config),
            CUSUMDetector(config: config),
            KurtosisDetector(config: config),
            PeakMADDetector(config: config),
        ]
        applyThresholds()
    }

    func process(_ raw: Vec3) -> ImpactEvent? {
        let filtered = filter.process(raw)
        let mag = filtered.magnitude

        recentSamples.append(filtered)
        if recentSamples.count > windowSize { recentSamples.removeFirst() }

        let votes = detectors.filter { $0.process(mag) }.count
        guard votes >= requiredVotes else { return nil }

        let peak = recentSamples.max(by: { $0.magnitude < $1.magnitude }) ?? filtered
        log.info("entity:ImpactEvent wasGeneratedBy activity:Detection votes=\(votes) peak=\(String(format: "%.3f", peak.magnitude))g")
        return ImpactEvent(timestamp: Date(), amplitude: peak)
    }

    func reset() {
        filter.reset()
        detectors.forEach { $0.reset() }
        recentSamples = []
    }

    private func applyThresholds() {
        let s = Float(sensitivity)
        config.staltaOnThreshold  = 8.0 - s * 5.0
        config.staltaOffThreshold = max(1.2, config.staltaOnThreshold * 0.4)
        config.cusumThreshold     = 2.0 - s * 1.5
        config.peakMADThreshold   = 12.0 - s * 8.0
        config.kurtosisThreshold  = 20.0 - s * 12.0
        log.debug("entity:DetectorThresholds wasDerivedFrom entity:Sensitivity value=\(String(format: "%.2f", s)) stalta=\(String(format: "%.1f", config.staltaOnThreshold)) cusum=\(String(format: "%.2f", config.cusumThreshold)) peakMAD=\(String(format: "%.1f", config.peakMADThreshold)) kurtosis=\(String(format: "%.1f", config.kurtosisThreshold))")
    }
}
