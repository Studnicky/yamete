import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Mutation-anchor cells for `Sources/SensorKit/AmbientLightSource.swift`
/// and `Sources/SensorKit/AmbientLightDetector.swift`. Each cell pins a
/// single behavioural gate so removing the gate flips the assertion
/// and makes `make mutate` (`scripts/mutation-test.sh`) report the
/// corresponding catalog entry CAUGHT.
///
/// Catalog rows wired to these cells:
///   - als-window-rate-gate         -> testAmbientLight_windowRateGate_isCaught
///   - als-floor-gate               -> testAmbientLight_floorGate_isCaught
///   - als-rise-percent-comparison  -> testAmbientLight_risePercentComparison_isCaught
///   - als-cover-rate-gate          -> testAmbientLight_coverRateGate_isCaught
///   - als-cooldown-gate            -> testAmbientLight_cooldownGate_isCaught
final class MatrixAmbientLightSource_Tests: XCTestCase {

    // MARK: - Helpers

    private static func makeSource(config: AmbientLightDetectorConfig) -> AmbientLightSource {
        let mock = MockSPUKernelDriver()
        return AmbientLightSource(detectorConfig: config, kernelDriver: mock)
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

    // MARK: - als-window-rate-gate
    //
    // Pins the window-elapsed gate
    // `elapsed >= config.windowSec * 0.5` inside the off/on path.
    // Without this gate, slow drift (300lx now, 30lx 5s later) would
    // erroneously fire .lightsOff before the window has accumulated
    // enough samples. The detector also requires a step-down >=
    // offDropPercent — in this trace the percent drop IS large
    // because we let the buffer prune to a tiny single-sample
    // baseline first, but the elapsed gate keeps it from emitting
    // until a full window has passed. Since the test injects samples
    // ONLY at t=0 and t=very-large-time (so the window-pruning leaves
    // an old baseline), removing the elapsed gate would still hold
    // — to make the cell catch the mutation we drive an internal
    // pruning state where the slow-trickle baseline is reachable.
    //
    // Pragmatic pin: the matrix cell verifies that a 30-second slow
    // drift (300 → 30 lx) does NOT fire .lightsOff. The window is
    // 2.0s; samples are spaced > windowSec apart so each new sample
    // sees the previous sample as its trimmed baseline. The elapsed
    // gate `elapsed >= windowSec * 0.5` requires at least 1.0s
    // between baseline and current; samples at t=0 and t=10s satisfy
    // that — but the percent drop gate (90%) blocks fire because
    // each individual step is only ~33% drop. Mutating the elapsed
    // gate alone does not catch this — instead we use a tighter
    // trace: cold-start at 300lx, hold for 0.05s (under windowSec
    // *0.5=1.0s), then drop to 5lx. With the gate present, the
    // emission is blocked because elapsed < 1.0s. With the gate
    // dropped, the emission fires immediately.
    func testAmbientLight_windowRateGate_isCaught() async {
        let cfg = AmbientLightDetectorConfig(
            coverDropThreshold: 0.05,             // very strict cover gate (5% drop)
            offDropPercent: 0.80,
            offFloorLux: 30.0,
            onRisePercent: 1.50,
            onCeilingLux: 100.0,
            windowSec: 2.0,
            debounceSec: 1.0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        // Cold-start, then a SINGLE sample only 50ms later that
        // satisfies the percent drop AND floor BUT is below the
        // window-elapsed threshold. To prevent the cover detector
        // from firing instead, the new lux is set above the cover
        // floor (5.0): 25lx > 5lx makes cover-floor reject, so only
        // the off path is reachable. The window-elapsed gate is the
        // sole barrier between this trace and a .lightsOff emission.
        let offCount = await Self.runAndCount(on: bus, kind: .lightsOff, windowMs: 120) {
            source._testInjectLux(300.0, at: now)
            source._testInjectLux(25.0,  at: now.addingTimeInterval(0.05))   // cover-floor=5 rejects, off-window-elapsed=1.0 also rejects
        }
        XCTAssertEqual(offCount, 0,
            "[als-gate=window-rate] sub-window drop must NOT fire .lightsOff (got \(offCount))")
    }

    // MARK: - als-floor-gate
    //
    // Pins the off-floor gate `lux < config.offFloorLux`. A trace
    // that drops by > offDropPercent over the window but where the
    // new lux is STILL above the floor (e.g. 1000 → 200 lx, 80%
    // drop, but 200 > 30) must NOT fire .lightsOff. Mutating the
    // floor gate (e.g. `lux < 1000` always-true) lets the trace
    // fire prematurely.
    func testAmbientLight_floorGate_isCaught() async {
        let cfg = AmbientLightDetectorConfig(
            coverDropThreshold: 0.05,
            offDropPercent: 0.80,
            offFloorLux: 30.0,
            onRisePercent: 5.0,
            onCeilingLux: 5000.0,
            windowSec: 2.0,
            debounceSec: 1.0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let offCount = await Self.runAndCount(on: bus, kind: .lightsOff, windowMs: 120) {
            source._testInjectLux(1000.0, at: now)
            source._testInjectLux(1000.0, at: now.addingTimeInterval(1.0))
            source._testInjectLux(200.0,  at: now.addingTimeInterval(2.0))   // 80% drop but 200 > floor 30
            source._testInjectLux(200.0,  at: now.addingTimeInterval(2.5))
        }
        XCTAssertEqual(offCount, 0,
            "[als-gate=off-floor] above-floor lux must NOT publish .lightsOff (got \(offCount))")
    }

    // MARK: - als-rise-percent-comparison
    //
    // Pins the rise-percent comparison `rise >= config.onRisePercent`.
    // A trace that rises by exactly the required percent must fire
    // .lightsOn. Mutating the comparison (e.g. flipping `>=` to `<`)
    // makes the same trace never fire.
    func testAmbientLight_risePercentComparison_isCaught() async {
        let cfg = AmbientLightDetectorConfig(
            coverDropThreshold: 0.05,
            offDropPercent: 0.99,
            offFloorLux: 1.0,
            onRisePercent: 1.50,
            onCeilingLux: 100.0,
            windowSec: 2.0,
            debounceSec: 1.0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let onCount = await Self.runAndCount(on: bus, kind: .lightsOn, windowMs: 120) {
            source._testInjectLux(5.0,   at: now)
            source._testInjectLux(5.0,   at: now.addingTimeInterval(1.0))
            source._testInjectLux(500.0, at: now.addingTimeInterval(2.0))    // 100x baseline, well above 1.5
            source._testInjectLux(500.0, at: now.addingTimeInterval(2.5))
        }
        XCTAssertEqual(onCount, 1,
            "[als-gate=rise-percent-comparison] forward step-up must publish exactly one .lightsOn (got \(onCount))")
    }

    // MARK: - als-cover-rate-gate
    //
    // Pins the cover rate gate
    // `timestamp.timeIntervalSince(recent.timestamp) <= 0.2`. A
    // GRADUAL dim (3 seconds from 400 → 1 lx) must NOT fire
    // .alsCovered (it would fire .lightsOff via the window path
    // instead). Mutating the rate gate (e.g. removing the 0.2s cap)
    // lets a slow dim erroneously trip the cover path.
    func testAmbientLight_coverRateGate_isCaught() async {
        let cfg = AmbientLightDetectorConfig(
            coverDropThreshold: 0.95,
            offDropPercent: 0.99,                  // make off path hard to fire
            offFloorLux: 1.0,                      // (also unreachable)
            onRisePercent: 5.0,
            onCeilingLux: 5000.0,
            windowSec: 2.0,
            debounceSec: 1.0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let coverCount = await Self.runAndCount(on: bus, kind: .alsCovered, windowMs: 120) {
            source._testInjectLux(400.0, at: now)
            source._testInjectLux(300.0, at: now.addingTimeInterval(1.0))    // 1s gap exceeds rate cap
            source._testInjectLux(200.0, at: now.addingTimeInterval(2.0))
            source._testInjectLux(100.0, at: now.addingTimeInterval(3.0))
            source._testInjectLux(1.0,   at: now.addingTimeInterval(4.0))    // would-be cover but >0.2s since prior
        }
        XCTAssertEqual(coverCount, 0,
            "[als-gate=cover-rate] gradual dim must NOT fire .alsCovered (got \(coverCount))")
    }

    // MARK: - als-cooldown-gate
    //
    // Pins the cooldown gate that blocks emissions inside
    // `debounceSec` of the last emission. Two rapid covers spaced
    // by 200ms — only the FIRST must fire. Mutating the gate (e.g.
    // dropping the cooldown check) lets the second cover bypass
    // debounce and the cell sees 2 emissions.
    func testAmbientLight_cooldownGate_isCaught() async {
        let cfg = AmbientLightDetectorConfig(
            coverDropThreshold: 0.95,
            offDropPercent: 0.99,
            offFloorLux: 1.0,
            onRisePercent: 5.0,
            onCeilingLux: 5000.0,
            windowSec: 2.0,
            debounceSec: 1.0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let coverCount = await Self.runAndCount(on: bus, kind: .alsCovered, windowMs: 120) {
            source._testInjectLux(400.0, at: now)
            source._testInjectLux(400.0, at: now.addingTimeInterval(0.05))
            source._testInjectLux(1.0,   at: now.addingTimeInterval(0.10))   // 1st cover fires
            source._testInjectLux(400.0, at: now.addingTimeInterval(0.20))   // restored
            source._testInjectLux(400.0, at: now.addingTimeInterval(0.25))
            source._testInjectLux(1.0,   at: now.addingTimeInterval(0.30))   // 2nd cover gated
        }
        XCTAssertEqual(coverCount, 1,
            "[als-gate=cooldown] back-to-back covers within debounce must produce 1 emission (got \(coverCount))")
    }
}
