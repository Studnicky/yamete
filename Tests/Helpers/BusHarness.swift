import Foundation
@testable import YameteCore

/// Wraps a fresh `ReactionBus` with a deterministic enricher for use in
/// integration tests. Holds a strong reference to the bus, exposes
/// helpers to subscribe and to drain the bus for a fixed wall-clock window.
final class BusHarness: @unchecked Sendable {
    let bus: ReactionBus

    init() {
        self.bus = ReactionBus()
    }

    /// Registers a deterministic, synchronous enricher. Must be called once
    /// before any reactions fire.
    func setUp() async {
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(
                reaction: reaction,
                clipDuration: 0.5,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: publishedAt
            )
        }
    }

    func subscribe() async -> AsyncStream<FiredReaction> {
        await bus.subscribe()
    }

    /// Subscribes immediately and drains the bus for `seconds`, returning every
    /// `FiredReaction` that arrives during the window.
    func collectFor(seconds: TimeInterval) async -> [FiredReaction] {
        let stream = await bus.subscribe()
        return await withTaskGroup(of: [FiredReaction].self) { group -> [FiredReaction] in
            group.addTask {
                var collected: [FiredReaction] = []
                for await fired in stream {
                    collected.append(fired)
                }
                return collected
            }
            group.addTask { [bus] in
                try? await Task.sleep(for: .seconds(seconds))
                await bus.close()
                return []
            }
            var all: [FiredReaction] = []
            for await chunk in group {
                all.append(contentsOf: chunk)
            }
            return all
        }
    }

    func close() async {
        await bus.close()
    }

    /// Symmetric teardown for `setUp()`. Closes the bus and yields once so any
    /// in-flight detached `Task { await bus.publish(...) }` spawned by a source
    /// under test gets a chance to drain into the closed-bus no-op path before
    /// the test method returns. Safe to call multiple times — `bus.close()` is
    /// idempotent (finishing already-finished continuations is a no-op, the
    /// subscribers dictionary is cleared on first call).
    func tearDown() async {
        await bus.close()
        await Task.yield()
    }
}
