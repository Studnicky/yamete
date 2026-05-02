import XCTest
@testable import YameteCore
@testable import SensorKit

/// Matrix coverage of the per-adapter `ImpactDetector` gate pipeline.
///
/// Each cell pins ONE production guard in `Sources/SensorKit/ImpactDetector.swift`
/// to a specific synthetic sample sequence. The cells are deliberately
/// asymmetric — every cell is calibrated to clear ALL OTHER gates so the
/// gate under test is the only thing that can decide the outcome. The
/// failure messages embed `[gate=...]` coordinates that match the
/// substrings pinned in `Tests/Mutation/mutation-catalog.json`.
///
/// Bug class: someone "tunes" a threshold (warmup / spike / rise rate /
/// crest / confirmations) and the gate stops blocking. Removing the gate
/// in source MUST flip a cell here from green to red. Mutation tests
/// re-verify that pairing on every CI run.
final class MatrixImpactDetector_Tests: XCTestCase {

    // MARK: - Helpers

    /// Detector config tuned to a single gate. Every other gate is set
    /// permissively so the cell asserts the named gate's behaviour and
    /// nothing else.
    private func config(
        spikeThreshold: Float = 0.0001,
        minRiseRate: Float = 0,
        minCrestFactor: Float = 0,
        minConfirmations: Int = 1,
        warmupSamples: Int = 0,
        windowDuration: TimeInterval = 0.20,
        intensityFloor: Float = 0.0001,
        intensityCeiling: Float = 1.0
    ) -> ImpactDetectorConfig {
        ImpactDetectorConfig(
            spikeThreshold: spikeThreshold,
            minRiseRate: minRiseRate,
            minCrestFactor: minCrestFactor,
            minConfirmations: minConfirmations,
            warmupSamples: warmupSamples,
            windowDuration: windowDuration,
            intensityFloor: intensityFloor,
            intensityCeiling: intensityCeiling
        )
    }

    // MARK: - Warmup gate (ImpactDetector.swift line 129)

    /// Removing the `warmupSamples` guard would cause the very first
    /// sample to detect even when warmupSamples > sampleCount. The cell
    /// asserts a strong sample BEFORE warmup completes returns nil; the
    /// `[gate=warmup]` substring pins this gate in the catalog.
    func testWarmupGate_belowSampleCount_returnsNil() {
        let detector = ImpactDetector(
            config: config(warmupSamples: 50),
            adapterName: "matrix-warmup"
        )
        // First 49 samples are below warmup threshold (sampleCount=1..49).
        let now = Date()
        for i in 0..<49 {
            let result = detector.process(
                magnitude: 0.500,
                timestamp: now.addingTimeInterval(Double(i) * 0.02)
            )
            XCTAssertNil(
                result,
                "[gate=warmup] sample \(i + 1)/50 must be rejected during warmup"
            )
        }
    }

    // MARK: - Spike threshold gate (ImpactDetector.swift line 132)

    /// Removing the `spikeThreshold` guard would cause sub-threshold
    /// magnitudes to detect. The cell feeds a sample below the
    /// configured spike threshold with `minConfirmations=0` (so the
    /// downstream confirmations gate, which ALSO uses spikeThreshold,
    /// cannot mask the mutation). The `[gate=spike]` substring pins
    /// this gate.
    func testSpikeGate_belowThreshold_returnsNil() {
        let detector = ImpactDetector(
            config: config(spikeThreshold: 0.500, minConfirmations: 0),
            adapterName: "matrix-spike"
        )
        // Magnitude well below the spike threshold — must be rejected.
        // With minConfirmations=0, the confirmations gate is permissive,
        // so the spike gate is the SOLE decider.
        let result = detector.process(magnitude: 0.100, timestamp: Date())
        XCTAssertNil(
            result,
            "[gate=spike] magnitude 0.100 below threshold 0.500 must NOT detect"
        )
    }

    // MARK: - Rise rate gate (ImpactDetector.swift line 141)

    /// Removing the `minRiseRate` guard would let a slow ramp detect
    /// despite a sub-threshold consecutive-sample rise. The cell builds
    /// a window where the maximum rise between any two consecutive
    /// samples is < minRiseRate, with the final magnitude clearing
    /// every other gate. The `[gate=riseRate]` substring pins this gate.
    func testRiseRateGate_gradualRamp_returnsNil() {
        let detector = ImpactDetector(
            config: config(
                spikeThreshold: 0.100,
                minRiseRate: 0.500,
                minConfirmations: 1
            ),
            adapterName: "matrix-rise"
        )
        // 10-sample ramp with consecutive rises of exactly 0.020 — well
        // below the 0.500 minRiseRate. Final magnitude (0.300) clears
        // the spike threshold (0.100) but the peak rise within the
        // window (0.020) does not. Removing the gate would let the
        // final sample detect.
        let now = Date()
        var lastResult: Float?
        for i in 0..<10 {
            let mag: Float = 0.100 + Float(i) * 0.020
            lastResult = detector.process(
                magnitude: mag,
                timestamp: now.addingTimeInterval(Double(i) * 0.02)
            )
        }
        XCTAssertNil(
            lastResult,
            "[gate=riseRate] gradual ramp with peak consecutive rise 0.020 < min 0.500 must NOT detect"
        )
    }

    // MARK: - Crest factor gate (ImpactDetector.swift line 150)

    /// Removing the `minCrestFactor` guard would let a sample fire
    /// against an elevated background RMS where the crest factor is
    /// below the threshold. The cell drives a long sequence of
    /// moderate-magnitude samples to raise background RMS, then probes
    /// with a sample only marginally above background. The
    /// `[gate=crestFactor]` substring pins this gate.
    func testCrestFactorGate_elevatedBackground_returnsNil() {
        let detector = ImpactDetector(
            config: config(
                spikeThreshold: 0.020,
                minCrestFactor: 5.0,
                minConfirmations: 1
            ),
            adapterName: "matrix-crest"
        )
        // 200 samples at 0.030 to push backgroundMeanSq up.
        let now = Date()
        for i in 0..<200 {
            _ = detector.process(
                magnitude: 0.030,
                timestamp: now.addingTimeInterval(Double(i) * 0.02)
            )
        }
        // Probe sample is above the spike threshold (0.025 > 0.020) but
        // its crest factor against the elevated background (~0.030) is
        // <2 — well below the 5.0 minimum. Removing the gate would let
        // it detect.
        let result = detector.process(
            magnitude: 0.025,
            timestamp: now.addingTimeInterval(4.10)
        )
        XCTAssertNil(
            result,
            "[gate=crestFactor] sample marginally above elevated RMS must fail crest factor gate"
        )
    }

    // MARK: - Confirmations gate (ImpactDetector.swift line 158)

    /// Removing the `minConfirmations` guard would let a single
    /// above-threshold sample fire even when the gate requires N
    /// confirmations within the window. The cell feeds ONE sample
    /// above threshold, with all other gates permissive, and asserts
    /// no detection. The `[gate=confirmations]` substring pins this
    /// gate.
    func testConfirmationsGate_singleSample_returnsNil() {
        let detector = ImpactDetector(
            config: config(
                spikeThreshold: 0.020,
                minConfirmations: 5
            ),
            adapterName: "matrix-confirm"
        )
        // Single above-threshold sample — fewer than 5 confirmations.
        let result = detector.process(magnitude: 0.080, timestamp: Date())
        XCTAssertNil(
            result,
            "[gate=confirmations] single above-threshold sample must NOT meet 5-confirmation requirement"
        )
    }
}
