import XCTest
@testable import SensorKit
@testable import YameteCore

/// Mutation-anchor cells for `Sources/SensorKit/AccelerometerReader.swift`.
/// Each test pins a single behavioural gate so removing the gate flips
/// the assertion and makes `make mutate` report the entry CAUGHT.
///
/// Architectural note: AccelerometerReader has no protocol-shaped DI seam
/// over IOKit (no `AccelerometerKernelDriver`-style abstraction). The
/// gates exercised here are reachable because:
///
///  1. `ReportContext` is `internal`, so cells construct one directly and
///     call `handleReport(report:length:)` with synthesised payloads. This
///     covers every gate inside `handleReport`:
///       - L630 length floor
///       - L646 running guard
///       - L660 decimation
///       - L664 magnitude bounds
///     plus the running guard inside `surfaceStall` (L622).
///
///  2. The watchdog tick-decision (L407) is extracted into the pure
///     helper `AccelHardware.evaluateWatchdogTick(snapshot:now:stallThreshold:)`,
///     which cells can call directly on synthetic snapshots.
///
///  3. The activity-probe gates (L286 dispatchAccel, L297 monotonicity)
///     are extracted into the pure helper
///     `AccelHardware.evaluateActivity(...)` so cells exercise the
///     conditional logic without touching IORegistry.
///
/// Gates that remain DEGENERATE after this pass are documented in
/// `Tests/Mutation/README.md` — they are the IOKit-result fidelity
/// guards (`KERN_SUCCESS`, `kIOReturnSuccess`, `IOIteratorNext != 0`,
/// `maxSize > 0`) whose failure modes can only be driven from a real
/// kernel mock, not from a swift-test process.
final class MatrixAccelerometerReader_Tests: XCTestCase {

    // MARK: - Helpers

    /// Permissive detector config: every detector-internal gate is open
    /// so that the only thing keeping a synthesised report from yielding
    /// is the AccelerometerReader gate under test. `warmupSamples = 0`
    /// removes the detector's own warmup window so a single in-range
    /// sample is enough to surface as an impact.
    private static func permissiveDetectorConfig() -> ImpactDetectorConfig {
        ImpactDetectorConfig(
            spikeThreshold: 0,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 1,
            warmupSamples: 0,
            intensityFloor: 0.0001,
            intensityCeiling: 100.0
        )
    }

