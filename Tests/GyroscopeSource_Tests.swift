import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Behavioural cells for `GyroscopeSource`, the direct-publish reaction
/// source over the BMI286 gyro channel of the SPU HID device.
///
/// The source subscribes to a private `AppleSPUDevice` broker (built
/// with a `MockSPUKernelDriver`) and decodes synthesised report bytes
/// through `_testInjectReport` on its own injection seam. The cells
/// exercise:
///   • Lifecycle: start/stop idempotency, broker refcount returns to 0
///     after stop.
///   • Threshold gating: below-floor magnitudes do not fire; cross-up
///     magnitudes fire exactly once; debounce gates rapid re-fires.
///   • Warmup gating: the initial warmupSamples reports are suppressed
///     unconditionally.
///   • Confirmations gate: under-confirmation windows do not surface.
///   • Hardware presence: `isAvailable` mirrors `AppleSPUDevice.isHardwarePresent`.
final class GyroscopeSource_Tests: XCTestCase {

    // MARK: - Helpers

    /// Synthesise an SPU HID report buffer with the BMI286 gyro layout
    /// (Int32 LE at byte offsets 6/10/14, divided by `rawScale` to yield
    /// deg/s). All three axes carry the same `magnitudeDegSec` value, so
    /// the resulting magnitude is `magnitudeDegSec * sqrt(3)`. Length
    /// defaults to the production minimum (18).
    static func makeGyroPayload(length: Int = AccelHardwareConstants.minReportLength,
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

    /// Permissive detector config: every gate is open so a single
    /// in-range sample produces a publish. Confirmations=1, warmup=0,
    /// rise/crest gates set so a single sample clears them. Used to
    /// reach the threshold + debounce gate cells without needing to
    /// compose a multi-sample window.
    static func permissiveConfig(spikeThreshold: Float = 100.0) -> GyroDetectorConfig {
        GyroDetectorConfig(
            spikeThreshold: spikeThreshold,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 1,
            warmupSamples: 0
        )
    }

    static func makeSource(config: GyroDetectorConfig = permissiveConfig()) -> (GyroscopeSource, MockSPUKernelDriver) {
        let mock = MockSPUKernelDriver()
        let source = GyroscopeSource(detectorConfig: config, kernelDriver: mock)
        return (source, mock)
    }

    // MARK: - Lifecycle

    func test_lifecycle_startStop_idempotent() async {
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()

        // Start twice: only one subscription. Stop twice: still 0.
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 1,
            "[gyroscope=lifecycle-start-idempotent] second start must be a no-op (got \(source.broker._testActiveSubscriptionCount()))")

        source.stop()
        source.stop()
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 0,
            "[gyroscope=lifecycle-stop-idempotent] subscription count must drop to 0 after stop (got \(source.broker._testActiveSubscriptionCount()))")

