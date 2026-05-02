import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// End-to-end tests for the sensitivity gating helper that the orchestrator
/// installs on `ImpactFusion.intensityGate`. Sensitivity is inverted to
/// thresholds: high sensitivity → low threshold → more reactive.
final class EndToEndTests: XCTestCase {

    func testSensitivityBandGating() {
        struct Case {
            let name: String
            let rawIntensity: Float
            let sensitivityMin: Float
            let sensitivityMax: Float
            let expectPass: Bool
            let expectedMapped: Float?
        }
        let cases: [Case] = [
            .init(name: "high sensitivity, weak force → passes",
                  rawIntensity: 0.15, sensitivityMin: 0.7, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 0.25),
            .init(name: "low sensitivity, weak force → rejected",
                  rawIntensity: 0.2, sensitivityMin: 0.1, sensitivityMax: 0.3,
                  expectPass: false, expectedMapped: nil),
            .init(name: "low sensitivity, strong force → passes",
                  rawIntensity: 0.85, sensitivityMin: 0.1, sensitivityMax: 0.3,
                  expectPass: true, expectedMapped: 0.75),
            .init(name: "default band, just above floor → passes near 0",
                  rawIntensity: 0.11, sensitivityMin: 0.1, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 0.01),
            .init(name: "default band, mid → linear map",
                  rawIntensity: 0.5, sensitivityMin: 0.1, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 0.5),
            .init(name: "default band, at ceiling → saturates to 1",
                  rawIntensity: 0.9, sensitivityMin: 0.1, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 1.0),
            .init(name: "default band, below floor → rejected",
                  rawIntensity: 0.05, sensitivityMin: 0.1, sensitivityMax: 0.9,
                  expectPass: false, expectedMapped: nil),
            .init(name: "narrow high band, mid-range force → saturated",
                  rawIntensity: 0.2, sensitivityMin: 0.8, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 1.0),
            .init(name: "full range, above zero → passes",
                  rawIntensity: 0.5, sensitivityMin: 0.0, sensitivityMax: 1.0,
                  expectPass: true, expectedMapped: 0.5),
        ]
        for c in cases {
            let mapped = FusedImpact.applySensitivity(
                rawIntensity: c.rawIntensity,
                sensitivityMin: c.sensitivityMin,
                sensitivityMax: c.sensitivityMax
            )
            if c.expectPass {
                XCTAssertNotNil(mapped, "\(c.name): expected pass")
                if let mapped, let expected = c.expectedMapped {
                    XCTAssertEqual(mapped, expected, accuracy: 0.01, "\(c.name): mapped value")
                }
            } else {
                XCTAssertNil(mapped, "\(c.name): expected reject")
            }
        }
    }
}
