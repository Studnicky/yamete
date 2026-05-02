import XCTest
@testable import YameteCore

final class ReactionBusTests: XCTestCase {

    func testSingleSubscriberReceivesPublishedReactions() async {
        let bus = ReactionBus()
        let stream = await bus.subscribe()

        await bus.publish(.acConnected)
        await bus.publish(.usbAttached(.init(name: "TestKey", vendorID: 0x1234, productID: 0x5678)))

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.kind, .acConnected)
        XCTAssertEqual(second?.kind, .usbAttached)
    }

    func testMultipleSubscribersAllReceivePublishedReactions() async {
        let bus = ReactionBus()
        let a = await bus.subscribe()
        let b = await bus.subscribe()
        let c = await bus.subscribe()

        await bus.publish(.willSleep)

        var aIter = a.makeAsyncIterator()
        var bIter = b.makeAsyncIterator()
        var cIter = c.makeAsyncIterator()
        let aNext = await aIter.next()
        let bNext = await bIter.next()
        let cNext = await cIter.next()
        XCTAssertEqual(aNext?.kind, .willSleep)
        XCTAssertEqual(bNext?.kind, .willSleep)
        XCTAssertEqual(cNext?.kind, .willSleep)
    }

    func testCloseFinishesAllSubscribers() async {
        let bus = ReactionBus()
        let stream = await bus.subscribe()
        await bus.close()

        var iter = stream.makeAsyncIterator()
        let result = await iter.next()
        XCTAssertNil(result, "Closing the bus must terminate live subscribers.")
    }

    func testBufferingNewestKeepsRecentReactionsForSlowConsumer() async {
        // Publish more than the buffer depth without draining; each subscriber
        // is bufferingNewest(8), so the newest 8 should remain available even
        // though older publishes happened before the consumer started reading.
        let bus = ReactionBus()
        let stream = await bus.subscribe()

        for i in 0..<32 {
            // Alternate event kinds to make order verifiable.
            let kind: Reaction = (i % 2 == 0) ? .acConnected : .acDisconnected
            await bus.publish(kind)
        }

        var iter = stream.makeAsyncIterator()
        var collected: [ReactionKind] = []
        for _ in 0..<ReactionsConfig.busBufferDepth {
            guard let next = await iter.next() else { break }
            collected.append(next.kind)
        }
        XCTAssertEqual(collected.count, ReactionsConfig.busBufferDepth,
                       "Slow consumer should still receive a full buffer of newest reactions.")
    }
}
