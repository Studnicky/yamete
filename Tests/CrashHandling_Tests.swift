import XCTest
@preconcurrency import AVFoundation
@testable import SensorKit
@testable import YameteCore

/// Crash-handling / arithmetic-trap audit suite.
///
/// None of the existing test files exercise SIGSEGV / SIGTRAP / SIGABRT
/// paths. This file pins the existing arithmetic / divide-by-zero / NaN
/// guards so that a future mutation that strips a guard surfaces as a
/// `.stale` decode, a `nil` result, a `false` predicate, or an empty
/// result list — not a process crash that takes the whole test runner
/// down with it.
///
/// Each cell:
///   1. Names the operation under test and the trap class it would
///      raise without the guard (overflow / underflow / NaN propagation
///      / divide-by-zero / pointer-dereference / etc.).
///   2. Drives the boundary input through the smallest available test
///      seam (pure static helpers where possible, mock-backed adapters
///      otherwise).
///   3. Asserts the *behavioural* outcome (not just absence of crash) so
///      a mutation that silently returns a wrong value still fails.
///
/// Cells that would require an out-of-process child to fault-inject
/// (e.g. an actual `mach_absolute_time` rollover, a force-unwrap
/// segfault) are documented as degenerate at the bottom of this file
/// with the reason in-line.
final class CrashHandling_Tests: XCTestCase {

    // MARK: - Cell 1 — AccelHardware.evaluateActivity, cold-boot underflow
    //
    // Trap class: integer underflow on `now &- lastTs` when both are
    // zero (cold-boot scenario where `_last_event_timestamp == 0`).
    // Without the `raw > 0` gate or the `now > lastTs` gate, a normal
    // `-` would trap; production uses `&-` *plus* a `now > lastTs` gate
    // so a mutation that drops either guard surfaces as `.stale` (wrap
    // produces enormous delta) or `.unreporting` rather than SIGABRT.

