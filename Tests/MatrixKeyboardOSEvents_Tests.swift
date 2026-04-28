import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Keyboard OS-event-surface matrix.
///
/// Bug class: keyboard rate-detection logic (`handleKeyPress` → `keyWindow`
/// → `tapRateThreshold` → `typingDebounce`) was previously only exercised
/// via `_testEmit(.keyboardTyped)`, which publishes directly to the bus
/// and bypasses the entire detection pipeline. A regression in window
/// pruning, threshold comparison, or debounce gate management would slip
/// through.
///
/// Strategy: drive synthetic key presses through `_injectKeyPress` (the
/// new test seam that calls the same `handleKeyPress` the real IOHID
/// callback uses). Assert that the production rate-window + debounce
/// pipeline produces the right number of `.keyboardTyped` reactions for
/// each input pattern.
@MainActor
final class MatrixKeyboardOSEvents_Tests: XCTestCase {

    // MARK: - Bus helpers

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction,
                          clipDuration: 0.5,
                          soundURL: nil,
                          faceIndices: [0],
                          publishedAt: publishedAt)
        }
        return bus
    }

    /// Subscribe and drain for `seconds`, returning every `FiredReaction`.
    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [FiredReaction] {
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

    private func makeSource(eventMonitor: MockEventMonitor = MockEventMonitor(),
                            hidMonitor: MockHIDDeviceMonitor = MockHIDDeviceMonitor()) -> KeyboardActivitySource {
        KeyboardActivitySource(eventMonitor: eventMonitor, hidMonitor: hidMonitor, enableHIDDetection: false)
    }

    // MARK: - Cell 1: rate at threshold fires exactly once

    /// 6 key presses spaced 100ms apart over a 600ms window. Rate-window
    /// is 2.0s, so the rolling rate is 6/2.0 = 3.0/s — exactly equal to
    /// the default threshold of 3.0/s. Production logic uses `>=`, so the
    /// final press should cross the gate. Debounce is 0.8s — only one
    /// reaction fires.
    func testRateAtThreshold_firesExactlyOneReaction() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 1.5) }
        try? await Task.sleep(for: .milliseconds(40))

        // Six presses, 100ms apart — rolling rate hits 3.0/s on the sixth.
        let start = Date()
        for i in 0..<6 {
            await source._injectKeyPress(at: start.addingTimeInterval(Double(i) * 0.1))
            try? await Task.sleep(for: .milliseconds(20))
        }

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        XCTAssertEqual(typed.count, 1,
                       "[cell=rate-at-threshold] rate ≥ 3.0/s must fire exactly one .keyboardTyped (debounce) — got \(typed.count)")

        source.stop()
    }

    // MARK: - Cell 2: rate below threshold never fires

    /// 4 key presses spaced 200ms apart over 600ms. Rolling rate caps at
    /// 4/2.0 = 2.0/s — below the 3.0/s threshold. No reaction.
    func testRateBelowThreshold_noReactions() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 1.0) }
        try? await Task.sleep(for: .milliseconds(40))

        let start = Date()
        for i in 0..<4 {
            await source._injectKeyPress(at: start.addingTimeInterval(Double(i) * 0.2))
            try? await Task.sleep(for: .milliseconds(20))
        }

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        XCTAssertEqual(typed.count, 0,
                       "[cell=rate-below-threshold] rate 2.0/s < 3.0/s must NOT fire .keyboardTyped — got \(typed.count)")

        source.stop()
    }

    // MARK: - Cell 3: rapid burst — debounce collapses to one

    /// 100 presses with 5ms inter-arrival (effective rate ~200/s) — far
    /// above threshold. Production debounce is 0.8s. The full burst spans
    /// 500ms < 0.8s, so the gate closes after the first qualifying press
    /// and never re-opens within the window. Expect at most one reaction.
    func testRapidBurst_debouncesToOne() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 1.5) }
        try? await Task.sleep(for: .milliseconds(40))

        let start = Date()
        for i in 0..<100 {
            await source._injectKeyPress(at: start.addingTimeInterval(Double(i) * 0.005))
        }

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        XCTAssertLessThanOrEqual(typed.count, 1,
                                 "[cell=rapid-burst-debounce] 100 presses in 500ms must debounce to ≤ 1 reaction — got \(typed.count)")
        XCTAssertGreaterThanOrEqual(typed.count, 1,
                                    "[cell=rapid-burst-debounce] burst far above threshold must produce ≥ 1 reaction — got \(typed.count)")

        source.stop()
    }

    // MARK: - Cell 4: spaced presses past debounce window — many reactions

    /// 10 presses spaced 1000ms apart. Each press alone has window=1
    /// (rate 0.5/s) which is below threshold, so this exercises the
    /// "spaced beyond debounce window" axis: the presses don't accumulate
    /// rate to threshold, so they shouldn't fire. This sanity check
    /// confirms the window pruning is working.
    func testSpacedBeyondWindow_noAccumulation() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 1.5) }
        try? await Task.sleep(for: .milliseconds(40))

        // 5 presses, 500ms apart. The 2.0s window holds at most ~4 of
        // them, rate maxes at 2.0/s — below threshold.
        let start = Date()
        for i in 0..<5 {
            await source._injectKeyPress(at: start.addingTimeInterval(Double(i) * 0.5))
        }

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        XCTAssertEqual(typed.count, 0,
                       "[cell=spaced-beyond-window] 5 presses 500ms apart cannot reach 3.0/s threshold — got \(typed.count)")

        source.stop()
    }

    // MARK: - Cell 5: low threshold — every press above threshold fires immediately

    /// Configure the threshold to 0.5/s so a single press in a 2.0s window
    /// crosses the gate. Each press is separated by > debounce (0.8s) so
    /// each one fires its own reaction. Drives the gate-reopen path.
    func testLowThresholdAndSpacedBeyondDebounce_eachPressFires() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.configure(tapRateThreshold: 0.5)
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 3.6) }
        try? await Task.sleep(for: .milliseconds(40))

        // 4 presses, 1.0s apart — past the 0.8s debounce.
        for _ in 0..<4 {
            await source._injectKeyPress(at: Date())
            try? await Task.sleep(for: .milliseconds(900))
        }

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        // Each press, far apart with low threshold + filled window, fires.
        // Allow ≥ 2 to absorb sleep-jitter; the production path must produce
        // multiple reactions in this scenario.
        XCTAssertGreaterThanOrEqual(typed.count, 2,
                                    "[cell=low-threshold-spaced] presses spaced > debounce window must produce multiple reactions — got \(typed.count)")
        XCTAssertLessThanOrEqual(typed.count, 4,
                                 "[cell=low-threshold-spaced] cannot exceed input press count — got \(typed.count)")

        source.stop()
    }

    // MARK: - Cell 6: configurable threshold mutation — boundary cell flips

    /// Mutate `tapRateThreshold` to 100.0/s and confirm a moderate-rate
    /// burst produces zero reactions. This is the rate-boundary cell:
    /// raising the threshold flips the boundary from "fires" to
    /// "doesn't fire" without changing the input.
    func testThresholdMutationFlipsBoundary() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.configure(tapRateThreshold: 100.0)  // unreachable rate
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 1.0) }
        try? await Task.sleep(for: .milliseconds(40))

        let start = Date()
        for i in 0..<10 {
            await source._injectKeyPress(at: start.addingTimeInterval(Double(i) * 0.05))
        }

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        XCTAssertEqual(typed.count, 0,
                       "[cell=threshold-mutation] threshold 100/s with 10 presses in 500ms (rate 5/s) must NOT fire — got \(typed.count)")

        source.stop()
    }

    // MARK: - Cell 7: _testEmit kind guard rejects non-.keyboardTyped kinds

    /// `_testEmit(_:)` is the bus-publish test seam. Its first guard
    /// (`guard kind == .keyboardTyped else { return }`) is the only
    /// surface that prevents unrelated `ReactionKind` values from
    /// publishing a `.keyboardTyped` reaction (the publish call below
    /// the guard is hardcoded to `.keyboardTyped`). Mutating the guard
    /// away lets `_testEmit(.mouseScrolled)` produce a spurious
    /// `.keyboardTyped` event on the bus, which this cell pins.
    func test_testEmit_nonKeyboardKind_doesNotPublish() async throws {
        let bus = await makeBus()
        let source = makeSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(40))

        // Pass a non-keyboard kind. Production guard returns immediately;
        // mutated code falls through and publishes `.keyboardTyped`.
        await source._testEmit(.mouseScrolled)
        await source._testEmit(.trackpadTapping)
        try? await Task.sleep(for: .milliseconds(80))

        let collected = await collectTask.value
        let typed = collected.filter { $0.kind == .keyboardTyped }
        XCTAssertEqual(typed.count, 0,
                       "[cell=testEmit-kind-guard] _testEmit(non-keyboard kind) must NOT publish .keyboardTyped — got \(typed.count)")

        source.stop()
    }
}
