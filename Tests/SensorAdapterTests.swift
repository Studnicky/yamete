import XCTest
@testable import YameteLib

// MARK: - Mock adapter for testing SensorManager

/// Test adapter that yields a fixed sample sequence.
final class MockSensorAdapter: SensorAdapter, @unchecked Sendable {
    let id: SensorID
    let name: String
    let isAvailable: Bool
    private let sampleSequence: [Vec3]
    private let error: Error?

    init(name: String = "Mock", available: Bool = true, samples: [Vec3] = [], error: Error? = nil) {
        self.id = SensorID(name)
        self.name = name
        self.isAvailable = available
        self.sampleSequence = samples
        self.error = error
    }

    func samples() -> AsyncThrowingStream<Vec3, Error> {
        let seq = sampleSequence
        let err = error
        return AsyncThrowingStream { continuation in
            for vec in seq {
                continuation.yield(vec)
            }
            if let err {
                continuation.finish(throwing: err)
            } else {
                continuation.finish()
            }
        }
    }
}

// MARK: - SensorManager tests

@MainActor
final class SensorManagerTests: XCTestCase {

    func testEventsYieldsSamplesFromAvailableAdapter() async {
        let expected = [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 1, z: 0)]
        let adapter = MockSensorAdapter(name: "A", samples: expected)
        let manager = SensorManager(adapters: [adapter])

        var received: [SensorSample] = []
        for await event in manager.events() {
            if case .sample(let sample) = event {
                received.append(sample)
            }
        }

        XCTAssertEqual(received.count, expected.count)
        XCTAssertTrue(received.allSatisfy { $0.source == SensorID("A") })
        for (r, e) in zip(received.map(\.value), expected) {
            XCTAssertEqual(r.x, e.x, accuracy: 1e-6)
            XCTAssertEqual(r.y, e.y, accuracy: 1e-6)
        }
    }

    func testEventsSkipsUnavailableAdapters() async {
        let unavailable = MockSensorAdapter(name: "Unavailable", available: false, samples: [Vec3(x: 9, y: 9, z: 9)])
        let available = MockSensorAdapter(name: "Available", available: true, samples: [Vec3(x: 1, y: 0, z: 0)])
        let manager = SensorManager(adapters: [unavailable, available])

        var activeSnapshots: [[String]] = []
        var sampleCount = 0
        for await event in manager.events() {
            switch event {
            case .adaptersChanged(_, let names):
                activeSnapshots.append(names)
            case .sample:
                sampleCount += 1
            case .error:
                break
            }
        }

        XCTAssertEqual(sampleCount, 1)
        XCTAssertTrue(activeSnapshots.contains(["Available"]))
        XCTAssertFalse(activeSnapshots.contains(["Unavailable"]))
    }

    func testEventsReportsErrorOnNoAdapters() async {
        let manager = SensorManager(adapters: [])

        var errors: [String] = []
        for await event in manager.events() {
            if case .error(let msg) = event { errors.append(msg) }
        }

        XCTAssertFalse(errors.isEmpty, "Should report error when no adapters available")
    }

    func testEventsPublishesAdapterLifecycle() async {
        let a = MockSensorAdapter(name: "A", samples: [Vec3.zero])
        let b = MockSensorAdapter(name: "B", samples: [Vec3.zero])
        let manager = SensorManager(adapters: [a, b])

        var snapshots: [[String]] = []
        for await event in manager.events() {
            if case .adaptersChanged(_, let names) = event {
                snapshots.append(names)
            }
        }

        XCTAssertTrue(snapshots.contains(["A", "B"]))
        XCTAssertEqual(snapshots.last, [])
    }

    func testEventsCancellation() async {
        let manySamples = (0..<1000).map { _ in Vec3(x: 0.5, y: 0.5, z: 0.5) }
        let adapter = MockSensorAdapter(samples: manySamples)
        let manager = SensorManager(adapters: [adapter])

        let task = Task {
            var count = 0
            for await event in manager.events() {
                if case .sample = event {
                    count += 1
                    if count >= 3 { break }
                }
            }
            return count
        }

        let count = await task.value
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    func testEventsReportsAdapterError() async {
        let failing = MockSensorAdapter(name: "Flaky", samples: [], error: SensorError.deviceNotFound)
        let manager = SensorManager(adapters: [failing])

        var messages: [String] = []
        for await event in manager.events() {
            if case .error(let msg) = event { messages.append(msg) }
        }

        XCTAssertTrue(messages.contains(where: { $0.contains("Flaky") }))
    }
}

// MARK: - SensorError tests

final class SensorErrorTests: XCTestCase {

    func testErrorDescriptions() {
        struct Case { let error: SensorError; let substring: String }
        let cases: [Case] = [
            .init(error: .permissionDenied, substring: "Input Monitoring"),
            .init(error: .deviceNotFound, substring: "No accelerometer"),
            .init(error: .ioKitError("0xDEAD"), substring: "0xDEAD"),
            .init(error: .noAdaptersAvailable, substring: "No compatible"),
        ]
        for c in cases {
            let desc = c.error.localizedDescription
            XCTAssertTrue(desc.contains(c.substring),
                "'\(c.error)' description should contain '\(c.substring)', got: \(desc)")
        }
    }
}
