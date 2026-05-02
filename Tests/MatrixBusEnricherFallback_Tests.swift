import XCTest
@testable import YameteCore

/// Matrix: `ReactionBus.publish` calls the registered enricher with a 0.5s
/// timeout. If the enricher times out, a fallback FiredReaction is built.
/// Bug class: fallback path silently broken (wrong defaults, missing
/// fields), enricher race conditions, subscriber double-deliver under
/// timeout, no delivery at all under timeout.
@MainActor
final class MatrixBusEnricherFallback_Tests: XCTestCase {

    // MARK: - Cell 1: no enricher set → fallback always

    func testNoEnricher_fallbackDelivered_perKind() async throws {
        // Publish a fixed list of kinds; assert each subscriber received one
        // FiredReaction with fallback fields.
        let kinds: [Reaction] = [
            .impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1, sources: [])),
            .acConnected,
            .usbAttached(USBDeviceInfo(name: "x", vendorID: 0, productID: 0)),
            .keyboardTyped,
        ]
        for r in kinds {
            let bus = ReactionBus()
            let stream = await bus.subscribe()
            let collector = Task<[FiredReaction], Never> {
                var got: [FiredReaction] = []
                for await f in stream { got.append(f); if got.count >= 1 { break } }
                return got
            }
            try await Task.sleep(for: .milliseconds(5))
            await bus.publish(r)
            try await Task.sleep(for: .milliseconds(20))
            collector.cancel()
            let collected = await collector.value
            let coords = "[scenario=no-enricher kind=\(r.kind.rawValue)]"
            XCTAssertEqual(collected.count, 1, "\(coords) expected 1 delivery, got \(collected.count)")
            let f = collected[0]
            XCTAssertEqual(f.kind, r.kind, "\(coords) kind mismatch")
            XCTAssertEqual(f.clipDuration, ReactionsConfig.eventResponseDuration, accuracy: 0.001,
                "\(coords) fallback clipDuration must equal eventResponseDuration")
            XCTAssertNil(f.soundURL, "\(coords) fallback soundURL must be nil")
            XCTAssertEqual(f.faceIndices, [0], "\(coords) fallback faceIndices must be [0]")
            await bus.close()
        }
    }

    // MARK: - Cell 2: enricher returns immediately

    func testImmediateEnricher_resultDelivered_perKind() async throws {
        let bus = ReactionBus()
        let url = URL(fileURLWithPath: "/tmp/yamete-test.mp3")
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 1.23,
                          soundURL: url, faceIndices: [7], publishedAt: publishedAt)
        }
        let stream = await bus.subscribe()
        let collector = Task<[FiredReaction], Never> {
            var got: [FiredReaction] = []
            for await f in stream { got.append(f); if got.count >= 1 { break } }
            return got
        }
        try await Task.sleep(for: .milliseconds(5))
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(20))
        collector.cancel()
        let collected = await collector.value
        XCTAssertEqual(collected.count, 1, "[scenario=immediate-enricher] expected 1 delivery")
        XCTAssertEqual(collected.first?.clipDuration ?? -1, 1.23, accuracy: 0.001,
            "[scenario=immediate-enricher] enricher value must propagate")
        XCTAssertEqual(collected.first?.soundURL, url,
            "[scenario=immediate-enricher] enricher soundURL must propagate")
        XCTAssertEqual(collected.first?.faceIndices, [7])
        await bus.close()
    }

    // MARK: - Cell 3: enricher takes 0.4s (under timeout)

    func testEnricher_underTimeout_resultDelivered() async throws {
        let bus = ReactionBus()
        // Production timeout is 500 ms. 200 ms enricher leaves 300 ms of
        // headroom — robust under CI schedulers that can delay an awaiting
        // task by 100+ ms. The 0.4 s value used previously was within 100 ms
        // of the timeout and flaked on slow runners (got fallback's [0]
        // instead of [42]).
        let enricherDelayMs = 200
        await bus.setEnricher { reaction, publishedAt in
            try? await Task.sleep(for: .milliseconds(enricherDelayMs))
            return FiredReaction(reaction: reaction, clipDuration: 9.9,
                                 soundURL: nil, faceIndices: [42], publishedAt: publishedAt)
        }
        let stream = await bus.subscribe()
        let collector = Task<[FiredReaction], Never> {
            var got: [FiredReaction] = []
            for await f in stream { got.append(f); if got.count >= 1 { break } }
            return got
        }
        try await Task.sleep(for: .milliseconds(10))
        let start = Date()
        await bus.publish(.acConnected)
        // Wait at least 2x the enricher latency to give it time to deliver,
        // scaled for slow CI hardware.
        try await Task.sleep(for: CITiming.scaledDuration(ms: enricherDelayMs * 2 + 100))
        collector.cancel()
        let collected = await collector.value
        let coords = "[scenario=enricher-under-timeout]"
        XCTAssertEqual(collected.count, 1, "\(coords) expected 1 delivery")
        XCTAssertEqual(collected.first?.faceIndices, [42],
            "\(coords) enricher value must win when under timeout")
        // Lower bound: publish() must have waited at least ~80% of the
        // enricher latency before returning. Avoids a hardcoded magic
        // number that would need updating with the latency knob.
        XCTAssertGreaterThan(Date().timeIntervalSince(start),
                             Double(enricherDelayMs) / 1000.0 * 0.8,
            "\(coords) publish must wait for enricher (~\(enricherDelayMs)ms)")
        await bus.close()
    }

    // MARK: - Cell 4: enricher takes 0.6s → timeout fallback

    func testEnricher_overTimeout_fallbackDelivered_oneDelivery() async throws {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            try? await Task.sleep(for: .milliseconds(600))
            return FiredReaction(reaction: reaction, clipDuration: 99.0,
                                 soundURL: URL(fileURLWithPath: "/never"),
                                 faceIndices: [99], publishedAt: publishedAt)
        }
        let stream = await bus.subscribe()
        let collector = Task<[FiredReaction], Never> {
            var got: [FiredReaction] = []
            for await f in stream {
                got.append(f)
                if got.count >= 2 { break }
            }
            return got
        }
        try await Task.sleep(for: .milliseconds(5))
        await bus.publish(.acConnected)
        // Wait past the 0.5s timeout, plus 0.1s slack, but BEFORE the 0.6s
        // enricher would have completed (we'd see two deliveries if the bug
        // failed to cancel the late enricher result).
        try await Task.sleep(for: .milliseconds(550))
        // Wait further so a leaking late delivery would show up.
        try await Task.sleep(for: .milliseconds(300))
        collector.cancel()
        let collected = await collector.value
        let coords = "[scenario=enricher-timeout]"
        XCTAssertEqual(collected.count, 1,
            "\(coords) expected 1 delivery, got \(collected.count) — fallback must replace timed-out enricher exactly once")
        // Fallback fields:
        XCTAssertEqual(collected.first?.clipDuration ?? -1, ReactionsConfig.eventResponseDuration, accuracy: 0.001,
            "\(coords) fallback clipDuration mismatch")
        XCTAssertNil(collected.first?.soundURL,
            "\(coords) fallback soundURL must be nil")
        XCTAssertEqual(collected.first?.faceIndices, [0],
            "\(coords) fallback faceIndices must be [0]")
        await bus.close()
    }

    // MARK: - Cell 5: subscribe / unsubscribe / re-subscribe

    /// Two subscribers receive the first reaction; cancel one stream, publish
    /// again — only the surviving subscriber receives the second.
    func testSubscribeUnsubscribe_noZombieDelivery() async throws {
        let bus = ReactionBus()
        await bus.setEnricher { r, t in
            FiredReaction(reaction: r, clipDuration: 0.1, soundURL: nil, faceIndices: [0], publishedAt: t)
        }
        let s1 = await bus.subscribe()
        let s2 = await bus.subscribe()

        let aTask = Task<Int, Never> {
            var n = 0
            for await _ in s1 { n += 1 }
            return n
        }
        let bTask = Task<Int, Never> {
            var n = 0
            for await _ in s2 { n += 1; if n >= 2 { break } }
            return n
        }
        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(50))

        // Cancel subscriber #1.
        aTask.cancel()
        try await Task.sleep(for: .milliseconds(50))

        // Publish again — only subscriber #2 should receive.
        await bus.publish(.acDisconnected)
        try await Task.sleep(for: .milliseconds(50))

        bTask.cancel()
        let aCount = await aTask.value
        let bCount = await bTask.value

        XCTAssertEqual(aCount, 1,
            "[scenario=unsubscribe] subscriber #1 should have received 1 (got \(aCount))")
        XCTAssertEqual(bCount, 2,
            "[scenario=unsubscribe] subscriber #2 should have received 2 (got \(bCount))")
        await bus.close()
    }
}