    /// Build a `ReportContext` and yield (context, stream) where the stream
    /// is hot — the caller drives reports via `ctx.handleReport(...)` and
    /// drains the stream with a bounded probe.
    private static func makeContext(
        config: ImpactDetectorConfig = permissiveDetectorConfig()
    ) -> (ReportContext, AsyncThrowingStream<SensorImpact, Error>) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let ctx = ReportContext(
            adapterID: SensorID.accelerometer,
            continuation: continuation,
            hpFilter: HighPassFilter(cutoffHz: 1.0, sampleRate: 50.0),
            lpFilter: LowPassFilter(cutoffHz: 25.0, sampleRate: 50.0),
            detector: ImpactDetector(config: config, adapterName: "test")
        )
        return (ctx, stream)
    }

    /// Build a synthesised HID report payload of the requested length.
    /// `magnitudeG` controls the per-axis raw value — bytes 6/10/14 are
    /// `Int32` little-endian and the production decoder divides by
    /// `AccelHardwareConstants.rawScale`. The result is a vector with
    /// magnitude `magnitudeG * sqrt(3)` (because all three axes carry the
    /// same value) which the cell can adjust to land inside or outside
    /// the [magnitudeMin, magnitudeMax] gate.
    private static func makePayload(length: Int, magnitudeG: Float) -> UnsafeMutablePointer<UInt8> {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(length, 1))
        buf.initialize(repeating: 0, count: max(length, 1))
        if length >= 18 {
            // Per-axis raw int32 such that rawAxis / rawScale = magnitudeG.
            let rawAxis = Int32(magnitudeG * AccelHardwareConstants.rawScale)
            withUnsafeBytes(of: rawAxis.littleEndian) { axisBytes in
                let raw = axisBytes.bindMemory(to: UInt8.self).baseAddress!
                for offset in [6, 10, 14] {
                    for j in 0..<4 { buf[offset + j] = raw[j] }
                }
            }
        }
        return buf
    }

    /// Drain up to one impact from the stream within a bounded timeout.
    private static func drainOne(
        _ stream: AsyncThrowingStream<SensorImpact, Error>,
        within: Duration = .milliseconds(80)
    ) async -> Int {
        let probe = Task<Int, Error> {
            var seen = 0
            for try await _ in stream {
                seen += 1
                if seen >= 1 { break }
            }
            return seen
        }
        try? await Task.sleep(for: within)
        probe.cancel()
        return (try? await probe.value) ?? 0
    }

    // MARK: - L630 — length floor gate

    /// `guard length >= minReportLength else { return }` (handleReport).
    /// A short payload (below `minReportLength`) must NOT produce an
    /// impact, even with a permissive detector. Removing the gate would
    /// let the misaligned `loadUnaligned` reads hit garbage memory — the
    /// cell allocates a buffer one byte longer than `length` so the
    /// gate's removal still does not segfault, but it can produce a
    /// downstream sample that the cell's failure substring catches.
    func testHandleReport_shortPayloadBelowMin_yieldsNothing() async throws {
        let (ctx, stream) = Self.makeContext()
        // Allocate enough underlying memory for the worst case (offsets
        // 6/10/14 + 4) so a mutation that drops the length gate does not
        // crash the test process — it must instead PRODUCE a sample,
        // which the assertion below detects.
        let buf = Self.makePayload(length: 18, magnitudeG: 1.0)
        defer { buf.deallocate() }
        // BUT we tell handleReport `length` is below the gate floor.
        let belowFloor = AccelHardwareConstants.minReportLength - 1
        ctx.handleReport(report: buf, length: belowFloor)
        // Drive a second short report to make sure no decimation race
        // produces a sample — both must be rejected by the length gate.
        ctx.handleReport(report: buf, length: belowFloor)

        let count = await Self.drainOne(stream)
        XCTAssertEqual(
            count, 0,
            "[accel-gate=length-floor] short payloads must be rejected by length gate (got \(count))"
        )
    }

    // MARK: - L646 — running guard inside handleReport

    /// `guard s.running else { return nil }` (handleReport). After
    /// `ctx.invalidate()` the report callback must drop every report,
    /// even if the report payload is in-range and the detector is
    /// permissive.
    func testHandleReport_afterInvalidate_yieldsNothing() async throws {
        let (ctx, stream) = Self.makeContext()
        ctx.invalidate()  // simulate teardown phase 1

        let buf = Self.makePayload(length: 24, magnitudeG: 1.0)
        defer { buf.deallocate() }
        // 4 reports to clear decimation; without the running guard,
        // every other one would yield.
        for _ in 0..<4 { ctx.handleReport(report: buf, length: 24) }

        let count = await Self.drainOne(stream)
        XCTAssertEqual(
            count, 0,
            "[accel-gate=handleReport-running] post-invalidate reports must be dropped (got \(count))"
        )
    }

    // MARK: - L660 — decimation gate

    /// `guard s.sampleCounter % decimationFactor == 0 else { return nil }`.
    /// With `decimationFactor = 2`, every other report should yield (in
    /// permissive mode). Removing the gate would yield on every report.
    /// The cell asserts the exact yield count over a fixed input batch.
    func testHandleReport_decimation_yieldsEveryNthReport() async throws {
        let (ctx, stream) = Self.makeContext()
        let buf = Self.makePayload(length: 24, magnitudeG: 1.0)
        defer { buf.deallocate() }

        // Drive 10 reports. With decimationFactor = 2, the production
        // gate yields on counter values where counter % 2 == 0 after
        // increment — i.e., 5 yields over 10 reports. Removing the gate
        // would yield on all 10, doubling the count.
        for _ in 0..<10 { ctx.handleReport(report: buf, length: 24) }

        let probe = Task<Int, Error> {
            var seen = 0
            for try await _ in stream {
                seen += 1
                if seen >= 10 { break }
            }
            return seen
        }
        try? await Task.sleep(for: .milliseconds(80))
        probe.cancel()
        let count = (try? await probe.value) ?? 0

        let factor = AccelHardwareConstants.decimationFactor
        let expected = 10 / factor
        XCTAssertEqual(
            count, expected,
            "[accel-gate=decimation] expected \(expected) yields over 10 reports at decimationFactor=\(factor) (got \(count))"
        )
    }

    // MARK: - L664 — magnitude bounds gate

    /// `guard rawMag > magnitudeMin && rawMag < magnitudeMax`. Synthesise
    /// a payload whose decoded magnitude lands BELOW `magnitudeMin`
    /// (sub-floor) and BATCH it through the decimation factor. No
    /// impacts must yield. Removing the gate would let the floor-crossing
    /// payload reach the detector and emit impacts.
    func testHandleReport_belowMagnitudeMin_yieldsNothing() async throws {
        let (ctx, stream) = Self.makeContext()
        // Per-axis magnitude ε; total vector magnitude = ε·sqrt(3) ≪ 0.3.
        let subFloor: Float = 0.01
        let buf = Self.makePayload(length: 24, magnitudeG: subFloor)
        defer { buf.deallocate() }

        // 10 reports — even after decimation, removing the gate would
        // surface several impacts.
        for _ in 0..<10 { ctx.handleReport(report: buf, length: 24) }

        let count = await Self.drainOne(stream)
        XCTAssertEqual(
            count, 0,
            "[accel-gate=magnitude-bounds] sub-floor magnitudes must be rejected (got \(count))"
        )
    }

    /// Symmetric upper-bound assertion. A super-ceiling payload (raw
    /// magnitude > magnitudeMax) must also be rejected. Removing the
    /// gate would emit on the first decimated report.
    func testHandleReport_aboveMagnitudeMax_yieldsNothing() async throws {
        let (ctx, stream) = Self.makeContext()
        // Per-axis magnitude 10g; total vector magnitude = 10·sqrt(3) ≈ 17g
        // which is far above magnitudeMax = 4g.
        let buf = Self.makePayload(length: 24, magnitudeG: 10.0)
        defer { buf.deallocate() }

        for _ in 0..<10 { ctx.handleReport(report: buf, length: 24) }

        let count = await Self.drainOne(stream)
        XCTAssertEqual(
            count, 0,
            "[accel-gate=magnitude-bounds] super-ceiling magnitudes must be rejected (got \(count))"
        )
    }

    // MARK: - L622 — running guard inside surfaceStall

    /// `guard s.running else { return nil /* already-stalled */ }` inside
    /// `surfaceStall`. After `ctx.invalidate()` (the running flag is
    /// false), `surfaceStall(error)` must NOT surface the error to the
    /// consumer — the running guard short-circuits the continuation
    /// finish. Removing the gate would let `cont.finish(throwing:)` run
    /// on a continuation that the cleanup path otherwise leaves alone,
    /// surfacing a spurious error after the consumer has decided the
    /// stream is done.
    func testSurfaceStall_afterInvalidate_yieldsNothing() async throws {
        let (ctx, stream) = Self.makeContext()
        struct SpuriousError: Error {}

        // Simulate the teardown phase: the cleanup closure invalidates
        // the context BEFORE the watchdog Task is cancelled, so a final
        // surfaceStall could still race in.
        ctx.invalidate()
        XCTAssertFalse(
            ctx.watchdogSnapshot().running,
            "[accel-gate=surfaceStall-running] invalidate must clear running flag"
        )

        // The race-window stall: must be no-oped by the running guard.
        ctx.surfaceStall(SpuriousError())

        // Drain — the stream must NOT surface SpuriousError. We check
        // by treating any error as a failure (the production cleanup
        // path closes the stream cleanly without an error, but here we
        // cancel after a short window because no producer is wired in).
        let probe = Task<Error?, Error> {
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let surfaced = (try? await probe.value) ?? nil
        XCTAssertNil(
            surfaced,
            "[accel-gate=surfaceStall-running] post-invalidate surfaceStall must not surface an error (got \(String(describing: surfaced)))"
        )
    }

    // MARK: - L407 — watchdog tick decision

    /// `guard snapshot.running else { return }` inside the watchdog
    /// poll loop, extracted into the pure helper
    /// `AccelHardware.evaluateWatchdogTick`. An invalidated snapshot must
    /// always decode as `.invalidated`. Removing the gate would skip the
    /// running check and either return `.alive` or `.stalled` based on
    /// the staleness math, leaking watchdog activity into a
    /// post-invalidate state.
    func testWatchdogTick_invalidatedSnapshot_returnsInvalidated() {
        let now = Date()
        let snapshot = (running: false, lastReportAt: now.addingTimeInterval(-30), sampleCounter: 0)
        let decision = AccelHardware.evaluateWatchdogTick(
            snapshot: snapshot,
            now: now,
            stallThreshold: 5.0
        )
        XCTAssertEqual(
            decision, .invalidated,
            "[accel-gate=watchdog-running] invalidated snapshot must short-circuit to .invalidated (got \(decision))"
        )
    }

    /// Companion: a fresh report inside the staleness budget must
    /// decode as `.alive`.
    func testWatchdogTick_freshReport_returnsAlive() {
        let now = Date()
        let snapshot = (running: true, lastReportAt: now.addingTimeInterval(-1.0), sampleCounter: 5)
        let decision = AccelHardware.evaluateWatchdogTick(
            snapshot: snapshot,
            now: now,
            stallThreshold: 5.0
        )
        XCTAssertEqual(decision, .alive)
    }

    /// Companion: a stale report past the threshold must decode as
    /// `.stalled` with the matching staleness.
    func testWatchdogTick_overdueReport_returnsStalled() {
        let now = Date()
        let snapshot = (running: true, lastReportAt: now.addingTimeInterval(-30.0), sampleCounter: 5)
        let decision = AccelHardware.evaluateWatchdogTick(
            snapshot: snapshot,
            now: now,
            stallThreshold: 5.0
        )
        if case .stalled = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected .stalled, got \(decision)")
        }
    }

    // MARK: - L286 — dispatchAccel filter inside isSensorActivelyReporting

    /// `guard dispatchAccel else { continue }`. Extracted into the pure
    /// helper `AccelHardware.evaluateActivity(...)`. A service that
    /// reports `dispatchAccel = false` (the gyro / temperature / hinge
    /// siblings on the SPU bus) must decode as `.skip`. Removing the
    /// gate would treat any SPU service as the accelerometer and surface
    /// `.reporting` whenever the timestamp happens to be fresh.
    func testEvaluateActivity_dispatchAccelFalse_returnsSkip() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: false,
            lastTsRaw: 1_000,
            now: 2_000,
            timebaseNumer: 1, timebaseDenom: 1,
            stalenessNs: 500_000_000
        )
        XCTAssertEqual(
            decision, .skip,
            "[accel-gate=dispatchAccel] non-accel SPU services must be skipped (got \(decision))"
        )
    }

    // MARK: - L297 — monotonic clock guard inside isSensorActivelyReporting

    /// `guard now > lastTs else { return false }`. Extracted into the
    /// pure helper. A non-monotonic snapshot (now ≤ lastTs, e.g. after
    /// a clock reset or under wraparound) must decode as
    /// `.clockNonMonotonic`. Removing the gate would let the
    /// `(now - lastTs)` subtraction underflow on `UInt64`, producing a
    /// huge bogus `deltaNs` and a `.stale` outcome — the caller
    /// (`isSensorActivelyReporting`) would still return false, but the
    /// observable decoded state changes from `.clockNonMonotonic` to
    /// `.stale`, which the cell pins.
    func testEvaluateActivity_clockNotMonotonic_returnsClockNonMonotonic() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: 1_000_000,
            now: 999_999,                // strictly less than lastTs
            timebaseNumer: 1, timebaseDenom: 1,
            stalenessNs: 500_000_000
        )
        XCTAssertEqual(
            decision, .clockNonMonotonic,
            "[accel-gate=clock-monotonicity] non-monotonic clock reading must short-circuit (got \(decision))"
        )
    }

    /// Companion: a fresh-and-monotonic snapshot decodes as `.reporting`.
    func testEvaluateActivity_freshMonotonicReading_returnsReporting() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: 1_000,
            now: 1_100,                  // 100ns after lastTs
            timebaseNumer: 1, timebaseDenom: 1,
            stalenessNs: 500_000_000     // 500ms freshness window
        )
        XCTAssertEqual(decision, .reporting)
    }

    /// Companion: a stale snapshot (well outside the freshness window)
    /// decodes as `.stale`.
    func testEvaluateActivity_staleReading_returnsStale() {
        let decision = AccelHardware.evaluateActivity(
            dispatchAccel: true,
            lastTsRaw: 1_000,
            now: 1_000 + 1_000_000_000,  // 1 second later
            timebaseNumer: 1, timebaseDenom: 1,
            stalenessNs: 500_000_000     // 500ms freshness window
        )
        XCTAssertEqual(decision, .stale)
    }
}