        // Restart cycle works.
        source.start(publishingTo: bus)
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 1,
            "[gyroscope=lifecycle-restart] restart after stop must re-subscribe")
        source.stop()
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 0,
            "[gyroscope=lifecycle-final-stop] final stop must release the subscription")

        await bus.close()
    }

    // MARK: - Threshold gates

    func test_threshold_belowFloor_doesNotFire() async {
        // Spike threshold 200 deg/s: feed magnitudes that decode to ~50 deg/s.
        let (source, _) = Self.makeSource(config: Self.permissiveConfig(spikeThreshold: 200))
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        // sqrt(3)*30 is approximately 51.9 deg/s, well below 200 floor.
        let buf = Self.makeGyroPayload(magnitudeDegSec: 30)
        defer { buf.deallocate() }

        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == .gyroSpike { count += 1 }
            return count
        }

        for _ in 0..<5 {
            source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())
        }

        // Bounded wait for late publishes, then close and read.
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 80))
        await bus.close()
        let count = await collector.value
        XCTAssertEqual(count, 0,
            "[gyroscope=below-floor] magnitudes below spike threshold must NOT publish .gyroSpike (got \(count))")
    }

    func test_threshold_crossUp_firesOnce() async {
        // Threshold 100 deg/s: payload at sqrt(3)*200 is approximately 346 deg/s, clears it.
        let (source, _) = Self.makeSource(config: Self.permissiveConfig(spikeThreshold: 100))
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makeGyroPayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == .gyroSpike { count += 1 }
            return count
        }

        source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())

        // Wait for the publish to arrive. ReactionBus.publish is async via a
        // detached Task in the source, so we poll on a window large enough
        // for the publish-then-fan-out pipeline to drain.
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 120))
        await bus.close()
        let count = await collector.value
        XCTAssertEqual(count, 1,
            "[gyroscope=cross-up-once] above-threshold magnitude must fire .gyroSpike exactly once (got \(count))")
    }

    func test_threshold_crossDown_repeatedFiresGated() async {
        // Threshold 100 deg/s. Inject several above-threshold reports in a
        // tight burst: debounce (gyroDebounce = 0.5s) caps fire count.
        let (source, _) = Self.makeSource(config: Self.permissiveConfig(spikeThreshold: 100))
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makeGyroPayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == .gyroSpike { count += 1 }
            return count
        }

        // Burst 10 reports back-to-back at the same timestamp.
        let now = Date()
        for _ in 0..<10 {
            source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: now)
        }

        try? await Task.sleep(for: CITiming.scaledDuration(ms: 120))
        await bus.close()
        let count = await collector.value
        XCTAssertEqual(count, 1,
            "[gyroscope=debounce-gate] back-to-back above-threshold reports must coalesce to one fire (got \(count))")
    }

    // MARK: - Warmup gate

    func test_warmup_suppresses_initial() async {
        let cfg = GyroDetectorConfig(
            spikeThreshold: 100,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 1,
            warmupSamples: 5  // first 5 samples are suppressed
        )
        let (source, _) = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makeGyroPayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == .gyroSpike { count += 1 }
            return count
        }

        // Only 4 samples (under warmup=5): none should clear.
        for _ in 0..<4 {
            source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())
        }

        try? await Task.sleep(for: CITiming.scaledDuration(ms: 80))
        await bus.close()
        let count = await collector.value
        XCTAssertEqual(count, 0,
            "[gyroscope=warmup-suppression] samples within warmup window must NOT publish (got \(count))")
    }

    // MARK: - Confirmations gate

    func test_confirmations_gate() async {
        // Confirmations=3 means at least 3 samples in the window must clear
        // the spike threshold. A single above-threshold sample after the
        // detector cold-starts will not satisfy the gate even with warmup=0.
        let cfg = GyroDetectorConfig(
            spikeThreshold: 100,
            minRiseRate: 0,
            minCrestFactor: 0,
            minConfirmations: 3,
            warmupSamples: 0
        )
        let (source, _) = Self.makeSource(config: cfg)
        let bus = ReactionBus()
        source.start(publishingTo: bus)
        defer { source.stop() }

        let buf = Self.makeGyroPayload(magnitudeDegSec: 200)
        defer { buf.deallocate() }

        let stream = await bus.subscribe()
        let collector = Task { () -> Int in
            var count = 0
            for await fired in stream where fired.reaction.kind == .gyroSpike { count += 1 }
            return count
        }

        // One above-threshold sample only: does not satisfy confirmations=3.
        source._testInjectReport(bytes: buf, length: AccelHardwareConstants.minReportLength, timestamp: Date())

        try? await Task.sleep(for: CITiming.scaledDuration(ms: 80))
        await bus.close()
        let count = await collector.value
        XCTAssertEqual(count, 0,
            "[gyroscope=confirmations-gate] under-confirmation single sample must NOT publish (got \(count))")
    }

    // MARK: - Hardware presence parity

    func test_isAvailable_followsHardwarePresence() {
        // The source's isAvailable consults AppleSPUDevice.isHardwarePresent()
        // (with the production default driver), which is the same call the
        // app's UI gates the gyro card on. The contract this cell pins is
        // surface parity: same call, same result, no per-source override.
        let mock = MockSPUKernelDriver()
        let source = GyroscopeSource(detectorConfig: Self.permissiveConfig(), kernelDriver: mock)

        XCTAssertEqual(source.isAvailable, AppleSPUDevice.isHardwarePresent(),
            "[gyroscope=isAvailable-parity] source.isAvailable must mirror AppleSPUDevice.isHardwarePresent")
    }
}
