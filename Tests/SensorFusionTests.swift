import XCTest
@testable import YameteLib

final class SensorFusionTests: XCTestCase {

    // Tests use explicit thresholds and large input values to ensure signals
    // pass the bandpass filter (HP 18Hz + LP 25Hz attenuates ~5x vs raw).

    func testSingleSourceCanTriggerConsensus() {
        let engine = SensorFusionEngine(windowDuration: 0.12, spikeThreshold: 0.05,
                                         minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0, minWarmupSamples: 0)
        let now = Date()
        let sample = SensorSample(source: "A", timestamp: now, value: Vec3(x: 2.0, y: 0, z: 0))
        let impact = engine.ingest(sample, activeSources: ["A"])
        XCTAssertNotNil(impact)
    }

    func testTwoSourcesRequireTwoSourceConsensus() {
        let engine = SensorFusionEngine(windowDuration: 0.12, spikeThreshold: 0.05,
                                         minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0, minWarmupSamples: 0)
        let now = Date()

        let aOnly = engine.ingest(
            SensorSample(source: "A", timestamp: now, value: Vec3(x: 2.0, y: 0, z: 0)),
            activeSources: ["A", "B"]
        )
        XCTAssertNil(aOnly)

        let both = engine.ingest(
            SensorSample(source: "B", timestamp: now.addingTimeInterval(0.01), value: Vec3(x: 2.0, y: 0, z: 0)),
            activeSources: ["A", "B"]
        )
        XCTAssertNotNil(both)
    }

    func testRearmsAfterCooldown() {
        let engine = SensorFusionEngine(windowDuration: 0.05, spikeThreshold: 0.05,
                                         minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0.30, minWarmupSamples: 0)
        let now = Date()

        let first = engine.ingest(
            SensorSample(source: "A", timestamp: now, value: Vec3(x: 2.0, y: 0, z: 0)),
            activeSources: ["A"]
        )
        XCTAssertNotNil(first)

        let immediate = engine.ingest(
            SensorSample(source: "A", timestamp: now.addingTimeInterval(0.01), value: Vec3(x: 3.0, y: 0, z: 0)),
            activeSources: ["A"]
        )
        XCTAssertNil(immediate)

        for i in 5...30 {
            _ = engine.ingest(
                SensorSample(source: "A", timestamp: now.addingTimeInterval(Double(i) * 0.02), value: Vec3.zero),
                activeSources: ["A"]
            )
        }

        let second = engine.ingest(
            SensorSample(source: "A", timestamp: now.addingTimeInterval(0.80), value: Vec3(x: 3.0, y: 0, z: 0)),
            activeSources: ["A"]
        )
        XCTAssertNotNil(second)
    }

    func testGravityOnlyDoesNotTrigger() {
        let engine = SensorFusionEngine(windowDuration: 0.12, spikeThreshold: 0.05,
                                         minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0, minWarmupSamples: 30)
        let start = Date()
        var triggered = false

        for i in 0..<200 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            if engine.ingest(SensorSample(source: "A", timestamp: t,
                value: Vec3(x: 0.01, y: 0.01, z: 0.98)), activeSources: ["A"]) != nil {
                triggered = true
            }
        }
        XCTAssertFalse(triggered)
    }

    func testTypingNoiseDoesNotTrigger() {
        let engine = SensorFusionEngine(windowDuration: 0.12, spikeThreshold: 0.05,
                                         minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0, minWarmupSamples: 30)
        let start = Date()
        var triggered = false

        for i in 0..<300 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            let v = Float(i % 7) * 0.003
            if engine.ingest(SensorSample(source: "A", timestamp: t,
                value: Vec3(x: v, y: v * 0.8, z: 0.98)), activeSources: ["A"]) != nil {
                triggered = true
            }
        }
        XCTAssertFalse(triggered)
    }

    func testImpactSpikeTriggersAfterSettling() {
        let engine = SensorFusionEngine(windowDuration: 0.12, spikeThreshold: 0.05,
                                         minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0, minWarmupSamples: 30)
        let start = Date()
        var triggered = false

        for i in 0..<120 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            _ = engine.ingest(SensorSample(source: "A", timestamp: t,
                value: Vec3(x: 0.01, y: 0.01, z: 0.98)), activeSources: ["A"])
        }

        for i in 120..<130 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            if engine.ingest(SensorSample(source: "A", timestamp: t,
                value: Vec3(x: 1.2, y: 1.0, z: 2.0)), activeSources: ["A"]) != nil {
                triggered = true
            }
        }
        XCTAssertTrue(triggered)
    }

    func testCrestFactorRejectsSustainedVibration() {
        let engine = SensorFusionEngine(windowDuration: 0.12, spikeThreshold: 0.01,
                                         minCrestFactor: 5.0, minRiseRate: 0, minConfirmations: 1,
                                         minRearmDuration: 0, minWarmupSamples: 50)
        let start = Date()
        var triggered = false

        // Sustained in-band oscillation: alternating ±0.5 every sample (25Hz = in-band)
        // Produces consistent filtered output where peak ≈ average (low crest factor)
        for i in 0..<200 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            let sign: Float = (i % 2 == 0) ? 1.0 : -1.0
            let v: Float = sign * 0.5
            if engine.ingest(SensorSample(source: "A", timestamp: t,
                value: Vec3(x: v, y: 0, z: 0)), activeSources: ["A"]) != nil {
                triggered = true
            }
        }
        XCTAssertFalse(triggered, "Sustained vibration should be rejected by crest factor")
    }
}
