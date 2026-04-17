import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

final class HighPassFilterTests: XCTestCase {

    func testFrequencyResponse() {
        struct Case { let name: String; let signal: [Vec3]; let settleCount: Int; let expectNearZero: Bool }
        let quiet = Vec3(x: 0, y: 0, z: 1.0)
        let impulse = Vec3(x: 0, y: 0, z: 3.0)
        let cases: [Case] = [
            .init(name: "DC removed after settling",
                  signal: Array(repeating: quiet, count: 200),
                  settleCount: 200, expectNearZero: true),
            .init(name: "impulse passes through",
                  signal: Array(repeating: .zero, count: 100) + [impulse],
                  settleCount: 100, expectNearZero: false),
        ]
        for c in cases {
            var hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: 50.0)
            var last = Vec3.zero
            for sample in c.signal { last = hpf.process(sample) }
            if c.expectNearZero {
                XCTAssertEqual(last.magnitude, 0, accuracy: 0.05, c.name)
            } else {
                XCTAssertGreaterThan(last.magnitude, 1.0, c.name)
            }
        }
    }
}
