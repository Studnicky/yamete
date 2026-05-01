import XCTest
@testable import YameteCore
@testable import SensorKit

/// Display hotplug matrix.
///
/// Bug class: macOS's `CGDisplayRegisterReconfigurationCallback` fires 3-4
/// times per real reconfigure (one for each transition stage). Without the
/// 200ms debounce in `dispatchDebounced`, every plug/unplug spams the bus
/// with 3-4 `.displayConfigured` reactions for what the user perceives as
/// a single event.
///
/// `_injectReconfigure(at:)` mirrors the post-`beginConfigurationFlag`
/// path of the production callback, driving `dispatchDebounced` directly.
@MainActor
final class MatrixDisplayHotplugSourceTests: XCTestCase {

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

    // MARK: - Cell: rapid 4 callbacks → debounced to 1

    func testRapidFourCallbacks_debouncedToOne() async {
        let bus = await makeBus()
        let source = DisplayHotplugSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        // Real reconfigures emit ~3-4 callbacks within ~50ms. Production
        // collapses them with the 200ms debounce window.
        //
        // Original test spaced the 4 injections with 20ms `Task.sleep`s.
        // Under CI the scheduler stretches 20ms sleeps past 50ms, so the
        // four callbacks span > 200ms and the debounce window closes
        // mid-burst — producing 2 publishes instead of 1. To keep the
        // test exercising the debounce gate deterministically across
        // hardware, the injections are now back-to-back via `Task.yield`
        // only. The 200ms debounce still catches them all in a single
        // window because there's no real-time gap between them.
        await source._injectReconfigure()
        await Task.yield()
        await source._injectReconfigure()
        await Task.yield()
        await source._injectReconfigure()
        await Task.yield()
        await source._injectReconfigure()
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 250))

        let collected = await collectTask.value
        let configs = collected.filter { $0.kind == .displayConfigured }
        XCTAssertEqual(configs.count, 1,
            "[scenario=rapid-four-callbacks] 200ms debounce must collapse 4 callbacks to 1, got \(configs.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: separated past debounce window → both publish

    func testReconfigsPastDebounceWindow_bothPublish() async {
        let bus = await makeBus()
        let source = DisplayHotplugSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.7) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectReconfigure()
        try? await Task.sleep(for: .milliseconds(250)) // > 200ms debounce
        await source._injectReconfigure()
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let configs = collected.filter { $0.kind == .displayConfigured }
        XCTAssertEqual(configs.count, 2,
            "[scenario=past-debounce] reconfigs separated by >200ms must both publish, got \(configs.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: 2 within window then 1 past → 2 publishes total

    /// Confirms the debounce is a sliding window — once it fires, subsequent
    /// rapid callbacks are gated until the window closes again.
    func testTwoWithinWindowThenOnePast_publishesTwice() async {
        let bus = await makeBus()
        let source = DisplayHotplugSource()
        source.start(publishingTo: bus)

        // CI-scale the collect window so the post-third-inject 200ms tail
        // (also CI-scaled to up to 600ms) lands inside the collect period.
        let collectSeconds: TimeInterval = CITiming.isCI ? 2.5 : 0.9
        let collectTask = Task { await self.collect(from: bus, seconds: collectSeconds) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectReconfigure()      // fires
        try? await Task.sleep(for: .milliseconds(50))
        await source._injectReconfigure()      // gated (within 200ms)
        // The 200ms sliding debounce closes 200ms after the *first* fire.
        // Sleep 300ms (CI-scaled) so the window has definitively closed
        // before the third inject — under CI a 250ms `Task.sleep` can
        // drift to ~280ms which lands inside the still-open window and
        // gates the third inject, producing only 1 publish.
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 300))
        await source._injectReconfigure()      // fires
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 200))

        let collected = await collectTask.value
        let configs = collected.filter { $0.kind == .displayConfigured }
        XCTAssertEqual(configs.count, 2,
            "[scenario=window-expire] sliding 200ms debounce must allow 2 publishes, got \(configs.count)")
        source.stop()
        await bus.close()
    }
    // MARK: - Cell: idempotent start — second start() does not double-register
    func testDoubleStart_doesNotDoubleRegister() async {
        let bus = await makeBus()
        let source = DisplayHotplugSource()
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 1,
            "[scenario=display-double-start-idempotency] second start must be a no-op; expected installCount=1, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

}
