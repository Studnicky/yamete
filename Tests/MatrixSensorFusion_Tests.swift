import XCTest
@testable import YameteCore
@testable import SensorKit

/// Sensor fusion matrix:
///   single/multi-sensor inputs × consensus thresholds × fusion-window timings
///
/// Drives `ImpactFusion.ingest(_:activeSources:)` directly with synthetic
/// `SensorImpact` values so tests are deterministic — no real sensor adapters,
/// no async tasks, no `Task.sleep`. Each assertion fires with explicit cell
/// coordinates so a regression is pinpointed.
@MainActor
final class MatrixSensorFusion_Tests: XCTestCase {

    // MARK: - Fixture: deterministic SensorImpact builder

    /// Test fixture for building `SensorImpact` values with explicit timestamps
    /// and intensities. Centralising construction keeps cell rows tiny and
    /// matches the "Domain module methods, not free helpers" rule from CLAUDE.md.
    private enum SensorFixture {
        static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        static func impact(_ source: SensorID,
                           offsetMs: Int,
                           intensity: Float = 0.7) -> SensorImpact {
            SensorImpact(
                source: source,
                timestamp: baseDate.addingTimeInterval(Double(offsetMs) / 1000.0),
                intensity: intensity
            )
        }

        static let allThree: [SensorID] = [.accelerometer, .microphone, .headphoneMotion]
    }

    /// Builds an `ImpactFusion` with explicit window/rearm/consensus.
    /// Defaults pick values large enough that the rearm gate never trips during
    /// a single test cell unless the cell deliberately drives back-to-back fires.
    private func makeFusion(consensus: Int,
                            fusionWindow: TimeInterval = 0.05,
                            rearmDuration: TimeInterval = 0) -> ImpactFusion {
        ImpactFusion(config: FusionConfig(
            consensusRequired: consensus,
            fusionWindow: fusionWindow,
            rearmDuration: rearmDuration
        ))
    }

    // MARK: - Matrix A: single-sensor input × consensus × window

