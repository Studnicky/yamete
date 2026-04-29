import XCTest
import os
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

// MARK: - ImpactDetector tests (per-adapter gate pipeline)

final class ImpactDetectorTests: XCTestCase {

    private func permissiveConfig(threshold: Float = 0.01, warmup: Int = 0) -> ImpactDetectorConfig {
        ImpactDetectorConfig(
            spikeThreshold: threshold, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: warmup,
            intensityFloor: 0.01, intensityCeiling: 1.0
        )
    }

    func testImpactDetectedAboveThreshold() {
        let detector = ImpactDetector(config: permissiveConfig(), adapterName: "test")
        let result = detector.process(magnitude: 0.5, timestamp: Date())
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result ?? 0, 0)
    }

    func testBelowThresholdDoesNotTrigger() {
        let detector = ImpactDetector(config: permissiveConfig(threshold: 0.5), adapterName: "test")
        let result = detector.process(magnitude: 0.3, timestamp: Date())
        XCTAssertNil(result)
    }

    func testWarmupGate() {
        let detector = ImpactDetector(config: permissiveConfig(warmup: 10), adapterName: "test")
        let now = Date()

        // During warmup
        for i in 0..<9 {
            let result = detector.process(magnitude: 0.8, timestamp: now.addingTimeInterval(Double(i) * 0.02))
            XCTAssertNil(result, "Should not trigger during warmup (sample \(i))")
        }

        // After warmup
        let result = detector.process(magnitude: 0.8, timestamp: now.addingTimeInterval(0.20))
        XCTAssertNotNil(result, "Should trigger after warmup")
    }

    func testIntensityMapping() {
        let config = ImpactDetectorConfig(
            spikeThreshold: 0.01, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: 0,
            intensityFloor: 0.1, intensityCeiling: 1.0
        )
        let detector = ImpactDetector(config: config, adapterName: "test")

        let result = detector.process(magnitude: 0.55, timestamp: Date())
        XCTAssertNotNil(result)
        // (0.55 - 0.1) / (1.0 - 0.1) = 0.5
        XCTAssertEqual(result ?? 0, 0.5, accuracy: 0.01)
    }
}

// MARK: - ImpactFusion tests

@MainActor
final class ImpactFusionTests: XCTestCase {

    func testSingleSourceTriggers() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 1))
        let now = Date()

        let result = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.intensity ?? 0, 0.8, accuracy: 0.01)
    }

    func testConsensusRequiresTwoWhenConfigured() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 2, fusionWindow: 0.2))
        let now = Date()

        let aOnly = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A"), SensorID("B")]
        )
        XCTAssertNil(aOnly)

        let both = engine.ingest(
            SensorImpact(source: SensorID("B"), timestamp: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: [SensorID("A"), SensorID("B")]
        )
        XCTAssertNotNil(both)
        // Average of 0.8 and 0.6
        XCTAssertEqual(both?.intensity ?? 0, 0.7, accuracy: 0.01)
    }

    func testConsensusClampedToActiveSources() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 5))
        let now = Date()

        // Only 1 active source → consensus clamped to 1 → triggers
        let result = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(result)
    }

    func testRearmPreventsRetrigger() {
        let engine = ImpactFusion(config: FusionConfig(consensusRequired: 1, rearmDuration: 0.5))
        let now = Date()

        let first = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: [SensorID("A")]
        )
        XCTAssertNotNil(first)

        let blocked = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now.addingTimeInterval(0.2), intensity: 0.9),
            activeSources: [SensorID("A")]
        )
        XCTAssertNil(blocked)
    }

    // MARK: - Mutation-anchor cells
    //
    // These cells exist specifically to anchor mutation-catalog entries
    // for `ImpactDetection.swift`. Each cell pins ONE production guard
    // to a deterministic synthetic input, and the failure messages
    // embed `[fusion-gate=...]` coordinates that the catalog substrings
    // pin to.

    /// `ImpactDetection.swift` line 161: rearmDuration guard. Removing
    /// it would let an impact within the rearm window re-trigger.
    func testFusionRearmGate_withinRearm_returnsNil() {
        let engine = ImpactFusion(config: FusionConfig(
            consensusRequired: 1,
            rearmDuration: 1.0
        ))
        let now = Date()
        let active: Set<SensorID> = [SensorID("A")]

        // First impact triggers — drains state.
        let first = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.8),
            activeSources: active
        )
        XCTAssertNotNil(first, "[fusion-gate=rearm] first impact must trigger to arm rearm window")

        // Second impact at +0.10s is well inside the 1.0s rearm — must
        // be blocked. Removing the rearm guard would let it through.
        let blocked = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now.addingTimeInterval(0.10), intensity: 0.9),
            activeSources: active
        )
        XCTAssertNil(
            blocked,
            "[fusion-gate=rearm] impact within 1.0s rearm window must NOT re-trigger"
        )
    }

    /// `ImpactDetection.swift` line 168: consensus participating-sources
    /// gate. Removing it would let one source meet a 2-source consensus
    /// requirement.
    func testFusionConsensusGate_singleSource_belowRequired_returnsNil() {
        let engine = ImpactFusion(config: FusionConfig(
            consensusRequired: 2,
            fusionWindow: 0.30
        ))
        let now = Date()
        // Two active sensors but only ONE reports — consensus 2/2 unmet.
        let active: Set<SensorID> = [SensorID("A"), SensorID("B")]

        let r1 = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now, intensity: 0.9),
            activeSources: active
        )
        XCTAssertNil(
            r1,
            "[fusion-gate=consensus] single participating source must NOT meet 2-of-2 consensus"
        )

        // Same source again — still 1 unique participating source.
        let r2 = engine.ingest(
            SensorImpact(source: SensorID("A"), timestamp: now.addingTimeInterval(0.05), intensity: 0.8),
            activeSources: active
        )
        XCTAssertNil(
            r2,
            "[fusion-gate=consensus] repeated impacts from same source must NOT meet 2-of-2 consensus"
        )
    }
}

