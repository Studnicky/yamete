import XCTest
@testable import YameteLib

final class ThresholdMappingTests: XCTestCase {

    func testSensitivityToThresholds() {
        struct Case {
            let name: String
            let sensitivity: Double
            let stalta: Float; let cusum: Float; let peakMAD: Float; let kurtosis: Float
        }
        let cases: [Case] = [
            .init(name: "min (hardest)", sensitivity: 0.0, stalta: 8.0, cusum: 2.0,  peakMAD: 12.0, kurtosis: 20.0),
            .init(name: "mid (linear)",  sensitivity: 0.5, stalta: 5.5, cusum: 1.25, peakMAD: 8.0,  kurtosis: 14.0),
            .init(name: "max (softest)", sensitivity: 1.0, stalta: 3.0, cusum: 0.5,  peakMAD: 4.0,  kurtosis: 8.0),
            .init(name: "quarter",       sensitivity: 0.25, stalta: 6.75, cusum: 1.625, peakMAD: 10.0, kurtosis: 17.0),
        ]
        for c in cases {
            let config = DetectorConfig()
            let det = ImpactDetector(config: config)
            det.sensitivity = c.sensitivity
            XCTAssertEqual(config.staltaOnThreshold, c.stalta, accuracy: 0.01, c.name)
            XCTAssertEqual(config.cusumThreshold, c.cusum, accuracy: 0.01, c.name)
            XCTAssertEqual(config.peakMADThreshold, c.peakMAD, accuracy: 0.01, c.name)
            XCTAssertEqual(config.kurtosisThreshold, c.kurtosis, accuracy: 0.01, c.name)
        }
    }

    func testSameValueSkipsReapply() {
        let det = ImpactDetector()
        det.sensitivity = 0.6
        det.sensitivity = 0.6 // must not crash or have side effects
    }
}

final class DetectionPipelineTests: XCTestCase {

    func testImpactDetection() {
        struct Case {
            let name: String
            let sensitivity: Double
            let samples: [Vec3]
            let expectImpact: Bool
        }
        let quiet200 = Array(repeating: Vec3(x: 0, y: 0, z: 1.0), count: 200)
        let impact10 = Array(repeating: Vec3(x: 2.0, y: 1.5, z: 3.0), count: 10)
        let weakImpact = Array(repeating: Vec3(x: 0.005, y: 0.005, z: 1.005), count: 3)

        let cases: [Case] = [
            .init(name: "silence only",
                  sensitivity: 0.5, samples: quiet200,
                  expectImpact: false),
            .init(name: "strong impact after settling",
                  sensitivity: 0.8, samples: quiet200 + impact10,
                  expectImpact: true),
            .init(name: "constant gravity only",
                  sensitivity: 0.2, samples: quiet200,
                  expectImpact: false),
        ]
        for c in cases {
            let det = ImpactDetector()
            det.sensitivity = c.sensitivity
            var detected = false
            for sample in c.samples {
                if det.process(sample) != nil { detected = true }
            }
            if c.expectImpact {
                XCTAssertTrue(detected, c.name)
            } else {
                XCTAssertFalse(detected, c.name)
            }
        }
    }

    func testResetClearsState() {
        let det = ImpactDetector()
        for _ in 0..<50 { _ = det.process(Vec3(x: 0, y: 0, z: 1.0)) }
        det.reset()
        XCTAssertNil(det.process(Vec3(x: 0, y: 0, z: 1.0)))
    }
}
