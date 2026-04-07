import XCTest
@testable import YameteCore
@testable import SensorKit

// MARK: - ImpactFusionEngine end-to-end tests
//
// Tests multi-sensor consensus, fusion window timing, rearm cooldown,
// and intensity averaging without any hardware dependency.

@MainActor
final class ImpactFusionE2ETests: XCTestCase {

    private let sensorA = SensorID("accelerometer")
    private let sensorB = SensorID("microphone")
    private let sensorC = SensorID("headphone")

    private func impact(_ source: SensorID, at time: Date, intensity: Float) -> SensorImpact {
        SensorImpact(source: source, timestamp: time, intensity: intensity)
    }

    // MARK: - Single sensor with consensus=2 does NOT trigger

    func testSingleSensorDoesNotTriggerWithConsensusTwo() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        // Only sensor A reports
        let result = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNil(result, "Single sensor should not trigger when consensus=2")
    }

    func testMultipleSameSensorDoNotTriggerConsensus() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        // Sensor A reports twice -- still only 1 unique source
        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.7), activeSources: active)
        XCTAssertNil(r1)

        let r2 = engine.ingest(impact(sensorA, at: now.addingTimeInterval(0.05), intensity: 0.8), activeSources: active)
        XCTAssertNil(r2, "Two impacts from same sensor should not meet consensus=2")
    }

    // MARK: - Two sensors within fusion window triggers

    func testTwoSensorsWithinWindowTriggersConsensus() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNil(r1, "First sensor alone should not trigger")

        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.10), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNotNil(r2, "Two different sensors within fusion window should trigger")
    }

    func testThreeSensorsConsensusTwo() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB, sensorC]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.5), activeSources: active)
        XCTAssertNil(r1)

        // Second sensor triggers consensus=2
        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.7),
            activeSources: active
        )
        XCTAssertNotNil(r2, "Second of three sensors should trigger consensus=2")
    }

    func testThreeSensorsConsensusThree() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 3, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB, sensorC]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.5), activeSources: active)
        XCTAssertNil(r1)

        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.03), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNil(r2, "Two sensors should not trigger consensus=3")

        let r3 = engine.ingest(
            impact(sensorC, at: now.addingTimeInterval(0.06), intensity: 0.7),
            activeSources: active
        )
        XCTAssertNotNil(r3, "Three sensors should trigger consensus=3")
    }

    // MARK: - Impacts outside fusion window

    func testImpactsOutsideFusionWindowDontCountTogether() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.10, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        // Sensor A reports at t=0
        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNil(r1)

        // Sensor B reports at t=0.20 -- outside the 0.10s fusion window
        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.20), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNil(r2, "Impacts separated by more than fusionWindow should not count together")
    }

    func testImpactJustInsideFusionWindowTriggers() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNil(r1)

        // Just inside the window (0.14 < 0.15)
        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.14), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNotNil(r2, "Impact just inside fusion window should trigger")
    }

    func testImpactJustOutsideFusionWindowRejects() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNil(r1)

        // Just outside the window (0.16 > 0.15)
        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.16), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNil(r2, "Impact just outside fusion window should not trigger")
    }

    // MARK: - Rearm cooldown

    func testRearmCooldownBlocksRapidRetriggers() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 1, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA]

        // First impact triggers
        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNotNil(r1, "First impact should trigger")

        // Second impact during rearm window -- blocked
        let r2 = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(0.30), intensity: 0.9),
            activeSources: active
        )
        XCTAssertNil(r2, "Impact during rearm cooldown should be blocked")

        // Third impact just before rearm expires -- still blocked
        let r3 = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(0.49), intensity: 0.9),
            activeSources: active
        )
        XCTAssertNil(r3, "Impact just before rearm expiry should be blocked")
    }

    func testImpactAfterRearmCooldownTriggers() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 1, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNotNil(r1)

        // Impact after rearm duration -- should trigger
        let r2 = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(0.55), intensity: 0.7),
            activeSources: active
        )
        XCTAssertNotNil(r2, "Impact after rearm cooldown expires should trigger")
    }

    func testRearmWithMultiSensorConsensus() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        // First consensus trigger
        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        let r1 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNotNil(r1, "First consensus should trigger")

        // Second pair during rearm -- blocked even with consensus
        _ = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(0.20), intensity: 0.9),
            activeSources: active
        )
        let r2 = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.25), intensity: 0.8),
            activeSources: active
        )
        XCTAssertNil(r2, "Consensus during rearm should be blocked")
    }

    // MARK: - FusedImpact intensity averaging

    func testFusedIntensityIsAverageOfSources() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        let result = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.4),
            activeSources: active
        )

        XCTAssertNotNil(result)
        // Average of 0.8 and 0.4 = 0.6
        XCTAssertEqual(result?.intensity ?? 0, 0.6, accuracy: 0.01, "Fused intensity should be average of sources")
    }

    func testFusedIntensityThreeSources() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 3, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB, sensorC]

        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.6), activeSources: active)
        _ = engine.ingest(impact(sensorB, at: now.addingTimeInterval(0.03), intensity: 0.8), activeSources: active)
        let result = engine.ingest(
            impact(sensorC, at: now.addingTimeInterval(0.06), intensity: 1.0),
            activeSources: active
        )

        XCTAssertNotNil(result)
        // Average of 0.6, 0.8, 1.0 = 0.8
        XCTAssertEqual(result?.intensity ?? 0, 0.8, accuracy: 0.01,
                       "Fused intensity of three sources should be their average")
    }

    func testFusedIntensityUsesStrongestPerSource() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        // Sensor A reports twice, with different intensities
        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.3), activeSources: active)
        _ = engine.ingest(impact(sensorA, at: now.addingTimeInterval(0.02), intensity: 0.9), activeSources: active)

        let result = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.5),
            activeSources: active
        )

        XCTAssertNotNil(result)
        // Should use best per source: A=0.9, B=0.5, average = 0.7
        XCTAssertEqual(result?.intensity ?? 0, 0.7, accuracy: 0.01,
                       "Fusion should use strongest impact per source for averaging")
    }

    // MARK: - Confidence value

    func testFusedConfidenceReflectsSensorParticipation() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB, sensorC]

        // Only 2 of 3 active sensors participate
        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        let result = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: active
        )

        XCTAssertNotNil(result)
        // 2 participants / 3 active = 0.667
        XCTAssertEqual(result?.confidence ?? 0, 2.0 / 3.0, accuracy: 0.01,
                       "Confidence should be fraction of active sensors that participated")
    }

    func testFusedConfidenceAllSensors() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        let result = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: active
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.confidence ?? 0, 1.0, accuracy: 0.01,
                       "All active sensors participating should yield confidence=1.0")
    }

    // MARK: - Sources list

    func testFusedImpactContainsParticipatingSourceIDs() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB, sensorC]

        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        let result = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: active
        )

        XCTAssertNotNil(result)
        let sourceSet = Set(result?.sources ?? [])
        XCTAssertTrue(sourceSet.contains(sensorA), "Sources should contain sensor A")
        XCTAssertTrue(sourceSet.contains(sensorB), "Sources should contain sensor B")
        XCTAssertFalse(sourceSet.contains(sensorC), "Sources should not contain non-participating sensor C")
    }

    // MARK: - Reset behavior

    func testResetClearsStateAllowsImmediateRetrigger() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 1, fusionWindow: 0.15, rearmDuration: 1.0
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA]

        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNotNil(r1)

        // During rearm -- should be blocked
        let r2 = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(0.1), intensity: 0.8),
            activeSources: active
        )
        XCTAssertNil(r2)

        // Reset clears state
        engine.reset()

        // Should trigger immediately after reset
        let r3 = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(0.2), intensity: 0.8),
            activeSources: active
        )
        XCTAssertNotNil(r3, "Impact after reset should trigger immediately")
    }

    // MARK: - Consensus clamping

    func testConsensusClampedToActiveSensorCount() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 5, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        // Only 2 sensors active -- consensus clamped from 5 to 2
        let active: Set<SensorID> = [sensorA, sensorB]

        _ = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        let result = engine.ingest(
            impact(sensorB, at: now.addingTimeInterval(0.05), intensity: 0.6),
            activeSources: active
        )
        XCTAssertNotNil(result, "Consensus should clamp to active sensor count (2)")
    }

    func testConsensusSingleActiveClampedToOne() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 3, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA]

        let result = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNotNil(result, "Single active sensor should trigger regardless of consensus config")
    }

    // MARK: - Configure mid-stream

    func testConfigureChangesRuntimeBehavior() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 1, fusionWindow: 0.15, rearmDuration: 0.50
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA, sensorB]

        // With consensus=1, single sensor triggers
        let r1 = engine.ingest(impact(sensorA, at: now, intensity: 0.8), activeSources: active)
        XCTAssertNotNil(r1)

        // Change to consensus=2 at runtime
        engine.configure(FusionConfig(consensusRequired: 2, fusionWindow: 0.15, rearmDuration: 0.50))
        engine.reset() // clear rearm state

        // Now single sensor should not trigger
        let r2 = engine.ingest(
            impact(sensorA, at: now.addingTimeInterval(1.0), intensity: 0.8),
            activeSources: active
        )
        XCTAssertNil(r2, "After configure to consensus=2, single sensor should not trigger")
    }

    // MARK: - Rapid fire sequence

    func testRapidFireSequenceRespectsRearm() {
        let engine = ImpactFusionEngine(config: FusionConfig(
            consensusRequired: 1, fusionWindow: 0.15, rearmDuration: 0.30
        ))
        let now = Date()
        let active: Set<SensorID> = [sensorA]

        var triggerCount = 0
        // 20 impacts over 2 seconds
        for i in 0..<20 {
            let ts = now.addingTimeInterval(Double(i) * 0.10)
            if engine.ingest(impact(sensorA, at: ts, intensity: 0.5), activeSources: active) != nil {
                triggerCount += 1
            }
        }

        // With 0.30s rearm and 2.0s total, max triggers: ~7 (2.0/0.30 rounded)
        XCTAssertGreaterThan(triggerCount, 0, "Should have at least one trigger")
        XCTAssertLessThanOrEqual(triggerCount, 8, "Rearm should limit trigger count")
    }
}
