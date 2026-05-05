import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Behavioural cells for `LidAngleSource`, the direct-publish reaction
/// source over the BMI286 lid hinge channel of the SPU HID device.
///
/// The source subscribes to a private `AppleSPUDevice` broker (built
/// with a `MockSPUKernelDriver`) and decodes synthesised report bytes
/// through `_testInjectAngle` / `_testInjectReport` on its own
/// injection seam. The cells exercise:
///   • Lifecycle: start/stop idempotency, broker refcount returns to
///     0 after stop.
///   • Cold-start suppression: the very first sample after start does
///     NOT publish (launch-time replay protection).
///   • State machine: open/close transitions emit exactly once;
///     hysteresis prevents oscillation.
///   • Slam path: a steep close fires `.lidSlammed` and SUPPRESSES
///     the parallel gentle-close emission.
///   • Hardware presence: `isAvailable` mirrors
///     `AppleSPUDevice.isHardwarePresent`.
final class LidAngleSource_Tests: XCTestCase {

    // MARK: - Helpers

    /// Permissive default config: small open/closed thresholds,
    /// realistic slam rate, brief smoothing window. Used by every
    /// cell that does not need to override.
    static func defaultConfig() -> LidAngleStateMachineConfig {
        LidAngleStateMachineConfig(
            openThresholdDeg: 10.0,
            closedThresholdDeg: 5.0,
            slamRateDegPerSec: -180.0,
            smoothingWindowMs: 100
        )
    }

    static func makeSource(config: LidAngleStateMachineConfig = defaultConfig()) -> (LidAngleSource, MockSPUKernelDriver) {
        let mock = MockSPUKernelDriver()
        let source = LidAngleSource(machineConfig: config, kernelDriver: mock)
        return (source, mock)
    }

    /// Subscribe FIRST, then run `inject`, await `windowMs`, close the
    /// bus, and return the count of lid reactions matching `kind`.
    /// Mirrors the gyro test harness pattern.
    @MainActor
    static func runAndCount(on bus: ReactionBus,
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

    /// Subscribe FIRST, run `inject`, await `windowMs`, close the
    /// bus, and return the kinds of every lid reaction observed in
    /// emission order. Used by cells that need to assert
    /// "no .lidClosed alongside .lidSlammed" across the same trace.
    @MainActor
    static func runAndCollectKinds(on bus: ReactionBus,
                                   windowMs: Int,
                                   inject: @MainActor () -> Void) async -> [ReactionKind] {
        let stream = await bus.subscribe()
        let collector = Task { () -> [ReactionKind] in
            var kinds: [ReactionKind] = []
            for await fired in stream {
                let k = fired.reaction.kind
                if k == .lidOpened || k == .lidClosed || k == .lidSlammed {
                    kinds.append(k)
                }
            }
            return kinds
        }
        inject()
        try? await Task.sleep(for: CITiming.scaledDuration(ms: windowMs))
        await bus.close()
        return await collector.value
    }

    // MARK: - Lifecycle

    func test_lifecycle_startStop_idempotent() async {
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()

        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 1,
            "[lid=lifecycle-start-idempotent] second start must be a no-op (got \(source.broker._testActiveSubscriptionCount()))")

        source.stop()
        source.stop()
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 0,
            "[lid=lifecycle-stop-idempotent] subscription count must drop to 0 after stop (got \(source.broker._testActiveSubscriptionCount()))")

