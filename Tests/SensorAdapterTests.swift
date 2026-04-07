import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

// MARK: - Mock adapter for testing SensorManager

/// Test adapter that yields a fixed impact sequence.
final class MockSensorAdapter: SensorAdapter, @unchecked Sendable {
    let id: SensorID
    let name: String
    let isAvailable: Bool
    private let impactSequence: [SensorImpact]
    private let error: Error?

    init(name: String = "Mock", available: Bool = true, impacts: [SensorImpact] = [], error: Error? = nil) {
        self.id = SensorID(name)
        self.name = name
        self.isAvailable = available
        self.impactSequence = impacts
        self.error = error
    }

    convenience init(name: String = "Mock", available: Bool = true, intensities: [Float] = [], error: Error? = nil) {
        let impacts = intensities.map {
            SensorImpact(source: SensorID(name), timestamp: Date(), intensity: $0)
        }
        self.init(name: name, available: available, impacts: impacts, error: error)
    }

    func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let seq = impactSequence
        let err = error
        return AsyncThrowingStream { continuation in
            for impact in seq { continuation.yield(impact) }
            if let err { continuation.finish(throwing: err) }
            else { continuation.finish() }
        }
    }
}

// MARK: - SensorManager tests

@MainActor
final class SensorManagerTests: XCTestCase {

    func testEventsYieldsImpactsFromAvailableAdapter() async {
        let adapter = MockSensorAdapter(name: "A", intensities: [0.5, 0.8])
        let manager = SensorManager(adapters: [adapter])

        var received: [SensorImpact] = []
        for await event in manager.events() {
            if case .impact(let impact) = event { received.append(impact) }
        }

        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0.source == SensorID("A") })
    }

    func testEventsSkipsUnavailableAdapters() async {
        let unavailable = MockSensorAdapter(name: "Unavailable", available: false, intensities: [0.9])
        let available = MockSensorAdapter(name: "Available", available: true, intensities: [0.5])
        let manager = SensorManager(adapters: [unavailable, available])

        var activeSnapshots: [[String]] = []
        var impactCount = 0
        for await event in manager.events() {
            switch event {
            case .adaptersChanged(_, let names): activeSnapshots.append(names)
            case .impact: impactCount += 1
            case .error: break
            }
        }

        XCTAssertEqual(impactCount, 1)
        XCTAssertTrue(activeSnapshots.contains(["Available"]))
    }

    func testEventsReportsErrorOnNoAdapters() async {
        let manager = SensorManager(adapters: [])
        var errors: [String] = []
        for await event in manager.events() {
            if case .error(let msg) = event { errors.append(msg) }
        }
        XCTAssertFalse(errors.isEmpty)
    }

    func testEventsPublishesAdapterLifecycle() async {
        let a = MockSensorAdapter(name: "A", intensities: [0.5])
        let b = MockSensorAdapter(name: "B", intensities: [0.5])
        let manager = SensorManager(adapters: [a, b])

        var snapshots: [[String]] = []
        for await event in manager.events() {
            if case .adaptersChanged(_, let names) = event { snapshots.append(names) }
        }

        XCTAssertTrue(snapshots.contains(["A", "B"]))
        XCTAssertEqual(snapshots.last, [])
    }

    func testEventsCancellation() async {
        let impacts = (0..<1000).map {
            SensorImpact(source: SensorID("Mock"), timestamp: Date(), intensity: Float($0) / 1000)
        }
        let adapter = MockSensorAdapter(impacts: impacts)
        let manager = SensorManager(adapters: [adapter])

        let task = Task {
            var count = 0
            for await event in manager.events() {
                if case .impact = event {
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
        let failing = MockSensorAdapter(name: "Flaky", intensities: [], error: SensorError.deviceNotFound)
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