// MARK: - ImpactFusion start() availability gate

/// `ImpactDetection.swift` line 85: empty-availability gate inside
/// `start(sources:bus:)`. Removing it would silently mark the fusion
/// engine running with zero sources and never surface the no-adapters
/// error to the UI.
@MainActor
final class ImpactFusionAvailabilityGateTests: XCTestCase {

    /// Stub source whose `isAvailable` is configurable. Used to drive
    /// the empty-available branch of `ImpactFusion.start(...)`.
    private final class StubSource: SensorSource, @unchecked Sendable {
        let id: SensorID
        let name: String
        let isAvailable: Bool
        init(id: SensorID, available: Bool) {
            self.id = id
            self.name = id.rawValue
            self.isAvailable = available
        }
        func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    func testStartWithNoAvailableSources_invokesOnError_doesNotMarkRunning() async {
        let engine = ImpactFusion()
        let bus = ReactionBus()
        let source = StubSource(id: SensorID("A"), available: false)

        let captured = OSAllocatedUnfairLock<String?>(initialState: nil)
        engine.onError = { @MainActor message in
            captured.withLock { $0 = message }
        }

        engine.start(sources: [source], bus: bus)

        let surfaced = captured.withLock { $0 }
        XCTAssertNotNil(
            surfaced,
            "[fusion-gate=empty-available] start() with no available sources must invoke onError"
        )
        XCTAssertFalse(
            engine.isRunning,
            "[fusion-gate=empty-available] start() with no available sources must NOT mark engine running"
        )
        XCTAssertEqual(
            engine.activeSources.count, 0,
            "[fusion-gate=empty-available] activeSources must remain empty when no sources are available"
        )
    }
}

/// Pins `ImpactDetection.swift:135` `guard isRunning else { return }` in
/// `stop()`. Removing the gate would let `stop()` proceed to invalidate
/// already-invalid resources (cancel nil tasks, finish nil continuations),
/// which CFRuntime tolerates silently — observable only via `_testHooks`.
@MainActor
final class ImpactFusionStopIdempotencyGateTests: XCTestCase {

    func testStopWhenNotRunning_isNoOp() {
        let engine = ImpactFusion()
        XCTAssertFalse(engine.isRunning, "precondition: engine must start not-running")
        engine.stop()
        XCTAssertEqual(
            engine._testHooks.stopInvocationCount, 1,
            "[fusion-gate=stop-idempotency] stop() must always increment invocation counter"
        )
        XCTAssertEqual(
            engine._testHooks.stopTeardownCount, 0,
            "[fusion-gate=stop-idempotency] stop() on not-running engine must NOT take the teardown branch"
        )
        XCTAssertTrue(
            engine._testHooks.lastStopWasNoOp,
            "[fusion-gate=stop-idempotency] stop() on not-running engine must mark lastStopWasNoOp"
        )
    }
}
