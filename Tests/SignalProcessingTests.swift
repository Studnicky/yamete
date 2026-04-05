import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

final class RingBufferTests: XCTestCase {

    func testPushAndRead() {
        struct Case { let name: String; let pushes: [Float]; let capacity: Int; let expectedArray: [Float]; let expectedFull: Bool }
        let cases: [Case] = [
            .init(name: "empty",           pushes: [],          capacity: 3, expectedArray: [],        expectedFull: false),
            .init(name: "partial",         pushes: [1, 2],      capacity: 5, expectedArray: [1, 2],    expectedFull: false),
            .init(name: "exactly full",    pushes: [1, 2, 3],   capacity: 3, expectedArray: [1, 2, 3], expectedFull: true),
            .init(name: "wraps once",      pushes: [1,2,3,4],   capacity: 3, expectedArray: [2, 3, 4], expectedFull: true),
            .init(name: "wraps twice",     pushes: [1,2,3,4,5,6,7], capacity: 3, expectedArray: [5, 6, 7], expectedFull: true),
            .init(name: "single capacity", pushes: [10, 20],    capacity: 1, expectedArray: [20],      expectedFull: true),
        ]
        for c in cases {
            var buf = RingBuffer(capacity: c.capacity)
            for v in c.pushes { buf.push(v) }
            XCTAssertEqual(buf.asArray(), c.expectedArray, c.name)
            XCTAssertEqual(buf.isFull, c.expectedFull, c.name)
            XCTAssertEqual(buf.currentCount, min(c.pushes.count, c.capacity), c.name)
        }
    }

    func testSumAbs() {
        struct Case { let name: String; let values: [Float]; let capacity: Int; let expected: Float }
        let cases: [Case] = [
            .init(name: "empty",        values: [],               capacity: 5, expected: 0),
            .init(name: "positive",     values: [1, 2, 3],        capacity: 5, expected: 6),
            .init(name: "mixed signs",  values: [-3, 4, -1, 2],   capacity: 4, expected: 10),
            .init(name: "after wrap",   values: [10, 20, 30, 40], capacity: 3, expected: 90),
        ]
        for c in cases {
            var buf = RingBuffer(capacity: c.capacity)
            for v in c.values { buf.push(v) }
            XCTAssertEqual(buf.sumAbs(), c.expected, accuracy: 1e-6, c.name)
        }
    }
}

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
            let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: 50.0)
            var last = Vec3.zero
            for sample in c.signal { last = hpf.process(sample) }
            if c.expectNearZero {
                XCTAssertEqual(last.magnitude, 0, accuracy: 0.05, c.name)
            } else {
                XCTAssertGreaterThan(last.magnitude, 1.0, c.name)
            }
        }
    }

    func testReset() {
        let hpf = HighPassFilter()
        _ = hpf.process(Vec3(x: 1, y: 1, z: 1))
        hpf.reset()
        let out = hpf.process(.zero)
        XCTAssertEqual(out.magnitude, 0, accuracy: 1e-6)
    }
}