        // Restart cycle works.
        source.start(publishingTo: bus)
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 1,
            "[lid=lifecycle-restart] restart after stop must re-subscribe")
        source.stop()
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 0,
            "[lid=lifecycle-final-stop] final stop must release the subscription")

        await bus.close()
    }

    // MARK: - Cold-start suppression

    func test_initialAngle_doesNotEmit() async {
        // First sample after start must NOT fire. A host that boots
        // with the lid already open at 90° should not surface
        // .lidOpened on the very first report.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let count = await Self.runAndCount(on: bus, kind: .lidOpened, windowMs: 80) {
            source._testInjectAngle(90.0, at: Date())
        }
        XCTAssertEqual(count, 0,
            "[lid=cold-start] first sample must not publish (got \(count) .lidOpened reactions)")
    }

    // MARK: - Open transition

    func test_open_emitsOnce() async {
        // Start with the lid closed. Synthetic trace 0° → 3° → 7° →
        // 15° must emit exactly one .lidOpened.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, kind: .lidOpened, windowMs: 120) {
            source._testInjectAngle(0.0, at: now)                                    // cold-start, no fire
            source._testInjectAngle(3.0, at: now.addingTimeInterval(0.1))            // still closed
            source._testInjectAngle(7.0, at: now.addingTimeInterval(0.2))            // opening
            source._testInjectAngle(15.0, at: now.addingTimeInterval(0.3))           // open — fires
        }
        XCTAssertEqual(count, 1,
            "[lid=open-once] 0→15° trace must emit exactly one .lidOpened (got \(count))")
    }

    // MARK: - Close transition

    func test_closed_emitsOnce() async {
        // Start with the lid open at 90°. Gentle close (90 → 60 → 30
        // → 8 → 3°) over 5s must emit exactly one .lidClosed.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, kind: .lidClosed, windowMs: 120) {
            source._testInjectAngle(90.0, at: now)                                   // cold-start at open
            source._testInjectAngle(60.0, at: now.addingTimeInterval(1.0))           // open → closing region (still > openThreshold here)
            source._testInjectAngle(30.0, at: now.addingTimeInterval(2.0))           // closing
            source._testInjectAngle(8.0, at: now.addingTimeInterval(3.0))            // crossing openThreshold downward
            source._testInjectAngle(3.0, at: now.addingTimeInterval(5.0))            // closed — fires
        }
        XCTAssertEqual(count, 1,
            "[lid=close-once] 90→3° gentle close must emit exactly one .lidClosed (got \(count))")
    }

    // MARK: - Slam path

    func test_slam_emits() async {
        // 90 → 0° within 50ms. EMA Δangle/Δt is approximately
        // -1800°/s, well below slamRate -180°/s; final angle 0° is
        // below closedThreshold 5°. Must emit .lidSlammed.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, kind: .lidSlammed, windowMs: 120) {
            source._testInjectAngle(90.0, at: now)                                   // cold-start
            source._testInjectAngle(0.0, at: now.addingTimeInterval(0.05))           // slam
        }
        XCTAssertEqual(count, 1,
            "[lid=slam-emits] steep 90→0° transition must emit .lidSlammed (got \(count))")
    }

    func test_slam_does_not_double_with_close() async {
        // Same trace as test_slam_emits but assert that NO
        // .lidClosed fires alongside the slam — the slam path takes
        // precedence over the gentle-close path within a single
        // sample.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let kinds = await Self.runAndCollectKinds(on: bus, windowMs: 120) {
            source._testInjectAngle(90.0, at: now)
            source._testInjectAngle(0.0, at: now.addingTimeInterval(0.05))
        }
        XCTAssertEqual(kinds, [.lidSlammed],
            "[lid=slam-suppresses-close] slam must NOT emit a parallel .lidClosed; got \(kinds)")
    }

    // MARK: - Hysteresis

    func test_hysteresis() async {
        // Angle oscillates between 4° and 6° (straddling the
        // closedThreshold 5°). State must remain in opening/closed
        // and produce ≤1 event in ~1 second of oscillation.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let kinds = await Self.runAndCollectKinds(on: bus, windowMs: 200) {
            source._testInjectAngle(0.0, at: now)                                    // cold-start at closed
            // 1s of 100Hz oscillation
            for i in 0..<100 {
                let t = now.addingTimeInterval(0.01 * Double(i + 1))
                let angle = (i % 2 == 0) ? 4.0 : 6.0
                source._testInjectAngle(angle, at: t)
            }
        }
        XCTAssertLessThanOrEqual(kinds.count, 1,
            "[lid=hysteresis] oscillation around closedThreshold must produce ≤1 event (got \(kinds.count): \(kinds))")
    }

    // MARK: - Hardware presence parity

    func test_isAvailable_followsHardwarePresence() {
        let mock = MockSPUKernelDriver()
        let source = LidAngleSource(machineConfig: Self.defaultConfig(), kernelDriver: mock)
        XCTAssertEqual(source.isAvailable, AppleSPUDevice.isHardwarePresent(),
            "[lid=isAvailable-parity] source.isAvailable must mirror AppleSPUDevice.isHardwarePresent")
    }
}
