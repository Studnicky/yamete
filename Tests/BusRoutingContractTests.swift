import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Bus-fanout contract: every (source, kind) pair fans out from the bus to
/// every subscribed output, and every kind blocked by the
/// `OutputConfigProvider` matrix is gated before delivery.
///
/// This file deliberately uses `_testEmit` to bypass source detection. It
/// exercises the bus + ReactionKind + OutputConfigProvider gate matrix in
/// isolation — proving the dispatch + enricher + gate logic regardless of
/// how a real source detects activity. For source-detection-pipeline
/// coverage at Ring 1 (`_inject*`) and Ring 2 (CGEvent / Notification /
/// IOKit callbacks), see `StimulusSourceContractTests`,
/// `StimulusToOutputScenariosTests`, the `Matrix*OSEvents_Tests`, and the
/// `MatrixL2_*` files.
///
/// The `_testEmit` calls below are NOT Ring 1 misses — they are intentional
/// orthogonal coverage of the bus-fanout contract. Source-detection
/// coverage lives elsewhere.
@MainActor
final class BusRoutingContractTests: XCTestCase {

    // MARK: - Bus fanout: every kind reaches the bus as a FiredReaction

    // MOVED-FROM: StimulusSourceContractTests.testEverySourceEmitsItsDeclaredKinds
    func testEverySourceEmitsItsDeclaredKinds() async throws {
        for contract in SourceContract.all {
            try await runContract(contract)
        }
    }

    // MARK: - Bus routing: every (source, kind) reaches a subscribed output

    // MOVED-FROM: StimulusToOutputScenariosTests.test_everySourceKind_reachesSubscribedOutput
    func test_busRoutes_everySourceKind_toSubscribedOutput() async throws {
        for contract in SourceContract.all {
            for kind in contract.emittedKinds {
                try await runReachableCase(contract: contract, kind: kind)
            }
        }
    }

    // MARK: - Bus gating: every disabled kind is blocked before output

    // MOVED-FROM: StimulusToOutputScenariosTests.test_disabledKind_isBlockedFromOutput
    func test_busBlocks_disabledKind_fromOutput() async throws {
        for contract in SourceContract.all {
            for kind in contract.emittedKinds {
                try await runBlockedCase(contract: contract, kind: kind)
            }
        }
    }

    // MARK: - Helpers

    // MOVED-FROM: StimulusSourceContractTests.runContract
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
        // CI-scale the collect window so the emit + subscribe latencies fit.
        let collectSeconds: TimeInterval = CITiming.isCI ? 1.5 : 0.5
        async let collected = harness.collectFor(seconds: collectSeconds)

        // Allow the subscription to register. CI-scaled.
        try await Task.sleep(for: CITiming.scaledDuration(ms: 60))

        for kind in contract.emittedKinds {
            await emitter._testEmit(kind)
            try await Task.sleep(for: CITiming.scaledDuration(ms: 20))
        }

        let fired = await collected
        let firedKinds = fired.map(\.kind)

        for kind in contract.emittedKinds {
            XCTAssertTrue(firedKinds.contains(kind),
                          "[\(contract.id.rawValue)] expected \(kind.rawValue) on bus, got \(firedKinds.map(\.rawValue))")
        }

        source.stop()
    }

    // MOVED-FROM: StimulusToOutputScenariosTests.runReachableCase
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
        // Allow consume() to subscribe before emitting. CI-scaled — under
        // CI load a 30 ms `Task.sleep` can drift past 100 ms and the emit
        // can land before the consume task has registered its subscription.
        try await Task.sleep(for: CITiming.scaledDuration(ms: 50))

        await emitter._testEmit(kind)

        // Poll until the action lands rather than waiting a fixed 150 ms.
        // Some sources (Bluetooth, keyboard activity) take longer to flow
        // through their detection pipeline on CI; the bare 150 ms tail
        // expired before the action wrote and the assertion below tripped.
        _ = await awaitUntil(timeout: 2.0) {
            spy.actionKinds().contains(kind)
        }

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

    // MOVED-FROM: StimulusToOutputScenariosTests.runBlockedCase
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
        try await Task.sleep(for: CITiming.scaledDuration(ms: 50))

        await emitter._testEmit(kind)
        // The blocked case asserts the kind never fires. We still need a
        // bounded settle window to give the bus time to deliver and the
        // gate time to reject. Use the CI-scaled tail so we don't trip
        // an early "no action yet" false negative on slow runners.
        try await Task.sleep(for: CITiming.scaledDuration(ms: 200))

        XCTAssertFalse(gated.actionKinds().contains(kind),
                       "[\(contract.id.rawValue)/\(kind.rawValue)] action fired despite block — got \(gated.actionKinds().map(\.rawValue))")

        source.stop()
        consumeTask.cancel()
        await harness.close()
    }
}
