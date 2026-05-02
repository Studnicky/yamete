import XCTest
@testable import YameteCore
@testable import SensorKit

/// Sleep / wake matrix.
///
/// Bug class: the `IORegisterForSystemPower` callback handles three message
/// types. If a regression conflates `kIOMessageSystemWillSleep` with
/// `kIOMessageSystemHasPoweredOn`, the wrong reaction fires. If
/// `kIOMessageCanSystemSleep` (which the source intentionally doesn't
/// handle) leaks through, sleep gets a spurious double-fire. The system
/// also occasionally re-broadcasts `HasPoweredOn` without an intervening
/// `WillSleep` — the source must not crash on that.
///
/// `_injectWillSleep(at:)` and `_injectDidWake(at:)` mirror the
/// `kIOMessageSystemWillSleep` and `kIOMessageSystemHasPoweredOn` paths
/// respectively, bypassing the kernel hop and the `IOAllowPowerChange`
/// reply (rootPort is 0 in tests — calling that against a 0 port is
/// undefined).
@MainActor
final class MatrixSleepWakeSourceTests: XCTestCase {

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(
                reaction: reaction,
                clipDuration: 0.5,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: publishedAt
            )
        }
        return bus
    }

    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [FiredReaction] {
        let stream = await bus.subscribe()
        let task = Task {
            var collected: [FiredReaction] = []
            for await fired in stream {
                collected.append(fired)
            }
            return collected
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        return await task.value
    }

    // MARK: - Cell: willSleep then didWake fires both

    func testWillSleepThenDidWake_bothPublish() async {
        let bus = await makeBus()
        let source = SleepWakeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectWillSleep()
        try? await Task.sleep(for: .milliseconds(15))
        await source._injectDidWake()
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .willSleep }.count, 1,
            "[scenario=sleep-wake] willSleep must publish once")
        XCTAssertEqual(collected.filter { $0.kind == .didWake }.count, 1,
            "[scenario=sleep-wake] didWake must publish once")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: repeated didWake without intervening willSleep is benign

    /// System semantic: `kIOMessageSystemHasPoweredOn` may be re-broadcast
    /// (e.g. after a quick lid open/close where the system never fully
    /// slept). The source MUST NOT crash; both wakes should publish.
    func testRepeatedDidWake_doesNotCrashAndBothPublish() async {
        let bus = await makeBus()
        let source = SleepWakeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectDidWake()
        try? await Task.sleep(for: .milliseconds(15))
        await source._injectDidWake()
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .didWake }.count, 2,
            "[scenario=repeated-wake] both wakes must publish (system-tolerant), got \(collected.filter { $0.kind == .didWake }.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: sleep/wake cycle (sleep → wake → sleep → wake)

    func testSleepWakeCycle_publishesEveryStage() async {
        let bus = await makeBus()
        let source = SleepWakeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectWillSleep()
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectDidWake()
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectWillSleep()
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectDidWake()
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .willSleep }.count, 2,
            "[scenario=sleep-wake-cycle] willSleep ×2")
        XCTAssertEqual(collected.filter { $0.kind == .didWake }.count, 2,
            "[scenario=sleep-wake-cycle] didWake ×2")
        source.stop()
        await bus.close()
    }
    // MARK: - Cell: idempotent start — second start() does not double-register
    func testDoubleStart_doesNotDoubleRegister() async {
        let bus = await makeBus()
        let source = SleepWakeSource()
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 1,
            "[scenario=sleepwake-double-start-idempotency] second start must be a no-op; expected installCount=1, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kernel-failure short-circuit — bad connect ⇒ no install
    func testKernelFailure_doesNotInstall() async {
        let bus = await makeBus()
        let source = SleepWakeSource()
        source._forceRegistrationFailure = true
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 0,
            "[scenario=sleepwake-kernel-failure] kernel-success guard must short-circuit; expected installCount=0, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

}
