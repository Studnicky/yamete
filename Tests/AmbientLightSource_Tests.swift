import XCTest
import os
@testable import SensorKit
@testable import YameteCore

/// Behavioural cells for `AmbientLightSource`, the direct-publish
/// reaction source over the BMI286 ambient-light channel of the SPU
/// HID device.
///
/// The source subscribes to a private `AppleSPUDevice` broker (built
/// with a `MockSPUKernelDriver`) and decodes synthesised report bytes
/// through `_testInjectLux` / `_testInjectReport` on its own injection
/// seam. The cells exercise:
///   • Lifecycle: start/stop idempotency, broker refcount returns to
///     0 after stop.
///   • Cold-start suppression: the very first sample after start does
///     NOT publish (launch-time replay protection).
///   • Step-down: a sharp drop publishes `.lightsOff` exactly once.
///   • Step-up: a sharp rise publishes `.lightsOn` exactly once.
///   • Hand cover: a fast (<200ms) drop with low floor publishes
///     `.alsCovered` (NOT `.lightsOff`).
///   • Slow drift: gradual lux changes outside the window do NOT
///     publish anything.
///   • Cooldown: rapid back-to-back covers are gated by the debounce.
///   • Hardware presence: `isAvailable` mirrors
///     `AppleSPUDevice.isHardwarePresent`.
final class AmbientLightSource_Tests: XCTestCase {

    // MARK: - Helpers

    /// Permissive default config matching `AmbientLightSource.init` defaults.
    static func defaultConfig() -> AmbientLightDetectorConfig {
        AmbientLightDetectorConfig()
    }

    static func makeSource(config: AmbientLightDetectorConfig = defaultConfig()) -> (AmbientLightSource, MockSPUKernelDriver) {
        let mock = MockSPUKernelDriver()
        let source = AmbientLightSource(detectorConfig: config, kernelDriver: mock)
        return (source, mock)
    }

    /// Subscribe FIRST, then run `inject`, await `windowMs`, close the
    /// bus, and return the count of ALS reactions matching `kind`.
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
    /// bus, and return the kinds of every ALS reaction observed in
    /// emission order.
    @MainActor
    static func runAndCollectKinds(on bus: ReactionBus,
                                   windowMs: Int,
                                   inject: @MainActor () -> Void) async -> [ReactionKind] {
        let stream = await bus.subscribe()
        let collector = Task { () -> [ReactionKind] in
            var kinds: [ReactionKind] = []
            for await fired in stream {
                let k = fired.reaction.kind
                if k == .alsCovered || k == .lightsOff || k == .lightsOn {
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
            "[als=lifecycle-start-idempotent] second start must be a no-op (got \(source.broker._testActiveSubscriptionCount()))")

        source.stop()
        source.stop()
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 0,
            "[als=lifecycle-stop-idempotent] subscription count must drop to 0 after stop (got \(source.broker._testActiveSubscriptionCount()))")

        // Restart cycle works.
        source.start(publishingTo: bus)
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 1,
            "[als=lifecycle-restart] restart after stop must re-subscribe")
        source.stop()
        XCTAssertEqual(source.broker._testActiveSubscriptionCount(), 0,
            "[als=lifecycle-final-stop] final stop must release the subscription")

        await bus.close()
    }

    // MARK: - Cold-start suppression

