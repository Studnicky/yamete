import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Bus + outputs under rapid-fire stress matrix.
///
/// Bug class:
///   1) Bus buffer overflow with `bufferingNewest(8)` drops oldest events
///      silently — outputs see fewer events than published.
///   2) Subscriber slot leaks under churn — `bus.subscribe()` followed by
///      stream drop must clean up via `onTermination → removeSubscriber`.
///   3) Coalesce window pathological cases (100 events in 16ms) must
///      collapse to one action with the multiplier capped at 2.0.
@MainActor
final class MatrixBusStressRapidFire_Tests: XCTestCase {

    // MARK: - Helpers

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 0.05,
                          soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
        }
        return bus
    }

    // MARK: - Cell A: 100 events same kind in tight burst → 1 coalesced action, m capped

    /// 100 publishes of `.acConnected` arriving inside the 16ms coalesce
    /// window must produce exactly one action whose multiplier is capped at
    /// 2.0 by `min(2.0, pendingMultiplier + intensity * 0.5)`.
    ///
    /// Round 6 hardening: the fixed `Task.sleep(10ms)` lead before the
    /// burst raced subscriber registration on the slow CI runner — when
    /// `consume()` had not yet subscribed, the entire 100-publish burst
    /// was dropped (0 actions instead of 1). Replace with a poll on
    /// `_testSubscriberCount() > 0` and replace the tail wait with
    /// `awaitUntil` on `spy.actions().count >= 1`.
    func testHundredSameKindCoalescesToOneActionMultiplierCapped() async throws {
        let bus = await makeBus()
        let spy = MatrixSpyOutput()
        spy.actionDuration = .milliseconds(5)
        let provider = MockConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        // Wait until the subscriber is registered before bursting — under
        // CI the consume() subscribe can take >10ms and the old fixed lead
        // let the burst race subscription, dropping all 100 events.
        _ = await awaitUntil(timeout: 1.0) {
            await bus._testSubscriberCount() > 0
        }
        for _ in 0..<100 {
            await bus.publish(.acConnected)
        }
        // Poll until the coalesced action lands (or timeout) — replaces
        // the brittle fixed 120ms tail sleep.
        _ = await awaitUntil(timeout: 2.0) {
            spy.actions().count >= 1
        }

        let actions = spy.actions()
        XCTAssertEqual(actions.count, 1,
            "[scenario=100-same-kind cell=tight-burst] expected 1 coalesced action, got \(actions.count)")
        let multiplier = actions.first?.multiplier ?? 0
        XCTAssertEqual(multiplier, 2.0, accuracy: 0.001,
            "[scenario=100-same-kind cell=multiplier-cap] expected multiplier=2.0 (cap), got \(multiplier)")
    }

    // MARK: - Cell B: 100 events alternating kinds → 1 action, m ≤ 2

    /// Alternate two kinds tightly; first stimulus seeds `pendingFired`,
    /// remainder stack into the same coalesce slot. Should produce one
    /// action of the SEEDED kind with multiplier capped at 2.0.
    func testHundredAlternatingKindsCoalesceToOneAction() async throws {
        let bus = await makeBus()
        let spy = MatrixSpyOutput()
        spy.actionDuration = .milliseconds(5)
        let provider = MockConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        _ = await awaitUntil(timeout: 1.0) {
            await bus._testSubscriberCount() > 0
        }
        let info = USBDeviceInfo(name: "test", vendorID: 1, productID: 1)
        for i in 0..<100 {
            await bus.publish(i % 2 == 0 ? .acConnected : .usbAttached(info))
        }
        _ = await awaitUntil(timeout: 2.0) {
            spy.actions().count >= 1
        }

        let actions = spy.actions()
        XCTAssertEqual(actions.count, 1,
            "[scenario=100-alternating cell=tight-burst] expected 1 coalesced action, got \(actions.count)")
        let multiplier = actions.first?.multiplier ?? 0
        XCTAssertLessThanOrEqual(multiplier, 2.0,
            "[scenario=100-alternating cell=multiplier-cap] expected multiplier ≤ 2.0, got \(multiplier)")
        let seededKind = actions.first?.kind
        XCTAssertEqual(seededKind, .acConnected,
            "[scenario=100-alternating cell=seeded-kind] first stimulus seeded; expected .acConnected, got \(String(describing: seededKind))")
    }

    // MARK: - Cell C: spaced events past lifecycle each get their own action

    /// 8 events spaced 80ms apart with actionDuration=10ms — each one's
    /// lifecycle finishes before the next arrives, so each fires
    /// independently with multiplier=1.0.
    func testSpacedEventsEachGetTheirOwnLifecycle() async throws {
        let bus = await makeBus()
        let spy = MatrixSpyOutput()
        spy.actionDuration = .milliseconds(10)
        let provider = MockConfigProvider()
        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: CITiming.scaledDuration(ms: 10))
        let count = 8
        // Inter-arrival was 80 ms (16 coalesce + 10 action + ~54 ms slack).
        // On a slow CI runner the action+post can stretch to 60+ ms, leaving
        // <20 ms slack; if A's lifecycle is still wrapping when B publishes,
        // B coalesces into A's still-pending slot and we lose a delivery.
        // Scale the inter-arrival on CI so each lifecycle has plenty of room
        // to wind down before the next publish.
        let interArrivalMs = CITiming.scaledMs(80)
        for _ in 0..<count {
            await bus.publish(.acConnected)
            try await Task.sleep(for: .milliseconds(interArrivalMs))
        }
        // Poll until all `count` actions have landed; fall back to a tail
        // sleep if the last lifecycle is still draining.
        _ = await awaitUntil(timeout: 2.0) {
            spy.actions().count >= count
        }

        let actions = spy.actions()
        XCTAssertEqual(actions.count, count,
            "[scenario=spaced count=\(count)] expected each spaced stimulus to fire independently, got \(actions.count)")
        for (i, action) in actions.enumerated() {
            XCTAssertEqual(action.multiplier, 1.0, accuracy: 0.001,
                "[scenario=spaced cell=action-\(i)] expected baseline multiplier=1.0, got \(action.multiplier)")
        }
    }

    // MARK: - Cell D: parallel subscribers each see published events

    /// 4 subscribers all collected from the same bus must each see exactly
    /// the published event (modulo per-subscriber buffer drops). With low
    /// volume (3 events, ~10ms apart), no drops.
    func testMultipleParallelSubscribersEachSeeEvents() async throws {
        let bus = await makeBus()
        let n = 4
        var streams: [AsyncStream<FiredReaction>] = []
        for _ in 0..<n {
            await streams.append(bus.subscribe())
        }

        // Spawn collector tasks per stream.
        let collected = await withTaskGroup(of: Int.self) { group in
            for stream in streams {
                group.addTask {
                    var count = 0
                    for await _ in stream {
                        count += 1
                        if count >= 3 { break }
                    }
                    return count
                }
            }
            // Publish 3 events with small spacing.
            try? await Task.sleep(for: .milliseconds(10))
            for _ in 0..<3 {
                await bus.publish(.acConnected)
                try? await Task.sleep(for: .milliseconds(5))
            }
            var counts: [Int] = []
            for await c in group { counts.append(c) }
            return counts
        }

        XCTAssertEqual(collected.count, n,
            "[scenario=parallel-subscribers cell=count=\(n)] expected \(n) collectors")
        for (i, c) in collected.enumerated() {
            XCTAssertEqual(c, 3,
                "[scenario=parallel-subscribers cell=subscriber-\(i)] each subscriber must receive 3 events, got \(c)")
        }
        await bus.close()
    }

    // MARK: - Cell E: subscriber-leak — subscribe + drop must clean up

    /// 50 subscriptions, each immediately dropped (no consumer). The bus
    /// must clean up via `onTermination` — `_testSubscriberCount()` drops
    /// to 0 after a tick. If the cleanup hook is removed, subscribers
    /// accumulate.
    func testSubscriberCleanupOnDrop() async throws {
        let bus = ReactionBus()
        // Open and immediately drop 50 streams.
        for _ in 0..<50 {
            _ = await bus.subscribe()
            // The stream goes out of scope at end of iteration → onTermination fires.
        }

        // Cleanup is async (Task in onTermination). Allow ample wall-clock for
        // every cleanup task to land.
        var lastCount = -1
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            let count = await bus._testSubscriberCount()
            lastCount = count
            if count == 0 { break }
        }
        XCTAssertEqual(lastCount, 0,
            "[scenario=subscribe-then-drop cell=count=50] expected 0 subscribers after cleanup, got \(lastCount) — onTermination cleanup likely missing")
    }

    // MARK: - Cell F: publish during close → no crash, returns cleanly

    /// Closing the bus while publish is in flight must not crash. The test
    /// fires a publish + close concurrently and asserts both return.
    func testPublishDuringCloseDoesNotCrash() async throws {
        let bus = await makeBus()
        async let p: Void = bus.publish(.acConnected)
        async let c: Void = bus.close()
        _ = await (p, c)
        // If we reached here without a crash/precondition failure, the cell passes.
        let count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 0,
            "[scenario=publish-during-close cell=post-close] expected 0 subscribers post-close, got \(count)")
    }
}
