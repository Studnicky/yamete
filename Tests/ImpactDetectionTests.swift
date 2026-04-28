import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

// MARK: - ImpactDetector tests (per-adapter gate pipeline)

final class ImpactDetectorTests: XCTestCase {

    private func permissiveConfig(threshold: Float = 0.01, warmup: Int = 0) -> ImpactDetectorConfig {
        ImpactDetectorConfig(
            spikeThreshold: threshold, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: warmup,
            intensityFloor: 0.01, intensityCeiling: 1.0
        )
    }

    func testImpactDetectedAboveThreshold() {
        let detector = ImpactDetector(config: permissiveConfig(), adapterName: "test")
        let result = detector.process(magnitude: 0.5, timestamp: Date())
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result ?? 0, 0)
    }

    func testBelowThresholdDoesNotTrigger() {
        let detector = ImpactDetector(config: permissiveConfig(threshold: 0.5), adapterName: "test")
        let result = detector.process(magnitude: 0.3, timestamp: Date())
        XCTAssertNil(result)
    }

    func testWarmupGate() {
        let detector = ImpactDetector(config: permissiveConfig(warmup: 10), adapterName: "test")
        let now = Date()

        // During warmup
        for i in 0..<9 {
            let result = detector.process(magnitude: 0.8, timestamp: now.addingTimeInterval(Double(i) * 0.02))
            XCTAssertNil(result, "Should not trigger during warmup (sample \(i))")
        }

        // After warmup
        let result = detector.process(magnitude: 0.8, timestamp: now.addingTimeInterval(0.20))
        XCTAssertNotNil(result, "Should trigger after warmup")
    }

    func testIntensityMapping() {
        let config = ImpactDetectorConfig(
            spikeThreshold: 0.01, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: 0,
            intensityFloor: 0.1, intensityCeiling: 1.0
        )
        let detector = ImpactDetector(config: config, adapterName: "test")

        let result = detector.process(magnitude: 0.55, timestamp: Date())
        XCTAssertNotNil(result)
        // (0.55 - 0.1) / (1.0 - 0.1) = 0.5
        XCTAssertEqual(result ?? 0, 0.5, accuracy: 0.01)
    }
}

// MARK: - ImpactFusion tests

@MainActor
final class ImpactFusionTests: XCTestCase {

    func testSingleSourceTriggers() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 1))
        let now = Date()

        let result = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.intensity ?? 0, 0.8, accuracy: 0.01)
    }

    func testConsensusRequiresTwoWhenConfigured() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 2, fusionWindow: 0.2))
        let now = Date()

        let aOnly = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A"), SensorID("B")]
        )
        XCTAssertNil(aOnly)

        let both = engine.ingest(
            SensorImpact(source: SensorID("B"), timestamp: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: [SensorID("A"), SensorID("B")]
        )
        XCTAssertNotNil(both)
        // Average of 0.8 and 0.6
        XCTAssertEqual(both?.intensity ?? 0, 0.7, accuracy: 0.01)
    }

    func testConsensusClampedToActiveSources() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 5))
        let now = Date()

        // Only 1 active source → consensus clamped to 1 → triggers
        let result = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(result)
    }

    func testRearmPreventsRetrigger() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 1, rearmDuration: 0.5))
        let now = Date()

        let first = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(first)

        let blocked = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now.addingTimeInterval(0.2), intensity: 0.9),
            activeSources: [SensorID("A")]
        )
        XCTAssertNil(blocked)
    }
}