    func test_initialSample_doesNotEmit() async {
        // First sample after start must NOT fire. A host that boots
        // in a brightly-lit room must not surface .lightsOn on the
        // very first report; same for boots in the dark.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let kinds = await Self.runAndCollectKinds(on: bus, windowMs: 80) {
            source._testInjectLux(500.0, at: Date())
        }
        XCTAssertEqual(kinds, [],
            "[als=cold-start] first sample must not publish (got \(kinds))")
    }

    // MARK: - Step-down (lights off)

    func test_stepDown_emits_lightsOff() async {
        // Bright baseline → sharp drop. After cold-start at 300lx,
        // hold for the window, then drop to 5lx. Window passed +
        // drop > 80% + new lux < 30 → exactly one .lightsOff.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, kind: .lightsOff, windowMs: 120) {
            source._testInjectLux(300.0, at: now)                            // cold-start, no fire
            source._testInjectLux(300.0, at: now.addingTimeInterval(0.5))    // baseline
            source._testInjectLux(300.0, at: now.addingTimeInterval(1.5))    // baseline
            source._testInjectLux(5.0,   at: now.addingTimeInterval(3.0))    // drop fires
            source._testInjectLux(5.0,   at: now.addingTimeInterval(3.2))    // within cooldown
            source._testInjectLux(5.0,   at: now.addingTimeInterval(3.4))    // still within cooldown
        }
        XCTAssertEqual(count, 1,
            "[als=step-down] 300→5lx step must emit exactly one .lightsOff (got \(count))")
    }

    // MARK: - Step-up (lights on)

    func test_stepUp_emits_lightsOn() async {
        // Dark baseline → sharp rise. After cold-start at 5lx, hold,
        // then rise to 500lx. Window passed + rise > 150% + new lux
        // > 100 → exactly one .lightsOn.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, kind: .lightsOn, windowMs: 120) {
            source._testInjectLux(5.0,   at: now)
            source._testInjectLux(5.0,   at: now.addingTimeInterval(0.5))
            source._testInjectLux(5.0,   at: now.addingTimeInterval(1.5))
            source._testInjectLux(500.0, at: now.addingTimeInterval(3.0))
            source._testInjectLux(500.0, at: now.addingTimeInterval(3.5))
        }
        XCTAssertEqual(count, 1,
            "[als=step-up] 5→500lx step must emit exactly one .lightsOn (got \(count))")
    }

    // MARK: - Hand cover

    func test_handCover_emits_alsCovered() async {
        // Bright baseline + a rapid hand-pass. Two samples ≤200ms
        // apart, baseline 400lx → 1lx new value. Cover fires (rate
        // gate active) — must NOT also fire .lightsOff because the
        // window has not elapsed.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let kinds = await Self.runAndCollectKinds(on: bus, windowMs: 120) {
            source._testInjectLux(400.0, at: now)
            source._testInjectLux(400.0, at: now.addingTimeInterval(0.05))
            source._testInjectLux(1.0,   at: now.addingTimeInterval(0.10))   // covered fires
            source._testInjectLux(1.0,   at: now.addingTimeInterval(0.12))
        }
        XCTAssertTrue(kinds.contains(.alsCovered),
            "[als=hand-cover] rapid 400→1lx drop must emit .alsCovered (got \(kinds))")
        XCTAssertFalse(kinds.contains(.lightsOff),
            "[als=hand-cover-vs-off] hand cover within window must NOT fire .lightsOff (got \(kinds))")
    }

    // MARK: - Slow drift

    func test_slowDrift_emitsNothing() async {
        // 300 → 200 → 100 → 50 lx over 30 seconds. Each step is
        // beyond the 2s window so the windowed comparators always
        // see a baseline within ~2s of the new sample — and the
        // per-window drop is too small (33–50%) to cross the
        // 80%-drop gate.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let kinds = await Self.runAndCollectKinds(on: bus, windowMs: 120) {
            source._testInjectLux(300.0, at: now)
            source._testInjectLux(200.0, at: now.addingTimeInterval(10.0))
            source._testInjectLux(100.0, at: now.addingTimeInterval(20.0))
            source._testInjectLux(50.0,  at: now.addingTimeInterval(30.0))
        }
        XCTAssertEqual(kinds, [],
            "[als=slow-drift] gradual dim outside window must not publish (got \(kinds))")
    }

    // MARK: - Cooldown

    func test_cooldown_gates_repeats() async {
        // Two cover events within 500ms — only the first must fire.
        let (source, _) = Self.makeSource()
        let bus = ReactionBus()
        await MainActor.run { source.start(publishingTo: bus) }
        defer { source.stop() }

        let now = Date()
        let count = await Self.runAndCount(on: bus, kind: .alsCovered, windowMs: 120) {
            source._testInjectLux(400.0, at: now)
            source._testInjectLux(400.0, at: now.addingTimeInterval(0.05))
            source._testInjectLux(1.0,   at: now.addingTimeInterval(0.10))   // 1st cover fires
            source._testInjectLux(400.0, at: now.addingTimeInterval(0.30))   // restored
            source._testInjectLux(1.0,   at: now.addingTimeInterval(0.50))   // 2nd cover gated by debounce
        }
        XCTAssertEqual(count, 1,
            "[als=cooldown] back-to-back covers within debounce must produce 1 emission (got \(count))")
    }

    // MARK: - Hardware presence parity

    func test_isAvailable_followsHardwarePresence() {
        let mock = MockSPUKernelDriver()
        let source = AmbientLightSource(detectorConfig: Self.defaultConfig(), kernelDriver: mock)
        XCTAssertEqual(source.isAvailable, AppleSPUDevice.isHardwarePresent(),
            "[als=isAvailable-parity] source.isAvailable must mirror AppleSPUDevice.isHardwarePresent")
    }
}