    func test_evaluateActivity_lastTsZero_returnsUnreporting_noTrap() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: 0,
            now: 0,
            timebaseNumer: 1,
            timebaseDenom: 1,
            stalenessNs: 500_000_000
        )
        XCTAssertEqual(decision, .unreporting,
            "[crash-cell=accel-coldboot-zero] raw==0 must return .unreporting (not trap, not .stale)")
    }

    func test_evaluateActivity_nowEqualsLastTs_returnsClockNonMonotonic_noTrap() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: 1_000,
            now: 1_000,
            timebaseNumer: 1,
            timebaseDenom: 1,
            stalenessNs: 500_000_000
        )
        XCTAssertEqual(decision, .clockNonMonotonic,
            "[crash-cell=accel-clock-equal] now==lastTs must return .clockNonMonotonic (not trap on &-)")
    }

    func test_evaluateActivity_nowLessThanLastTs_returnsClockNonMonotonic_noTrap() {
        // The actual "would-trap" boundary if the gate were removed:
        // now < lastTs makes `now &- lastTs` wrap to UInt64.max-ish.
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: 2_000_000_000,
            now: 1_000_000_000,
            timebaseNumer: 1,
            timebaseDenom: 1,
            stalenessNs: 500_000_000
        )
        XCTAssertEqual(decision, .clockNonMonotonic,
            "[crash-cell=accel-clock-backwards] now<lastTs must return .clockNonMonotonic (gate prevents underflow path being interpreted as fresh)")
    }

    // MARK: - Cell 2 — Trackpad evaluateCircle NaN guard
    //
    // Trap class: NaN propagation. `atan2(0, 0)` is defined as 0 on
    // Darwin (per the C99 spec) and `hypot(0, 0)` is 0 — combined with
    // a delta accumulator, a buggy guard could push NaN into
    // `circleAngleAccum` and poison every subsequent comparison
    // (NaN > anything is always false → silent failure).
    //
    // Production code guards with `mag > 2.0`, which is also the gate
    // that prevents `atan2(0, 0)` from ever being consumed. Pin that
    // gate by feeding `dx=0, dy=0` and asserting no `.trackpadCircling`
    // ever fires.

    @MainActor
    func test_evaluateCircle_zeroDelta_doesNotPropagateNaN_noFire() async throws {
        let bus = ReactionBus()
        let source = TrackpadActivitySource(eventMonitor: MockEventMonitor())
        source.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.1, touchingMax: 1.0,
            slidingMin: 0.5, slidingMax: 0.9,
            contactMin: 0.3, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0,
            touchingEnabled: false,
            slidingEnabled: false,
            contactEnabled: false,
            tappingEnabled: false,
            circlingEnabled: true
        )
        source.start(publishingTo: bus)
        defer { source.stop() }

        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var n = 0
            for await _ in stream { n += 1 }
            return n
        }

        // 100 zero-delta samples — magnitude gate (`mag > 2.0`) must
        // reject every one before atan2 / hypot output is consumed.
        for _ in 0..<100 {
            source._injectCircleSample(dx: 0, dy: 0)
        }

        try? await Task.sleep(for: .milliseconds(50))
        await bus.close()
        let count = await collector.value
        XCTAssertEqual(count, 0,
            "[crash-cell=trackpad-circle-zero-delta] zero-delta samples must NOT produce any reaction (mag>2.0 gate prevents NaN/0-mag path); got \(count)")
    }

    // MARK: - Cell 3 — MicrophoneAdapter zero-frame buffer pointer access
    //
    // Trap class: out-of-bounds pointer read. A mutation that drops the
    // `frameLength > 0` guard combined with downstream code that does
    // `channelData[0]` could dereference garbage on a buffer with no
    // backing samples. The production guard short-circuits before any
    // pointer access. Pin it: emit a zero-length buffer and assert the
    // stream yields no impacts and the process keeps running.

    func test_micTap_zeroFrameLength_yieldsNoImpact_noTrap() async throws {
        let mock = MockMicrophoneEngineDriver()
        let permissive = ImpactDetectorConfig(
            spikeThreshold: 0.0001, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: 0,
            intensityFloor: 0.0001, intensityCeiling: 1.0
        )
        let adapter = MicrophoneSource(
            detectorConfig: permissive,
            driverFactory: { mock }
        )

        let stream = adapter.impacts()
        let collector = Task<Int, Error> {
            var n = 0
            for try await _ in stream {
                n += 1
                if n >= 1 { break }
            }
            return n
        }
        try? await Task.sleep(for: .milliseconds(50))

        let format = mock.inputFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else {
            XCTFail("[crash-cell=mic-zero-frame] could not allocate buffer")
            return
        }
        buf.frameLength = 0
        for _ in 0..<10 {
            mock.emit(buffer: buf)
        }

        try? await Task.sleep(for: .milliseconds(60))
        collector.cancel()
        let count = (try? await collector.value) ?? 0
        XCTAssertEqual(count, 0,
            "[crash-cell=mic-zero-frame] zero-frame buffers must yield 0 impacts (frameLength>0 gate); got \(count)")
    }

    // MARK: - Cell 4 — ImpactDetector divide-by-zero on backgroundRMS
    //
    // Trap class: divide-by-zero (Float division returns Inf, not a
    // hardware trap on Darwin, but downstream comparisons against Inf
    // are silently wrong → mutation-undetectable). Production guard:
    //   if backgroundRMS > 0 { let crest = windowPeak / backgroundRMS ... }
    // Pin it: feed zero magnitudes (background EMA stays at the
    // intensityFloor seed) and assert no impact ever fires from a
    // sustained-zero signal.

    func test_impactDetector_zeroMagnitudeStream_noImpact_noTrap() {
        let cfg = ImpactDetectorConfig(
            spikeThreshold: 0.01, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: 0,
            intensityFloor: 0.01, intensityCeiling: 1.0
        )
        let det = ImpactDetector(config: cfg, adapterName: "crash-cell")

        let now = Date()
        for i in 0..<100 {
            let r = det.process(magnitude: 0.0, timestamp: now.addingTimeInterval(Double(i) * 0.01))
            XCTAssertNil(r,
                "[crash-cell=impact-zero-mag] zero magnitude must never yield an impact (spikeThreshold gate); got \(String(describing: r)) at i=\(i)")
        }
    }

    /// Companion to Cell 4: a single huge spike against zero-RMS history.
    /// Without the `backgroundRMS > 0` gate, the crest computation would
    /// return Inf. The gate path skips the crest check when the
    /// background hasn't accumulated energy; the result must be a finite
    /// intensity in [0, 1] (or nil from another gate) — never NaN/Inf.
    func test_impactDetector_spikeAgainstZeroBackground_finiteResult() {
        let cfg = ImpactDetectorConfig(
            spikeThreshold: 0.5, minRiseRate: 0, minCrestFactor: 100.0,
            minConfirmations: 1, warmupSamples: 0,
            intensityFloor: 0.0, intensityCeiling: 1.0
        )
        let det = ImpactDetector(config: cfg, adapterName: "crash-cell")
        let r = det.process(magnitude: 1.0, timestamp: Date())
        if let value = r {
            XCTAssertTrue(value.isFinite,
                "[crash-cell=impact-zero-bg] result must be finite; got \(value)")
            XCTAssertTrue(value >= 0.0 && value <= 1.0,
                "[crash-cell=impact-zero-bg] result must be in [0,1]; got \(value)")
        }
    }

    // MARK: - Cell 5 — HIDDeviceMonitor with 1000 matchers
    //
    // Trap class: integer overflow on iteration counter (degenerate on
    // 64-bit Int) and CFArray bridging cost. The mock implementation
    // iterates `matchers` in a `for` loop; 1000 matchers is well within
    // Int's range but pins that the iteration is safe.

    func test_hidMonitor_thousandMatchers_returnsEmpty_noTrap() {
        let mock = MockHIDDeviceMonitor()
        let matchers: [HIDMatcher] = (0..<1000).map { i in
            let t = "T-\(i)"
            let p = "P-\(i)"
            return HIDMatcher(transport: t, product: p, usagePage: i, usage: i)
        }
        let result = mock.queryDevices(matchers: matchers)
        XCTAssertEqual(result.count, 0,
            "[crash-cell=hid-1000-matchers] empty mock must return [] for any matcher count; got \(result.count)")
        XCTAssertEqual(mock.queryHistory.count, 1,
            "[crash-cell=hid-1000-matchers] queryDevices must record exactly 1 call regardless of matcher count")
        XCTAssertEqual(mock.queryHistory.first?.count, 1000,
            "[crash-cell=hid-1000-matchers] queryHistory must preserve full matcher list")
    }

    // MARK: - Cell 6 — ReactionBus.publish on closed bus
    //
    // Trap class: use-after-finish on `AsyncStream.Continuation`. The
    // documented behaviour of `continuation.yield(_:)` after `finish()`
    // is silent no-op. The bus's `close()` finishes every continuation
    // *and* clears the dictionary, so a subsequent `publish` walks an
    // empty subscriber set — also a silent no-op. Pin it.

    func test_reactionBus_publishAfterClose_silentNoOp() async {
        let bus = ReactionBus()
        let stream = await bus.subscribe()

        let drained = Task { () -> Int in
            var n = 0
            for await _ in stream { n += 1 }
            return n
        }

        await bus.close()
        await bus.publish(.didWake)
        await bus.publish(.willSleep)

        let count = await drained.value
        XCTAssertEqual(count, 0,
            "[crash-cell=bus-publish-after-close] post-close publishes must not deliver; got \(count)")

        let live = await bus._testSubscriberCount()
        XCTAssertEqual(live, 0,
            "[crash-cell=bus-publish-after-close] subscriber dict must be empty after close+publish; got \(live)")
    }

    // MARK: - Cell 7 — UInt64 arithmetic at the wraparound boundary
    //
    // Trap class: integer overflow on `(now &- lastTs) &* numer` when
    // `now` and `lastTs` are at opposite ends of UInt64. Production
    // uses `&-` (wrap) and `&*` (wrap) explicitly, so a mutation that
    // swaps either to `-` / `*` would trap. Drive the wraparound
    // boundary directly via the static helper.
    //
    // Note: there is no UInt64-typed Settings field — the originally
    // proposed "Settings UInt64 overflow" cell is degenerate (see
    // bottom). This cell repurposes the slot to pin the wraparound
    // arithmetic that does exist in `evaluateActivity`.

    func test_evaluateActivity_uint64WraparoundBoundary_noTrap() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: Int.max,
            now: UInt64(Int.max) + 1,
            timebaseNumer: 1,
            timebaseDenom: 1,
            stalenessNs: UInt64.max
        )
        XCTAssertTrue(decision == .reporting || decision == .stale,
            "[crash-cell=accel-uint64-wrap] near-max boundary must return .reporting or .stale (no trap); got \(decision)")
    }

    // MARK: - Cell 8 — evaluateWatchdogTick with extreme staleness
    //
    // Trap class: `Date.timeIntervalSince` on far-future / far-past
    // dates returns a TimeInterval (Double) — not trap-prone. A
    // mutation that converts through Int64 / UInt64 would trap. Pin
    // the Double-domain behaviour at both extremes.

    func test_evaluateWatchdogTick_invalidatedSnapshot_returnsInvalidated_noTrap() {
        let snapshot = (running: false, lastReportAt: Date.distantPast, sampleCounter: 0)
        let decision = AccelHardware.evaluateWatchdogTick(
            snapshot: snapshot,
            now: Date.distantFuture,
            stallThreshold: 5.0
        )
        XCTAssertEqual(decision, .invalidated,
            "[crash-cell=watchdog-distant-times] invalidated snapshot must short-circuit before TimeInterval math (no trap on distant-past/future); got \(decision)")
    }

    func test_evaluateWatchdogTick_distantPastReport_returnsStalled_noTrap() {
        let snapshot = (running: true, lastReportAt: Date.distantPast, sampleCounter: 1)
        let decision = AccelHardware.evaluateWatchdogTick(
            snapshot: snapshot,
            now: Date(),
            stallThreshold: 5.0
        )
        switch decision {
        case .stalled(let s):
            XCTAssertGreaterThan(s, 5.0,
                "[crash-cell=watchdog-distant-past] staleness must exceed threshold; got \(s)")
        default:
            XCTFail("[crash-cell=watchdog-distant-past] expected .stalled, got \(decision)")
        }
    }

    // MARK: - Documented degenerate cells
    //
    // 1. "Settings UInt64 overflow" — degenerate: SettingsStore has no
    //    UInt64-typed fields. All numeric Settings are Double or Int.
    //    The wraparound arithmetic that does exist in the codebase
    //    lives in AccelHardware.evaluateActivity (timebase math) and
    //    is covered by Cell 7. No production code path reads a
    //    UInt64.max-valued Settings field.
    //
    // 2. "AccelerometerReader watchdog mach_absolute_time wraparound"
    //    in-process — degenerate: the production watchdog uses Date
    //    (TimeInterval / Double) for staleness, not mach_absolute_time.
    //    mach_absolute_time rollover is unreachable in-process
    //    (post-Big-Sur the timebase is nanoseconds since boot, ~584
    //    years to wrap). Cell 8 pins the Date-domain behaviour at
    //    distantPast / distantFuture, which is the actual extreme
    //    reachable in this codebase.
    //
    // 3. Out-of-process SIGSEGV / SIGTRAP fault injection — degenerate
    //    in-process: testing that a force-unwrap actually traps
    //    requires XCUIApplication to spawn a child target, which
    //    `swift test` does not configure here. Each cell above pins
    //    the *guard* that prevents the trap; the absence-of-trap
    //    assertion is the test runner not crashing.
}
