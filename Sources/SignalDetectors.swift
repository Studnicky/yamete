import Foundation

// MARK: - Protocol

protocol SignalDetector: AnyObject {
    func process(_ sample: Float) -> Bool
    func reset()
}

// MARK: - DetectorConfig

/// Shared (reference-type) config so that threshold changes propagate to all
/// detectors without rebuilding them.  Buffer-size fields are only read at
/// init; threshold fields are read every ``process`` call.
final class DetectorConfig {
    // STA/LTA
    var staltaStaN: Int   = 5
    var staltaLtaN: Int   = 50
    var staltaOnThreshold:  Float = 4.0
    var staltaOffThreshold: Float = 1.5

    // CUSUM
    var cusumAlpha:     Float = 0.02
    var cusumThreshold: Float = 0.5

    // Kurtosis
    var kurtosisMinSamples: Int   = 30
    var kurtosisThreshold:  Float = 10.0

    // PeakMAD
    var peakMADMinSamples:         Int   = 30
    var peakMADConsistencyConstant: Float = 1.4826
    var peakMADThreshold:          Float = 8.0

    init() {}
}

// MARK: - STALTADetector

final class STALTADetector: SignalDetector {
    private let config: DetectorConfig
    private var staBuffer: RingBuffer
    private var ltaBuffer: RingBuffer
    private var isTriggered = false
    private var holdSamples = 0

    init(config: DetectorConfig) {
        self.config = config
        staBuffer = RingBuffer(capacity: config.staltaStaN)
        ltaBuffer = RingBuffer(capacity: config.staltaLtaN)
    }

    func process(_ sample: Float) -> Bool {
        staBuffer.push(abs(sample))
        ltaBuffer.push(abs(sample))
        guard ltaBuffer.isFull else { return false }

        let staMean = staBuffer.sumAbs() / Float(staBuffer.currentCount)
        let ltaMean = ltaBuffer.sumAbs() / Float(ltaBuffer.currentCount)
        guard ltaMean > 1e-6 else { return false }

        let ratio = staMean / ltaMean
        let wasTriggered = isTriggered

        if !isTriggered && ratio >= config.staltaOnThreshold {
            isTriggered = true
            holdSamples = config.staltaStaN
        } else if isTriggered {
            holdSamples -= 1
            if holdSamples <= 0 && ratio < config.staltaOffThreshold { isTriggered = false }
        }

        return !wasTriggered && isTriggered
    }

    func reset() {
        staBuffer = RingBuffer(capacity: config.staltaStaN)
        ltaBuffer = RingBuffer(capacity: config.staltaLtaN)
        isTriggered = false
    }
}

// MARK: - CUSUMDetector

final class CUSUMDetector: SignalDetector {
    private let config: DetectorConfig
    private var cusum: Float = 0
    private var inEvent = false

    init(config: DetectorConfig) { self.config = config }

    func process(_ sample: Float) -> Bool {
        cusum = max(0, cusum + abs(sample) - config.cusumAlpha)
        let triggered = cusum > config.cusumThreshold
        let rising = !inEvent && triggered
        inEvent = triggered
        if !triggered { cusum *= 0.9 }
        return rising
    }

    func reset() { cusum = 0; inEvent = false }
}

// MARK: - KurtosisDetector

final class KurtosisDetector: SignalDetector {
    private let config: DetectorConfig
    private var buffer: RingBuffer
    private var inEvent = false

    init(config: DetectorConfig) {
        self.config = config
        buffer = RingBuffer(capacity: config.kurtosisMinSamples)
    }

    func process(_ sample: Float) -> Bool {
        buffer.push(sample)
        guard buffer.isFull else { return false }

        let samples = buffer.asArray()
        let n = Float(samples.count)
        let mean = samples.reduce(0, +) / n
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        guard variance > 1e-10 else { inEvent = false; return false }

        let m4 = samples.map { let d = $0 - mean; return d*d*d*d }.reduce(0, +) / n
        let triggered = (m4 / (variance * variance)) > config.kurtosisThreshold
        let rising = !inEvent && triggered
        inEvent = triggered
        return rising
    }

    func reset() { buffer = RingBuffer(capacity: config.kurtosisMinSamples); inEvent = false }
}

// MARK: - PeakMADDetector

final class PeakMADDetector: SignalDetector {
    private let config: DetectorConfig
    private var buffer: RingBuffer
    private var inEvent = false

    init(config: DetectorConfig) {
        self.config = config
        buffer = RingBuffer(capacity: config.peakMADMinSamples)
    }

    func process(_ sample: Float) -> Bool {
        buffer.push(abs(sample))
        guard buffer.isFull else { return false }

        let samples = buffer.asArray().sorted()
        let median = samples[samples.count / 2]
        let mad = samples.map { abs($0 - median) }.sorted()[samples.count / 2]
            * config.peakMADConsistencyConstant
        guard mad > 1e-6 else { return false }

        let triggered = (samples.last ?? 0) / mad > config.peakMADThreshold
        let rising = !inEvent && triggered
        inEvent = triggered
        return rising
    }

    func reset() { buffer = RingBuffer(capacity: config.peakMADMinSamples); inEvent = false }
}
