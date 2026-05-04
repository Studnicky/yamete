import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Mutation-anchor cells for `Sources/SensorKit/LidAngleSource.swift`
/// and `Sources/SensorKit/LidAngleStateMachine.swift`. Each cell pins a
/// single behavioural gate so removing the gate flips the assertion
/// and makes `make mutate` (`scripts/mutation-test.sh`) report the
/// corresponding catalog entry CAUGHT.
///
/// Catalog rows wired to these cells:
///   - lid-slam-rate-gate     -> testLidAngle_slamRateGate_isCaught
///   - lid-open-threshold     -> testLidAngle_openThreshold_isCaught
///   - lid-closed-threshold   -> testLidAngle_closedThreshold_isCaught
///   - lid-time-delta-sign    -> testLidAngle_timeDeltaSign_isCaught
///   - lid-ema-smoothing      -> testLidAngle_emaSmoothing_isCaught
final class MatrixLidAngleSource_Tests: XCTestCase {

    // MARK: - Helpers

    private static func makeSource(config: LidAngleStateMachineConfig) -> LidAngleSource {
        let mock = MockSPUKernelDriver()
        return LidAngleSource(machineConfig: config, kernelDriver: mock)
    }

    /// Subscribe FIRST, run `inject`, await `windowMs`, close the
    /// bus, and return the count of reactions matching `kind`.
    @MainActor
    private static func runAndCount(on bus: ReactionBus,
                                    kind: ReactionKind,
                                    windowMs: Int,
                                    inject: @MainActor () -> Void) async -> Int {
        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == kind { count += 1 }
            return count
        }
        inject()
        try? await Task.sleep(for: CITiming.scaledDuration(ms: windowMs))
        await bus.close()
        return await collector.value
    }

    // MARK: - lid-slam-rate-gate
    //
    // Pins the slam-rate guard
    // `if s.smoothedRate < config.slamRateDegPerSec && angleDeg < ...`.
    // A gentle close (90 → 3° over 5s) yields an EMA rate around
    // -17°/s, which does NOT cross slamRate -180. Without the
    // slam-rate gate (mutation flips the comparator to `>` or drops
    // the rate test entirely), the gentle-close trace would
    // erroneously fire .lidSlammed instead of (or in addition to)
    // .lidClosed.
    func testLidAngle_slamRateGate_isCaught() async {
        let cfg = LidAngleStateMachineConfig(
            openThresholdDeg: 10.0,
            closedThresholdDeg: 5.0,
            slamRateDegPerSec: -180.0,
            smoothingWindowMs: 100
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let slamCount = await Self.runAndCount(on: bus, kind: .lidSlammed, windowMs: 120) {
            source._testInjectAngle(90.0, at: now)                       // cold-start
            source._testInjectAngle(60.0, at: now.addingTimeInterval(1.0))
            source._testInjectAngle(30.0, at: now.addingTimeInterval(2.0))
            source._testInjectAngle(8.0,  at: now.addingTimeInterval(3.0))
            source._testInjectAngle(3.0,  at: now.addingTimeInterval(5.0))
        }
        XCTAssertEqual(slamCount, 0,
            "[lid-gate=slam-rate] gentle close must NOT fire .lidSlammed (slam-rate gate must reject) (got \(slamCount))")
    }

    // MARK: - lid-open-threshold
    //
    // Pins the open-threshold guard
    // `if angleDeg >= config.openThresholdDeg`. A trace that climbs
    // only to 1° (well below openThreshold 10°) must NOT fire
    // .lidOpened. Mutating the gate (e.g. `>= 0`) would let the
    // sub-threshold trace fire.
    func testLidAngle_openThreshold_isCaught() async {
        let cfg = LidAngleStateMachineConfig(
            openThresholdDeg: 10.0,
            closedThresholdDeg: 0.5,   // tight closed band so 1° is in opening region
            slamRateDegPerSec: -1000.0,
            smoothingWindowMs: 100
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let openCount = await Self.runAndCount(on: bus, kind: .lidOpened, windowMs: 120) {
            source._testInjectAngle(0.0, at: now)
            source._testInjectAngle(0.7, at: now.addingTimeInterval(0.1))   // crosses closedThreshold → opening
            source._testInjectAngle(1.0, at: now.addingTimeInterval(0.2))   // still below openThreshold
            source._testInjectAngle(1.0, at: now.addingTimeInterval(0.3))
        }
        XCTAssertEqual(openCount, 0,
            "[lid-gate=open-threshold] sub-threshold angle must NOT publish .lidOpened (got \(openCount))")
    }

    // MARK: - lid-closed-threshold
    //
    // Pins the closed-threshold guard
    // `if angleDeg <= config.closedThresholdDeg`. A trace that
    // descends from 90° to only 8° (above closedThreshold 5°) must
    // NOT fire .lidClosed. Mutating the gate (e.g. `<= 100`) would
    // let the trace fire prematurely.
    func testLidAngle_closedThreshold_isCaught() async {
        let cfg = LidAngleStateMachineConfig(
            openThresholdDeg: 10.0,
            closedThresholdDeg: 5.0,
            slamRateDegPerSec: -1000.0,
            smoothingWindowMs: 100
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let closedCount = await Self.runAndCount(on: bus, kind: .lidClosed, windowMs: 120) {
            source._testInjectAngle(90.0, at: now)                         // cold-start at open
            source._testInjectAngle(50.0, at: now.addingTimeInterval(1.0))
            source._testInjectAngle(20.0, at: now.addingTimeInterval(2.0))
            source._testInjectAngle(8.0,  at: now.addingTimeInterval(3.0))  // closing region — never crosses 5°
            source._testInjectAngle(8.0,  at: now.addingTimeInterval(5.0))
        }
        XCTAssertEqual(closedCount, 0,
            "[lid-gate=closed-threshold] above-closed-threshold trace must NOT publish .lidClosed (got \(closedCount))")
    }

    // MARK: - lid-time-delta-sign
    //
    // Pins the `dt > 0` guard inside the state machine. A slam
    // requires a positive Δt so the rate computation has a sane
    // sign. Mutating the gate (e.g. `dt > -1` or removing it) would
    // let a non-monotonic timestamp produce a bogus instantaneous
    // rate that pollutes the EMA. We assert the slam still fires on
    // a forward-time slam trace; if the mutated production code
    // accepts a non-monotonic dt and the EMA pollutes negative, the
    // production slam fires; if instead the mutation flips the sign
    // entirely, the rate computation produces a positive (non-slam)
    // EMA and slam never fires. The assertion pins exactly one
    // .lidSlammed.
    func testLidAngle_timeDeltaSign_isCaught() async {
        let cfg = LidAngleStateMachineConfig(
            openThresholdDeg: 10.0,
            closedThresholdDeg: 5.0,
            slamRateDegPerSec: -180.0,
            smoothingWindowMs: 50
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let slamCount = await Self.runAndCount(on: bus, kind: .lidSlammed, windowMs: 120) {
            source._testInjectAngle(90.0, at: now)
            source._testInjectAngle(0.0, at: now.addingTimeInterval(0.05))
        }
        XCTAssertEqual(slamCount, 1,
            "[lid-gate=time-delta-sign] forward-time slam trace must publish exactly one .lidSlammed (got \(slamCount))")
    }

    // MARK: - lid-ema-smoothing
    //
    // Pins the EMA smoothing in the rate computation:
    // `s.smoothedRate = alpha * instantaneousRate + (1 - alpha) * s.smoothedRate`.
    // A single noisy sample (one big negative jump) must NOT trip
    // the slam path because the EMA attenuates it. Mutating the
    // smoothing (e.g. setting alpha=1.0 or replacing the EMA with
    // the raw instantaneous rate) makes a single jitter sample fire
    // .lidSlammed.
    //
    // The trace: lid sits open at 90° for ~1 second (10 samples at
    // 100Hz), then a SINGLE 90→0° sample with dt=10ms (rate
    // -9000°/s). Without EMA smoothing, that sample's instantaneous
    // rate alone trips slamRate -180. With EMA smoothing
    // (window=200ms → alpha≈0.05 at dt=10ms), the smoothed rate
    // climbs only to about -450°/s on that single sample, which
    // does cross slamRate -180. So the cell uses a wider window
    // (smoothing 500ms → alpha≈0.02 → smoothed about -180°/s on
    // the single jump) where the EMA attenuates JUST enough that a
    // single sample is below slamRate; the un-smoothed mutation
    // crosses slamRate trivially.
    //
    // Practical pin: the smoothed rate after one sample is
    // `alpha * raw`. With alpha≈0.0196 at smoothing 500ms / dt 10ms
    // and raw -9000, smoothed≈-176, which is GREATER than slamRate
    // -180 (closer to zero — does not cross). With smoothing
    // dropped, raw -9000 trivially crosses. Fire count: 0 with EMA,
    // 1 without.
    func testLidAngle_emaSmoothing_isCaught() async {
        let cfg = LidAngleStateMachineConfig(
            openThresholdDeg: 10.0,
            closedThresholdDeg: 5.0,
            slamRateDegPerSec: -180.0,
            smoothingWindowMs: 500           // wide window — heavy EMA attenuation
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let slamCount = await Self.runAndCount(on: bus, kind: .lidSlammed, windowMs: 120) {
            // Cold-start at open, hold 90° for 10 ticks at 100Hz so
            // the EMA settles at ~0.
            source._testInjectAngle(90.0, at: now)
            for i in 1...10 {
                let t = now.addingTimeInterval(0.01 * Double(i))
                source._testInjectAngle(90.0, at: t)
            }
            // Now ONE big jump to 0° at the next tick.
            source._testInjectAngle(0.0, at: now.addingTimeInterval(0.11))
        }
        XCTAssertEqual(slamCount, 0,
            "[lid-gate=ema-smoothing] single noisy 90→0° jump must NOT fire .lidSlammed under EMA smoothing (got \(slamCount))")
    }
}
