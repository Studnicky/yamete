import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

@MainActor
final class EnvelopeTests: XCTestCase {

    func testEnvelopeProportions() {
        struct Case {
            let name: String
            let intensity: Float; let duration: Double
            let fadeIn: Double; let hold: Double; let fadeOut: Double
        }
        let cases: [Case] = [
            .init(name: "max intensity",  intensity: 1.0, duration: 1.0, fadeIn: 0.10, hold: 0.60, fadeOut: 0.30),
            .init(name: "mid intensity",  intensity: 0.5, duration: 1.0, fadeIn: 0.20, hold: 0.40, fadeOut: 0.40),
            .init(name: "min intensity",  intensity: 0.0, duration: 1.0, fadeIn: 0.30, hold: 0.20, fadeOut: 0.50),
            .init(name: "scaled 3s",      intensity: 1.0, duration: 3.0, fadeIn: 0.30, hold: 1.80, fadeOut: 0.90),
            .init(name: "zero duration",  intensity: 0.5, duration: 0.0, fadeIn: 0.00, hold: 0.00, fadeOut: 0.00),
            .init(name: "short clip",     intensity: 0.7, duration: 0.3, fadeIn: 0.048, hold: 0.144, fadeOut: 0.108),
        ]
        for c in cases {
            let env = ScreenFlash.envelope(clipDuration: c.duration, intensity: c.intensity)
            XCTAssertEqual(env.fadeIn, c.fadeIn, accuracy: 1e-3, "\(c.name) fadeIn")
            XCTAssertEqual(env.hold, c.hold, accuracy: 1e-3, "\(c.name) hold")
            XCTAssertEqual(env.fadeOut, c.fadeOut, accuracy: 1e-3, "\(c.name) fadeOut")
        }
    }

    func testEnvelopeInvariants() {
        // Envelope should always sum to duration and stay non-negative.
        for i in stride(from: Float(0), through: 1.0, by: 0.05) {
            for d in [0.0, 0.1, 0.5, 1.0, 2.5] {
                let env = ScreenFlash.envelope(clipDuration: d, intensity: i)
                let total = env.fadeIn + env.hold + env.fadeOut
                XCTAssertEqual(total, d, accuracy: 1e-10, "sum at intensity=\(i) duration=\(d)")
                XCTAssertGreaterThanOrEqual(env.fadeIn, 0, "fadeIn at intensity=\(i)")
                XCTAssertGreaterThanOrEqual(env.hold, 0, "hold at intensity=\(i)")
                XCTAssertGreaterThanOrEqual(env.fadeOut, 0, "fadeOut at intensity=\(i)")
            }
        }
    }
}
