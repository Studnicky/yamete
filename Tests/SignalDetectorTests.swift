import XCTest
@testable import YameteLib

/// Shared test pattern: feed a signal sequence, check if detector triggers.
private struct DetectorScenario {
    let name: String
    let signal: [Float]
    let expectTrigger: Bool
}

private func runScenarios(_ scenarios: [DetectorScenario], make: () -> any SignalDetector) {
    for s in scenarios {
        let det = make()
        var triggered = false
        for sample in s.signal {
            if det.process(sample) { triggered = true }
        }
        if s.expectTrigger {
            XCTAssertTrue(triggered, "\(s.name): expected trigger but didn't get one")
        } else {
            XCTAssertFalse(triggered, "\(s.name): expected no trigger but got one")
        }
    }
}

private let silence100   = Array(repeating: Float(0.001), count: 100)
private let quietNoise60 = (0..<60).map { Float($0 % 5 + 1) * 0.01 }
private let spike5       = Array(repeating: Float(2.0), count: 5)
private let sustained50  = Array(repeating: Float(0.5), count: 50)
private let impulseInQuiet: [Float] = Array(repeating: 0.01, count: 29) + [5.0] + Array(repeating: 0.01, count: 10)
private let sinusoid100  = (0..<100).map { Float(sin(Double($0) * 0.3)) * 0.1 }
private let constant100  = Array(repeating: Float(0.5), count: 100)

final class STALTADetectorTests: XCTestCase {
    func testScenarios() {
        let scenarios: [DetectorScenario] = [
            .init(name: "silence",           signal: silence100,                expectTrigger: false),
            .init(name: "quiet then spike",  signal: quietNoise60 + spike5,     expectTrigger: true),
            .init(name: "constant level",    signal: constant100,               expectTrigger: false),
        ]
        runScenarios(scenarios) { STALTADetector(config: DetectorConfig()) }
    }
}

final class CUSUMDetectorTests: XCTestCase {
    func testScenarios() {
        let scenarios: [DetectorScenario] = [
            .init(name: "silence",           signal: silence100,    expectTrigger: false),
            .init(name: "sustained energy",  signal: sustained50,   expectTrigger: true),
            .init(name: "brief blip",        signal: silence100 + [0.3], expectTrigger: false),
        ]
        runScenarios(scenarios) { CUSUMDetector(config: DetectorConfig()) }
    }
}

final class KurtosisDetectorTests: XCTestCase {
    func testScenarios() {
        let scenarios: [DetectorScenario] = [
            .init(name: "sinusoid (low kurtosis)", signal: sinusoid100,      expectTrigger: false),
            .init(name: "impulse in quiet",        signal: impulseInQuiet,   expectTrigger: true),
            .init(name: "silence",                 signal: silence100,       expectTrigger: false),
        ]
        runScenarios(scenarios) { KurtosisDetector(config: DetectorConfig()) }
    }
}

final class PeakMADDetectorTests: XCTestCase {
    func testScenarios() {
        let scenarios: [DetectorScenario] = [
            .init(name: "constant (zero MAD)",     signal: constant100,              expectTrigger: false),
            .init(name: "varied noise then outlier",
                  signal: quietNoise60 + Array(repeating: Float(3.0), count: 5),     expectTrigger: true),
            .init(name: "silence",                 signal: silence100,               expectTrigger: false),
        ]
        runScenarios(scenarios) { PeakMADDetector(config: DetectorConfig()) }
    }
}