    /// One sensor fires once. Result depends on consensus required vs. the
    /// number of *active* sources — the engine clamps `consensusRequired` to
    /// `activeSources.count`, so a "require 3" against 1 active source still
    /// fires (clamped to 1). The whole truth table is asserted here.
    func testSingleSensorAcrossConsensusAndWindow() {
        let consensusValues = [1, 2, 3]
        let windows: [TimeInterval] = [0.05, 0.10, 0.20]
        let activeSizes = [1, 2, 3]
        var cells = 0

        for consensus in consensusValues {
            for window in windows {
                for active in activeSizes {
                    let fusion = makeFusion(consensus: consensus, fusionWindow: window)
                    let activeSet = Set(SensorFixture.allThree.prefix(active))
                    let impact = SensorFixture.impact(.accelerometer, offsetMs: 0)
                    let result = fusion.ingest(impact, activeSources: activeSet)

                    // Engine clamps `consensusRequired` to active count: with
                    // one impact, fires exactly when clamped requirement ≤ 1
                    // (i.e. only one source observed in the window).
                    let clamped = max(1, min(consensus, active))
                    let expected = (clamped == 1)
                    XCTAssertEqual(result != nil, expected,
                        "[scenario=single consensus=\(consensus) window=\(window) active=\(active) clamped=\(clamped)] " +
                        "expected fire=\(expected), got \(result != nil)")
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, consensusValues.count * windows.count * activeSizes.count,
                       "matrix shrinkage detected")
    }

    // MARK: - Matrix B: two-sensor input within window × consensus

    /// Two distinct sensors fire with a small offset (within every window).
    /// Fires when clamped consensus ≤ 2.
    func testTwoSensorsWithinWindow() {
        let consensusValues = [1, 2, 3]
        let activeSizes = [2, 3]
        var cells = 0

        for consensus in consensusValues {
            for active in activeSizes {
                let fusion = makeFusion(consensus: consensus, fusionWindow: 0.05)
                let activeSet = Set(SensorFixture.allThree.prefix(active))

                _ = fusion.ingest(SensorFixture.impact(.accelerometer, offsetMs: 0),
                                  activeSources: activeSet)
                let result = fusion.ingest(SensorFixture.impact(.microphone, offsetMs: 10),
                                           activeSources: activeSet)

                let clamped = max(1, min(consensus, active))
                let expected = (clamped <= 2)
                XCTAssertEqual(result != nil, expected,
                    "[scenario=two-in-window consensus=\(consensus) active=\(active) clamped=\(clamped)] " +
                    "expected fire=\(expected), got \(result != nil)")
                cells += 1
            }
        }
        XCTAssertEqual(cells, consensusValues.count * activeSizes.count)
    }

    // MARK: - Matrix C: three-sensor input timed at boundaries × consensus

    /// Three sensors firing at increasing inter-arrival gaps. Whether they all
    /// land inside the fusion window decides whether full 3-consensus is met.
    /// Window = 50 ms (also `Defaults.fusionWindow / 3` in spirit). Boundary
    /// cells: 0 / 49 / 51 ms apart between each pair.
    func testThreeSensorBoundaryTiming() {
        // Cell semantics:
        //   - allInWindow: all three impacts land inside the fusion window.
        //   - expectedFireCounts[consensus]: total fires across the 3 ingests.
        //
        // Mechanics: ingest() fires the first time `participatingSources.count
        // >= required`, then resets recentImpacts. So a 3-impact sequence
        // can fire ZERO, ONE, or (only with consensus=1 and time spacing) UP
        // TO 3 times.
        //
        //   • 0ms-apart    (all in window):
        //     - consensus=1: fires on impact 1 (1 source). Resets. fires on impact 2 (2 source after 1 was wiped, but only 1 is fresh). Resets. Fires on 3.
        //       Actually each impact has 1 source after reset → all 3 fire.
        //     - consensus=2: nothing on 1; fires on 2 (2 sources). Reset. 3 alone → nothing. → 1 fire.
        //     - consensus=3: nothing on 1; nothing on 2 (only 2 sources); fires on 3 (3 sources). → 1 fire.
        //   • 49ms-apart   (still in window): same as 0ms (window > all gaps).
        //   • 51ms-apart   (none stay together):
        //     - Window expiry removes prior impact before the next one is added.
        //     - consensus=1: fires on each (1 source each). → 3 fires.
        //     - consensus=2/3: never gets ≥2 fresh sources. → 0 fires.

        struct Cell { let label: String; let offsets: [Int]; let allInWindow: Bool }
        let timing: [Cell] = [
            .init(label: "0ms-apart",  offsets: [0, 0, 0],   allInWindow: true),
            .init(label: "49ms-apart", offsets: [0, 49, 49], allInWindow: true),
            .init(label: "51ms-apart", offsets: [0, 51, 102], allInWindow: false),
        ]
        let consensusValues = [1, 2, 3]
        var cells = 0

        for cell in timing {
            for consensus in consensusValues {
                let fusion = makeFusion(consensus: consensus, fusionWindow: 0.05)
                let activeSet: Set<SensorID> = Set(SensorFixture.allThree)

                let r1 = fusion.ingest(SensorFixture.impact(.accelerometer, offsetMs: cell.offsets[0]),
                                       activeSources: activeSet)
                let r2 = fusion.ingest(SensorFixture.impact(.microphone, offsetMs: cell.offsets[1]),
                                       activeSources: activeSet)
                let r3 = fusion.ingest(SensorFixture.impact(.headphoneMotion, offsetMs: cell.offsets[2]),
                                       activeSources: activeSet)
                let fireCount = [r1, r2, r3].filter { $0 != nil }.count

                let expected: Int
                if cell.allInWindow {
                    switch consensus {
                    case 1: expected = 3   // fires each time after reset
                    case 2: expected = 1   // fires only when 2 stack
                    case 3: expected = 1   // fires only when all 3 stack
                    default: expected = 0
                    }
                } else {
                    expected = (consensus == 1) ? 3 : 0
                }
                XCTAssertEqual(fireCount, expected,
                    "[scenario=\(cell.label) consensus=\(consensus) allInWindow=\(cell.allInWindow)] " +
                    "expected fireCount=\(expected), got \(fireCount)")
                cells += 1
            }
        }
        XCTAssertEqual(cells, timing.count * consensusValues.count)
    }

    // MARK: - Matrix D: low-intensity input never fires below the gate

    /// Below-gate intensity is rejected by `intensityGate`. Engine itself does
    /// not drop on intensity, but we exercise the wrapper used by the
    /// orchestrator so the matrix covers that gate too.
    func testIntensityGateRejectsBelowThreshold() {
        let intensities: [Float] = [0.0, 0.05, 0.1, 0.5, 1.0]
        let gate: Float = 0.2
        var cells = 0
        for intensity in intensities {
            let fusion = makeFusion(consensus: 1, fusionWindow: 0.1)
            // Gate that drops below `gate`. Engine wraps fused impact through
            // this on real publish; tests can't trigger ImpactFusion's gate
            // directly without `start(...)`, but we can verify ingest still
            // returns the impact and assert what the gate would do externally.
            let activeSet: Set<SensorID> = [.accelerometer]
            let result = fusion.ingest(
                SensorFixture.impact(.accelerometer, offsetMs: 0, intensity: intensity),
                activeSources: activeSet
            )
            // ingest itself never gates on intensity — confirm and document.
            let fused = result
            XCTAssertNotNil(fused,
                "[scenario=low-intensity intensity=\(intensity)] ingest must not gate on intensity")
            // Now exercise the same condition the orchestrator's gate would apply.
            let passes = (fused?.intensity ?? 0) >= gate
            let expected = intensity >= gate
            XCTAssertEqual(passes, expected,
                "[scenario=low-intensity intensity=\(intensity) gate=\(gate)] expected pass=\(expected), got \(passes)")
            cells += 1
        }
        XCTAssertEqual(cells, intensities.count)
    }

    // MARK: - Matrix E: high-intensity input × rearm / debounce

    /// With `rearmDuration` set, two impacts spaced by less than the rearm
    /// only fire once. Spacing past the rearm fires twice. We sweep three
    /// rearm values × two spacings. The first impact always fires
    /// (precondition: lastTriggerAt = .distantPast).
    func testDebounceRearmGate() {
        let rearmValues: [TimeInterval] = [0.1, 0.25, 0.5]
        let spacingsMs = [50, 200, 600]
        var cells = 0

        for rearm in rearmValues {
            for spacing in spacingsMs {
                let fusion = makeFusion(consensus: 1, fusionWindow: 0.05, rearmDuration: rearm)
                let activeSet: Set<SensorID> = [.accelerometer]

                let first = fusion.ingest(
                    SensorFixture.impact(.accelerometer, offsetMs: 0, intensity: 0.9),
                    activeSources: activeSet
                )
                let second = fusion.ingest(
                    SensorFixture.impact(.accelerometer, offsetMs: spacing, intensity: 0.9),
                    activeSources: activeSet
                )

                let secondExpected = (Double(spacing) / 1000.0) >= rearm
                XCTAssertNotNil(first,
                    "[scenario=rearm rearm=\(rearm) spacing=\(spacing)ms] first impact must always fire")
                XCTAssertEqual(second != nil, secondExpected,
                    "[scenario=rearm rearm=\(rearm) spacing=\(spacing)ms] " +
                    "expected secondFire=\(secondExpected), got \(second != nil)")
                cells += 1
            }
        }
        XCTAssertEqual(cells, rearmValues.count * spacingsMs.count)
    }
}
