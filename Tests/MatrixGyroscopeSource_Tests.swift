import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Mutation-anchor cells for `Sources/SensorKit/GyroscopeSource.swift`
/// and `Sources/SensorKit/GyroDetector.swift`. Each cell pins a single
/// behavioural gate so removing the gate flips the assertion and makes
/// `make mutate` (`scripts/mutation-test.sh`) report the corresponding
/// catalog entry CAUGHT.
///
/// Catalog rows wired to these cells:
///   - gyro-warmup-gate          -> testGyroSpike_warmup_isCaught
///   - gyro-magnitude-floor      -> testGyroSpike_magnitudeFloor_isCaught
///   - gyro-confirmations-gate   -> testGyroSpike_confirmations_isCaught
///   - gyro-debounce-window      -> testGyroSpike_debounceWindow_isCaught
///   - gyro-decode-byte-offset   -> testGyroSpike_decodeOffset_isCaught
final class MatrixGyroscopeSource_Tests: XCTestCase {

    // MARK: - Helpers (shared with GyroscopeSource_Tests pattern)

    /// Synthesise a BMI286-shaped report buffer with the gyro layout.
    private static func makePayload(length: Int = AccelHardwareConstants.minReportLength,
                                    magnitudeDegSec: Float) -> UnsafeMutablePointer<UInt8> {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(length, 1))
        buf.initialize(repeating: 0, count: max(length, 1))
        if length >= AccelHardwareConstants.minReportLength {
            let raw = Int32(magnitudeDegSec * AccelHardwareConstants.rawScale)
            withUnsafeBytes(of: raw.littleEndian) { axisBytes in
                let p = axisBytes.bindMemory(to: UInt8.self).baseAddress!
                for offset in [6, 10, 14] {
                    for j in 0..<4 { buf[offset + j] = p[j] }
                }
            }
        }
        return buf
    }

    /// Synthesise a BMI286-shaped report buffer with a value ONLY on the
    /// X-axis (offset 6); Y and Z offsets are left as zero. Used by the
    /// `gyro-decode-byte-offset` cell so that mutating the X offset
    /// collapses the decoded magnitude to zero (Y and Z are zero by
    /// construction; if X is decoded from the wrong offset it picks up
    /// zero bytes too, sub-threshold for any positive spike threshold).
    private static func makeXOnlyPayload(magnitudeDegSec: Float) -> UnsafeMutablePointer<UInt8> {
        let length = AccelHardwareConstants.minReportLength
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buf.initialize(repeating: 0, count: length)
        let raw = Int32(magnitudeDegSec * AccelHardwareConstants.rawScale)
        withUnsafeBytes(of: raw.littleEndian) { axisBytes in
            let p = axisBytes.bindMemory(to: UInt8.self).baseAddress!
            for j in 0..<4 { buf[6 + j] = p[j] }
        }
        return buf
    }

    /// Build a source bound to a private broker (mock kernel driver) so
    /// the cell can drive synthetic reports through `_testInjectReport`.
    private static func makeSource(config: GyroDetectorConfig) -> GyroscopeSource {
        let mock = MockSPUKernelDriver()
        return GyroscopeSource(detectorConfig: config, kernelDriver: mock)
    }

    /// Subscribe to the bus FIRST, then run `inject` (the cell's report
    /// injection sequence), wait `windowMs`, close, and return the count
    /// of `.gyroSpike` reactions observed. Subscribing before injection
    /// is critical: source publishes are scheduled via detached Tasks
    /// from the broker callback and would race past a late subscriber.
    private static func runAndCount(on bus: ReactionBus, windowMs: Int, inject: () -> Void) async -> Int {
        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == .gyroSpike { count += 1 }
            return count
        }
        inject()
        try? await Task.sleep(for: CITiming.scaledDuration(ms: windowMs))
        await bus.close()
        return await collector.value
    }

    // MARK: - gyro-warmup-gate
    //
    // Pins `guard s.sampleCount >= config.warmupSamples else { return nil }`
    // (Sources/SensorKit/GyroDetector.swift). With warmupSamples=10, four
    // above-threshold samples must NOT publish — the warmup gate suppresses
    // them. Mutating the gate to always pass would let the threshold-clear
    // samples surface, which the assertion catches.
    func testGyroSpike_warmup_isCaught() async {
        let cfg = GyroDetectorConfig(
            spikeThreshold: 100,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 1,
            warmupSamples: 10
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makePayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let count = await Self.runAndCount(on: bus, windowMs: 80) {
            for _ in 0..<4 {
                source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())
            }
        }
        XCTAssertEqual(count, 0,
            "[gyro-gate=warmup] above-threshold samples within warmup window must NOT publish (got \(count))")
    }

    // MARK: - gyro-magnitude-floor
    //
    // Pins `guard magnitude > config.spikeThreshold else { return nil }`
    // (Sources/SensorKit/GyroDetector.swift). With spikeThreshold=200,
    // payloads decoding to ~52 deg/s must NOT publish. Mutating the gate
    // (e.g., changing `>` to `>= 0`) would let sub-floor magnitudes pass.
    func testGyroSpike_magnitudeFloor_isCaught() async {
        // minConfirmations=0 isolates the spikeThreshold floor (gate 2):
        // gate 5 passes regardless, so the only gate that should reject a
        // sub-threshold magnitude is the floor itself. Mutating the floor
        // (e.g., `>` to `>= 0`) flips this cell from 0 publishes to >=1.
        let cfg = GyroDetectorConfig(
            spikeThreshold: 200,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 0,
            warmupSamples: 0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        // sqrt(3)*30 is approximately 52 deg/s, well below 200.
        let buf = Self.makePayload(magnitudeDegSec: 30)
        defer { buf.deallocate() }
        let count = await Self.runAndCount(on: bus, windowMs: 80) {
            for _ in 0..<5 {
                source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())
            }
        }
        XCTAssertEqual(count, 0,
            "[gyro-gate=magnitude-floor] sub-threshold magnitudes must be rejected by spikeThreshold floor (got \(count))")
    }

    // MARK: - gyro-confirmations-gate
    //
    // Pins `guard confirmed >= config.minConfirmations else { return nil }`.
    // With minConfirmations=5 and only one above-threshold sample, the
    // detector must not surface. Mutating the gate (e.g., setting min=0)
    // would let the single sample fire.
    func testGyroSpike_confirmations_isCaught() async {
        let cfg = GyroDetectorConfig(
            spikeThreshold: 100,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 5,
            warmupSamples: 0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makePayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }
        let count = await Self.runAndCount(on: bus, windowMs: 80) {
            // Only one above-threshold sample.
            source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())
        }
        XCTAssertEqual(count, 0,
            "[gyro-gate=confirmations] under-confirmation single sample must NOT publish (got \(count))")
    }

    // MARK: - gyro-debounce-window
    //
    // Pins the per-source debounce gate inside
    // `GyroscopeSource.handleReport`:
    //   `if let last = s.lastFiredAt, timestamp.timeIntervalSince(last) < gyroDebounce { return nil }`
    // A burst of 10 above-threshold reports at the same timestamp must
    // produce exactly one publish. Mutating the gate (e.g., dropping
    // the `< gyroDebounce` check) would surface every report.
    func testGyroSpike_debounceWindow_isCaught() async {
        let cfg = GyroDetectorConfig(
            spikeThreshold: 100,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 1,
            warmupSamples: 0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makePayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, windowMs: 120) {
            for _ in 0..<10 {
                source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: now)
            }
        }
        XCTAssertEqual(count, 1,
            "[gyro-gate=debounce-window] tight burst must coalesce to a single fire under gyroDebounce (got \(count))")
    }

    // MARK: - gyro-decode-byte-offset
    //
    // Pins the byte offsets of the gyro decoder's `loadUnaligned` reads
    // (offsets 6, 10, 14). The cell synthesises a payload whose magnitude
    // is ABOVE threshold when read from the canonical offsets, but with
    // the OTHER bytes left as zero so a wrong offset reads zero and
    // misses the threshold. Mutating any of the three offsets to (e.g.)
    // 5/9/13 in the production decoder would yield magnitude=0 and the
    // assertion (which expects exactly one publish) would fail.
    func testGyroSpike_decodeOffset_isCaught() async {
        let cfg = GyroDetectorConfig(
            spikeThreshold: 100,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 1,
            warmupSamples: 0
        )
        let source = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        // X-only payload: Y and Z offsets are zero. With the canonical
        // X offset (6) the decoded magnitude is 200 (above threshold).
        // Mutating the X offset to 0 reads zero bytes, magnitude collapses
        // to 0 → no publish, fail.
        let buf = Self.makeXOnlyPayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let count = await Self.runAndCount(on: bus, windowMs: 120) {
            source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())
        }
        XCTAssertEqual(count, 1,
            "[gyro-gate=decode-offset] canonical offsets 6/10/14 must decode the synthesised magnitude above threshold (got \(count))")
    }
}
