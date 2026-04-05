import XCTest
@testable import YameteLib

@MainActor
final class ImpactDetectionTests: XCTestCase {

    // Tests use explicit thresholds and large input values to ensure signals
    // pass the bandpass filter (HP 18Hz + LP 25Hz attenuates ~5x vs raw).

    /// Creates a permissive config — all gates disabled except spike threshold.
    private func permissiveConfig(threshold: Float = 0.05, rearm: TimeInterval = 0, warmup: Int = 0) -> DetectionConfig {
        DetectionConfig(
            spikeThreshold: threshold,
            minCrestFactor: 0, minRiseRate: 0, minConfirmations: 1,
            minRearmDuration: rearm, minWarmupSamples: warmup
        )
    }

    func testSingleSourceCanTriggerConsensus() {
        let engine = ImpactDetectionEngine(config: permissiveConfig())
        let now = Date()
        let sample = SensorSample(source: SensorID("A"), timestamp: now, value: Vec3(x: 2.0, y: 0, z: 0))
        let impact = engine.ingest(sample, activeSources: [SensorID("A")])
        XCTAssertNotNil(impact)
    }

    func testTwoSourcesRequireTwoSourceConsensus() {
        let engine = ImpactDetectionEngine(config: permissiveConfig())
        let now = Date()

        let aOnly = engine.ingest(
            SensorSample(source: SensorID("A"), timestamp: now, value: Vec3(x: 2.0, y: 0, z: 0)),
            activeSources: [SensorID("A"), SensorID("B")]
        )
        XCTAssertNil(aOnly)

        let both = engine.ingest(
            SensorSample(source: SensorID("B"), timestamp: now.addingTimeInterval(0.01), value: Vec3(x: 2.0, y: 0, z: 0)),
            activeSources: [SensorID("A"), SensorID("B")]
        )
        XCTAssertNotNil(both)
    }

    func testRearmsAfterCooldown() {
        let engine = ImpactDetectionEngine(windowDuration: 0.05, config: permissiveConfig(rearm: 0.30))
        let now = Date()

        let first = engine.ingest(
            SensorSample(source: SensorID("A"), timestamp: now, value: Vec3(x: 2.0, y: 0, z: 0)),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(first)

        let immediate = engine.ingest(
            SensorSample(source: SensorID("A"), timestamp: now.addingTimeInterval(0.01), value: Vec3(x: 3.0, y: 0, z: 0)),
            activeSources: [SensorID("A")]
        )
        XCTAssertNil(immediate)

        for i in 5...30 {
            _ = engine.ingest(
                SensorSample(source: SensorID("A"), timestamp: now.addingTimeInterval(Double(i) * 0.02), value: Vec3.zero),
                activeSources: [SensorID("A")]
            )
        }

        let second = engine.ingest(
            SensorSample(source: SensorID("A"), timestamp: now.addingTimeInterval(0.80), value: Vec3(x: 3.0, y: 0, z: 0)),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(second)
    }

    func testGravityOnlyDoesNotTrigger() {
        let engine = ImpactDetectionEngine(config: permissiveConfig(warmup: 30))
        let start = Date()
        var triggered = false

        for i in 0..<200 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            if engine.ingest(SensorSample(source: SensorID("A"), timestamp: t,
                value: Vec3(x: 0.01, y: 0.01, z: 0.98)), activeSources: [SensorID("A")]) != nil {
                triggered = true
            }
        }
        XCTAssertFalse(triggered)
    }

    func testTypingNoiseDoesNotTrigger() {
        let engine = ImpactDetectionEngine(config: permissiveConfig(warmup: 30))
        let start = Date()
        var triggered = false

        for i in 0..<300 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            let v = Float(i % 7) * 0.003
            if engine.ingest(SensorSample(source: SensorID("A"), timestamp: t,
                value: Vec3(x: v, y: v * 0.8, z: 0.98)), activeSources: [SensorID("A")]) != nil {
                triggered = true
            }
        }
        XCTAssertFalse(triggered)
    }

    func testImpactSpikeTriggersAfterSettling() {
        let engine = ImpactDetectionEngine(config: permissiveConfig(warmup: 30))
        let start = Date()
        var triggered = false

        for i in 0..<120 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            _ = engine.ingest(SensorSample(source: SensorID("A"), timestamp: t,
                value: Vec3(x: 0.01, y: 0.01, z: 0.98)), activeSources: [SensorID("A")])
        }

        for i in 120..<130 {
            let t = start.addingTimeInterval(Double(i) * 0.02)
            if engine.ingest(SensorSample(source: SensorID("A"), timestamp: t,
                value: Vec3(x: 1.2, y: 1.0, z: 2.0)), activeSources: [SensorID("A")]) != nil {
                triggered = true
            }
        }
        XCTAssertTrue(triggered)
    }

}
