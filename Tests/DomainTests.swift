import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

final class Vec3Tests: XCTestCase {

    func testMagnitude() {
        struct Case { let name: String; let input: Vec3; let expected: Float }
        let cases: [Case] = [
            .init(name: "zero",     input: .zero,                           expected: 0),
            .init(name: "unit X",   input: Vec3(x: 1, y: 0, z: 0),         expected: 1),
            .init(name: "unit Y",   input: Vec3(x: 0, y: 1, z: 0),         expected: 1),
            .init(name: "unit Z",   input: Vec3(x: 0, y: 0, z: 1),         expected: 1),
            .init(name: "3-4-0",    input: Vec3(x: 3, y: 4, z: 0),         expected: 5),
            .init(name: "1-1-1",    input: Vec3(x: 1, y: 1, z: 1),         expected: sqrtf(3)),
            .init(name: "negative", input: Vec3(x: -3, y: -4, z: 0),       expected: 5),
            .init(name: "gravity",  input: Vec3(x: 0, y: 0, z: 0.98),      expected: 0.98),
        ]
        for c in cases {
            XCTAssertEqual(c.input.magnitude, c.expected, accuracy: 1e-5, c.name)
        }
    }
}

final class ClampTests: XCTestCase {

    func testFloatClamp() {
        struct Case { let name: String; let value: Float; let range: ClosedRange<Float>; let expected: Float }
        let cases: [Case] = [
            .init(name: "below",    value: -1,   range: 0...1, expected: 0),
            .init(name: "above",    value: 2,    range: 0...1, expected: 1),
            .init(name: "in range", value: 0.5,  range: 0...1, expected: 0.5),
            .init(name: "at low",   value: 0,    range: 0...1, expected: 0),
            .init(name: "at high",  value: 1,    range: 0...1, expected: 1),
            .init(name: "wide",     value: 50,   range: 0...100, expected: 50),
        ]
        for c in cases {
            XCTAssertEqual(c.value.clamped(to: c.range), c.expected, c.name)
        }
    }

    func testDoubleClamp() {
        struct Case { let name: String; let value: Double; let range: ClosedRange<Double>; let expected: Double }
        let cases: [Case] = [
            .init(name: "below",    value: -5,   range: 0...10, expected: 0),
            .init(name: "above",    value: 15,   range: 0...10, expected: 10),
            .init(name: "in range", value: 7,    range: 0...10, expected: 7),
            .init(name: "at low",   value: 0,    range: 0...1,  expected: 0),
            .init(name: "at high",  value: 1,    range: 0...1,  expected: 1),
        ]
        for c in cases {
            XCTAssertEqual(c.value.clamped(to: c.range), c.expected, c.name)
        }
    }
}
