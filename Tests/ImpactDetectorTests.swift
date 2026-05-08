import XCTest
@testable import YameteCore
@testable import SensorKit

final class ImpactDetectorTests: XCTestCase {

    private func permissiveConfig(threshold: Float = 0.01, warmup: Int = 0) -> ImpactDetectorConfig {
        ImpactDetectorConfig(
            spikeThreshold: threshold, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: warmup,
            intensityFloor: 0.01, intensityCeiling: 1.0
        )
    }

    func testImpactDetectedAboveThreshold() {
        let detector = ImpactDetector(config: permissiveConfig(), sourceName: "test")
        let result = detector.process(magnitude: 0.5, timestamp: Date())
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result ?? 0, 0)
    }

    func testBelowThresholdDoesNotTrigger() {
        let detector = ImpactDetector(config: permissiveConfig(threshold: 0.5), sourceName: "test")
        let result = detector.process(magnitude: 0.3, timestamp: Date())
        XCTAssertNil(result)
    }

    func testWarmupGate() {
        let detector = ImpactDetector(config: permissiveConfig(warmup: 10), sourceName: "test")
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
        let detector = ImpactDetector(config: config, sourceName: "test")

        let result = detector.process(magnitude: 0.55, timestamp: Date())
        XCTAssertNotNil(result)
        // (0.55 - 0.1) / (1.0 - 0.1) = 0.5
        XCTAssertEqual(result ?? 0, 0.5, accuracy: 0.01)
    }
}
