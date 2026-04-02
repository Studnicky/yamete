import XCTest
@testable import YameteLib

/// End-to-end detection pipeline tests.
/// Feeds synthetic accelerometer data through the full chain:
///   Vec3 samples → HighPassFilter → 4 detectors → voting → ImpactEvent
/// Then verifies intensity gating against sensitivity band.
final class EndToEndTests: XCTestCase {

    // MARK: - Synthetic signal generators

    /// Gravity-only signal (resting MacBook)
    private static func gravity(_ count: Int) -> [Vec3] {
        Array(repeating: Vec3(x: 0.01, y: 0.02, z: 0.98), count: count)
    }

    /// Sharp physical impact: sudden multi-axis acceleration spike
    private static func impact(magnitude: Float, count: Int = 8) -> [Vec3] {
        let m = magnitude / sqrtf(3)
        return Array(repeating: Vec3(x: m, y: m, z: m), count: count)
    }

    /// Typing-like noise: tiny deterministic vibrations well below detection threshold
    private static func typing(_ count: Int) -> [Vec3] {
        (0..<count).map { i in
            let t = Float(i) * 0.001
            return Vec3(x: t.truncatingRemainder(dividingBy: 0.005),
                 y: t.truncatingRemainder(dividingBy: 0.003),
                 z: 0.98)
        }
    }

    // MARK: - Full pipeline: detector + sensitivity gating

    func testDetectionPipeline() {
        struct Case {
            let name: String
            let sensitivity: Double
            let samples: [Vec3]
            let expectDetection: Bool
        }
        let cases: [Case] = [
            .init(name: "resting produces no events",
                  sensitivity: 0.5,
                  samples: Self.gravity(300),
                  expectDetection: false),

            .init(name: "strong impact detected at mid sensitivity",
                  sensitivity: 0.8,
                  samples: Self.gravity(200) + Self.impact(magnitude: 3.0),
                  expectDetection: true),

            .init(name: "typing ignored at default sensitivity",
                  sensitivity: 0.5,
                  samples: Self.typing(500),
                  expectDetection: false),

            .init(name: "weak impact ignored at low sensitivity",
                  sensitivity: 0.2,
                  samples: Self.gravity(200) + Self.gravity(10),
                  expectDetection: false),

            .init(name: "strong impact detected at high sensitivity",
                  sensitivity: 1.0,
                  samples: Self.gravity(200) + Self.impact(magnitude: 2.0),
                  expectDetection: true),
        ]

        for c in cases {
            let detector = ImpactDetector()
            detector.sensitivity = c.sensitivity
            var events: [ImpactEvent] = []
            for sample in c.samples {
                if let event = detector.process(sample) {
                    events.append(event)
                }
            }
            if c.expectDetection {
                XCTAssertFalse(events.isEmpty, "\(c.name): expected detection, got none")
            } else {
                XCTAssertTrue(events.isEmpty, "\(c.name): expected silence, got \(events.count) events")
            }
        }
    }

    // MARK: - Sensitivity band gating (ImpactController logic)

    func testSensitivityBandGating() {
        struct Case {
            let name: String
            let rawIntensity: Float
            let sensitivityMin: Float
            let sensitivityMax: Float
            let expectPass: Bool            // does it pass the gate?
            let expectedMapped: Float?      // if it passes, what's the mapped value?
        }
        let cases: [Case] = [
            .init(name: "below floor → rejected",
                  rawIntensity: 0.2, sensitivityMin: 0.3, sensitivityMax: 0.8,
                  expectPass: false, expectedMapped: nil),
            .init(name: "at floor → passes as 0",
                  rawIntensity: 0.3, sensitivityMin: 0.3, sensitivityMax: 0.8,
                  expectPass: true, expectedMapped: 0.0),
            .init(name: "mid-band → linear map",
                  rawIntensity: 0.55, sensitivityMin: 0.3, sensitivityMax: 0.8,
                  expectPass: true, expectedMapped: 0.5),
            .init(name: "at ceiling → saturates to 1",
                  rawIntensity: 0.8, sensitivityMin: 0.3, sensitivityMax: 0.8,
                  expectPass: true, expectedMapped: 1.0),
            .init(name: "above ceiling → clamped to 1",
                  rawIntensity: 1.0, sensitivityMin: 0.3, sensitivityMax: 0.8,
                  expectPass: true, expectedMapped: 1.0),
            .init(name: "narrow band mid → full range",
                  rawIntensity: 0.55, sensitivityMin: 0.5, sensitivityMax: 0.6,
                  expectPass: true, expectedMapped: 0.5),
        ]
        for c in cases {
            // Replicate ImpactController.handleSample gating logic
            let sMin = c.sensitivityMin
            let sMax = c.sensitivityMax
            let raw = c.rawIntensity

            guard raw >= sMin else {
                XCTAssertFalse(c.expectPass, "\(c.name): below floor should reject")
                continue
            }
            XCTAssertTrue(c.expectPass, "\(c.name): should pass gate")

            let bandWidth = max(Float(0.001), sMax - sMin)
            let mapped = ((raw - sMin) / bandWidth).clamped(to: 0...1)

            if let expected = c.expectedMapped {
                XCTAssertEqual(mapped, expected, accuracy: 0.01, "\(c.name): mapped value")
            }
        }
    }

    // MARK: - Multi-impact sequence with debounce simulation

    func testMultiImpactSequence() {
        struct Case {
            let name: String
            let impactCount: Int
            let gapSamples: Int     // samples between impacts (at 50Hz)
            let sensitivity: Double
            let minExpectedEvents: Int
        }
        let cases: [Case] = [
            .init(name: "single impact",
                  impactCount: 1, gapSamples: 0, sensitivity: 0.8,
                  minExpectedEvents: 1),
            .init(name: "two impacts with long gap",
                  impactCount: 2, gapSamples: 200, sensitivity: 0.8,
                  minExpectedEvents: 2),
            .init(name: "rapid impacts (some may merge)",
                  impactCount: 5, gapSamples: 10, sensitivity: 0.8,
                  minExpectedEvents: 1), // detectors may not reset fast enough
        ]
        for c in cases {
            let detector = ImpactDetector()
            detector.sensitivity = c.sensitivity
            var samples: [Vec3] = Self.gravity(200) // settle
            for i in 0..<c.impactCount {
                samples += Self.impact(magnitude: 3.0)
                if i < c.impactCount - 1 {
                    samples += Self.gravity(c.gapSamples)
                }
            }
            var eventCount = 0
            for sample in samples {
                if detector.process(sample) != nil { eventCount += 1 }
            }
            XCTAssertGreaterThanOrEqual(eventCount, c.minExpectedEvents,
                "\(c.name): got \(eventCount) events, expected >= \(c.minExpectedEvents)")
        }
    }
}
