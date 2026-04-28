import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Headline matrix test: every (source, kind) pair drives a SpyOutput action,
/// and per-kind blocking via the OutputConfigProvider matrix prevents action
/// delivery for the GatedSpyOutput.
@MainActor
final class StimulusToOutputScenariosTests: XCTestCase {

    func test_everySourceKind_reachesSubscribedOutput() async throws {
        for contract in SourceContract.all {
            for kind in contract.emittedKinds {
                try await runReachableCase(contract: contract, kind: kind)
            }
        }
    }

    private func runReachableCase(contract: SourceContract, kind: ReactionKind) async throws {
        let harness = BusHarness()
        await harness.setUp()

        guard let source = SourceContract.makeSource(for: contract.id),
              let emitter = source as? TestEmitter else {
            XCTFail("Cannot build source/emitter for \(contract.id.rawValue)")
            return
        }
        await source.start(publishingTo: harness.bus)

        let provider = MockConfigProvider()
        let spy = MatrixSpyOutput()

        let consumeTask = Task { @MainActor [bus = harness.bus] in
            await spy.consume(from: bus, configProvider: provider)
        }
        // Allow consume() to subscribe before emitting.
        try await Task.sleep(for: .milliseconds(30))

        await emitter._testEmit(kind)

        // Give coalesce (16 ms) + action (~2 ms) + slack to land.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(spy.actionKinds().contains(kind),
                      "[\(contract.id.rawValue)/\(kind.rawValue)] action did not fire — got \(spy.actionKinds().map(\.rawValue))")
        // Strict-equal assertion: emitting a single kind must produce
        // EXACTLY one matching action call. A regression where an emit
        // double-fans-out or echos a different kind is caught here.
        let matchCount = spy.actionKinds().filter { $0 == kind }.count
        XCTAssertEqual(matchCount, 1,
                       "[\(contract.id.rawValue)/\(kind.rawValue)] expected exactly 1 action of this kind, got \(matchCount); kinds=\(spy.actionKinds().map(\.rawValue))")

        source.stop()
        consumeTask.cancel()
        await harness.close()
    }

    func test_disabledKind_isBlockedFromOutput() async throws {
        for contract in SourceContract.all {
            for kind in contract.emittedKinds {
                try await runBlockedCase(contract: contract, kind: kind)
            }
        }
    }

    private func runBlockedCase(contract: SourceContract, kind: ReactionKind) async throws {
        let harness = BusHarness()
        await harness.setUp()

        guard let source = SourceContract.makeSource(for: contract.id),
              let emitter = source as? TestEmitter else {
            XCTFail("Cannot build source/emitter for \(contract.id.rawValue)")
            return
        }
        await source.start(publishingTo: harness.bus)

        let provider = MockConfigProvider()
        provider.block(kind: kind)

        let gated = GatedSpyOutput()

        let consumeTask = Task { @MainActor [bus = harness.bus] in
            await gated.consume(from: bus, configProvider: provider)
        }
        try await Task.sleep(for: .milliseconds(30))

        await emitter._testEmit(kind)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(gated.actionKinds().contains(kind),
                       "[\(contract.id.rawValue)/\(kind.rawValue)] action fired despite block — got \(gated.actionKinds().map(\.rawValue))")

        source.stop()
        consumeTask.cancel()
        await harness.close()
    }
}
