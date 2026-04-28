import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// For each stimulus source, drive `_testEmit(kind)` for every kind in its
/// contract and verify each kind reaches the bus as a `FiredReaction`.
@MainActor
final class StimulusSourceContractTests: XCTestCase {

    func testEverySourceEmitsItsDeclaredKinds() async throws {
        for contract in SourceContract.all {
            try await runContract(contract)
        }
    }

    private func runContract(_ contract: SourceContract) async throws {
        let harness = BusHarness()
        await harness.setUp()

        guard let source = SourceContract.makeSource(for: contract.id) else {
            XCTFail("makeSource returned nil for \(contract.id.rawValue)")
            return
        }
        guard let emitter = source as? TestEmitter else {
            XCTFail("Source \(contract.id.rawValue) does not conform to TestEmitter")
            return
        }

        await source.start(publishingTo: harness.bus)

        // Spawn the collector before any emit so the subscription is in place.
        async let collected = harness.collectFor(seconds: 0.5)

        // Allow the subscription to register.
        try await Task.sleep(for: .milliseconds(40))

        for kind in contract.emittedKinds {
            await emitter._testEmit(kind)
            try await Task.sleep(for: .milliseconds(20))
        }

        let fired = await collected
        let firedKinds = fired.map(\.kind)

        for kind in contract.emittedKinds {
            XCTAssertTrue(firedKinds.contains(kind),
                          "[\(contract.id.rawValue)] expected \(kind.rawValue) on bus, got \(firedKinds.map(\.rawValue))")
        }

        source.stop()
    }
}
