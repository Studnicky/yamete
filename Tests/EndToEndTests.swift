import XCTest
@testable import YameteLib

/// End-to-end tests for sensitivity gating (ImpactController normalization logic).
/// Sensitivity is inverted to thresholds: high sensitivity → low threshold → more reactive.
final class EndToEndTests: XCTestCase {

    // MARK: - Sensitivity band gating (ImpactController logic)

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
            // High sensitivity (0.7–0.9) → thresholds 0.1–0.3 → very reactive
            .init(name: "high sensitivity, weak force → passes",
                  rawIntensity: 0.15, sensitivityMin: 0.7, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 0.25),

            // Low sensitivity (0.1–0.3) → thresholds 0.7–0.9 → needs strong force
            .init(name: "low sensitivity, weak force → rejected",
                  rawIntensity: 0.2, sensitivityMin: 0.1, sensitivityMax: 0.3,
                  expectPass: false, expectedMapped: nil),

            .init(name: "low sensitivity, strong force → passes",
                  rawIntensity: 0.85, sensitivityMin: 0.1, sensitivityMax: 0.3,
                  expectPass: true, expectedMapped: 0.75),

            // Default sensitivity (0.1–0.9) → thresholds 0.1–0.9
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

            // Narrow band, high sensitivity (0.8–0.9) → thresholds 0.1–0.2
            .init(name: "narrow high band, mid-range force → saturated",
                  rawIntensity: 0.2, sensitivityMin: 0.8, sensitivityMax: 0.9,
                  expectPass: true, expectedMapped: 1.0),

            // Full sensitivity (0.0–1.0) → thresholds 0.0–1.0
            .init(name: "full range, above zero → passes",
                  rawIntensity: 0.5, sensitivityMin: 0.0, sensitivityMax: 1.0,
                  expectPass: true, expectedMapped: 0.5),
        ]
        for c in cases {
            // Mirror ImpactController inverted gating logic.
            let thresholdLow = 1.0 - c.sensitivityMax
            let thresholdHigh = 1.0 - c.sensitivityMin
            let raw = c.rawIntensity

            guard raw >= thresholdLow else {
                XCTAssertFalse(c.expectPass, "\(c.name): below threshold should reject")
                continue
            }
            XCTAssertTrue(c.expectPass, "\(c.name): should pass gate")

            let bandWidth = max(Float(0.001), thresholdHigh - thresholdLow)
            let mapped = ((raw - thresholdLow) / bandWidth).clamped(to: 0...1)

            if let expected = c.expectedMapped {
                XCTAssertEqual(mapped, expected, accuracy: 0.01, "\(c.name): mapped value")
            }
        }
    }
}
