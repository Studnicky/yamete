import XCTest
@testable import YameteCore
@testable import SensorKit

/// Thunderbolt attach/detach matrix.
///
/// Same shape as Bluetooth — IOKit's `IOServiceAddMatchingNotification` for
/// `IOThunderboltPort` emits one event per match/terminate. No time-based
/// debounce. Every event must publish independently.
///
/// `_injectAttach(name:)` and `_injectDetach(name:)` mirror the
/// `kIOFirstMatchNotification` / `kIOTerminatedNotification` callback,
/// bypassing `IORegistryEntryCreateCFProperty` lookups.
@MainActor
final class MatrixThunderboltSourceTests: XCTestCase {

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

    // MARK: - Cell: attach/detach pair both publish

    func testAttachThenDetach_bothPublish() async {
        let bus = await makeBus()
        let source = ThunderboltSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(name: "CalDigit TS4")
        try? await Task.sleep(for: .milliseconds(15))
        await source._injectDetach(name: "CalDigit TS4")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .thunderboltAttached }.count, 1,
            "[scenario=attach-detach-pair] attach must publish once")
        XCTAssertEqual(collected.filter { $0.kind == .thunderboltDetached }.count, 1,
            "[scenario=attach-detach-pair] detach must publish once")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: multiple devices in flight tracked independently

    func testMultipleDevices_eachTrackedIndependently() async {
        let bus = await makeBus()
        let source = ThunderboltSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(name: "CalDigit TS4")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectAttach(name: "OWC Dock")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectAttach(name: "LaCie Drive")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .thunderboltAttached }.count, 3,
            "[scenario=multiple-devices] each distinct attach must publish, got \(collected.filter { $0.kind == .thunderboltAttached }.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: reattach after detach (same device, both publish)

    func testReattachAfterDetach_bothPublish() async {
        let bus = await makeBus()
        let source = ThunderboltSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(name: "CalDigit TS4")
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectDetach(name: "CalDigit TS4")
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectAttach(name: "CalDigit TS4")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .thunderboltAttached }.count, 2,
            "[scenario=reattach] both attaches must publish (no spurious dedup), got \(collected.filter { $0.kind == .thunderboltAttached }.count)")
        XCTAssertEqual(collected.filter { $0.kind == .thunderboltDetached }.count, 1,
            "[scenario=reattach] detach publishes once")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kind threshold — empty name

    func testEmptyName_doesNotCrashAndPublishes() async {
        let bus = await makeBus()
        let source = ThunderboltSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(name: "")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .thunderboltAttached }.count, 1,
            "[scenario=empty-name] empty payload still publishes (no crash, no silent drop)")
        source.stop()
        await bus.close()
    }
}
