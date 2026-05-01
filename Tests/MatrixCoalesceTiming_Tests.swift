import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Coalesce timing matrix:
///   inter-arrival time × actionDuration × stimulus count
///
/// Verifies the 16ms coalesce window in `ReactiveOutput.consume`. The engine
/// stacks multipliers when stimuli land inside the window and a lifecycle is
/// not yet running; once a lifecycle starts, additional stimuli drop until it
/// finishes.
///
/// Runtime budget: each cell sleeps for at most ~250ms. The total number of
/// cells is held under 30 to keep the file under 8s.
@MainActor
final class MatrixCoalesceTiming_Tests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeBus(intensity _: Float = 0.5) async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 0.05,
                          soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
        }
        return bus
    }

    /// Publish, wait the inter-arrival, publish second.
    /// Sleeps `coalesceMs + actionDurationMs + slack` afterwards before reading
    /// `spy.actions`.
    private func runTwoStimulusCell(interArrivalMs: Int, actionDurationMs: Int) async throws -> [SpyCall] {
        let bus = await makeBus()
        let spy = MatrixSpyOutput()
        spy.actionDuration = .milliseconds(actionDurationMs)
        let provider = MockConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        if interArrivalMs > 0 {
            try await Task.sleep(for: .milliseconds(interArrivalMs))
        }
        await bus.publish(.acConnected)

        // Wait long enough for both potential lifecycles to settle. The longest
        // case is 200ms inter-arrival + 16ms coalesce + actionDuration + slack.
        let settleMs = max(200, interArrivalMs) + 16 + actionDurationMs + 80
        try await Task.sleep(for: .milliseconds(settleMs))

        return spy.actions()
    }

    // MARK: - Matrix A: two stimuli, ≤16ms apart → stack into one action

    /// .acConnected intensity=0.4 → multiplier = 1.0 + 0.4*0.5 = 1.2
    func testStackingWithinCoalesceWindow() async throws {
        // Cells safely inside the 16ms coalesce window. Under CI, even 5ms
        // sleeps can drift past the 16ms boundary if the scheduler is loaded;
        // tighten to 0/2ms inter-arrivals so the second publish always lands
        // within the window. Multiple cells still exercise different scheduler
        // points without straddling the boundary.
        struct Cell { let interArrivalMs: Int }
        let cells: [Cell] = [
            .init(interArrivalMs: 0),
            .init(interArrivalMs: 1),
            .init(interArrivalMs: 2),
        ]
        for cell in cells {
            let actions = try await runTwoStimulusCell(
                interArrivalMs: cell.interArrivalMs,
                actionDurationMs: 5
            )
            XCTAssertEqual(actions.count, 1,
                "[interArrival=\(cell.interArrivalMs)ms actionDur=5ms] " +
                "expected actions=1 (coalesced), got \(actions.count)")
            let multiplier = actions.first?.multiplier ?? 0
            XCTAssertEqual(multiplier, 1.2, accuracy: 0.01,
                "[interArrival=\(cell.interArrivalMs)ms] expected multiplier≈1.2, got \(multiplier)")
        }
    }

    // MARK: - Matrix B: two stimuli ≥17ms apart, action long → second drops

    /// Inter-arrival exceeds coalesce window AND second stimulus arrives while
    /// the first lifecycle is still running. Second is dropped (no coalesce
    /// window restart, lifecycle in flight).
    func testSecondStimulusDropsWhileLifecycleInFlight() async throws {
        // 17ms is too close to the 16ms boundary for reliable behavior; use
        // 30ms as the smallest "definitely past coalesce" cell.
        struct Cell { let interArrivalMs: Int; let actionDurationMs: Int }
        let cells: [Cell] = [
            .init(interArrivalMs: 30, actionDurationMs: 80),
            .init(interArrivalMs: 50, actionDurationMs: 80),
            .init(interArrivalMs: 100, actionDurationMs: 200),
        ]
        for cell in cells {
            let actions = try await runTwoStimulusCell(
                interArrivalMs: cell.interArrivalMs,
                actionDurationMs: cell.actionDurationMs
            )
            XCTAssertEqual(actions.count, 1,
                "[interArrival=\(cell.interArrivalMs)ms actionDur=\(cell.actionDurationMs)ms] " +
                "second stimulus must drop while first lifecycle in flight, got actions=\(actions.count)")
            let multiplier = actions.first?.multiplier ?? 0
            XCTAssertEqual(multiplier, 1.0, accuracy: 0.01,
                "[interArrival=\(cell.interArrivalMs)ms] " +
                "expected baseline multiplier=1.0 (no stack), got \(multiplier)")
        }
    }

    // MARK: - Matrix C: spaced past lifecycle → both fire independently

    /// Inter-arrival far exceeds coalesce + action duration: both lifecycles
    /// run independently, two actions, both with multiplier=1.0.
    func testIndependentLifecyclesWhenSpacedPastAction() async throws {
        struct Cell { let interArrivalMs: Int; let actionDurationMs: Int }
        let cells: [Cell] = [
            .init(interArrivalMs: 200, actionDurationMs: 10),
            .init(interArrivalMs: 250, actionDurationMs: 20),
        ]
        for cell in cells {
            let actions = try await runTwoStimulusCell(
                interArrivalMs: cell.interArrivalMs,
                actionDurationMs: cell.actionDurationMs
            )
            XCTAssertEqual(actions.count, 2,
                "[interArrival=\(cell.interArrivalMs)ms actionDur=\(cell.actionDurationMs)ms] " +
                "expected 2 independent actions, got \(actions.count)")
            for (i, action) in actions.enumerated() {
                XCTAssertEqual(action.multiplier, 1.0, accuracy: 0.01,
                    "[interArrival=\(cell.interArrivalMs)ms action=\(i)] " +
                    "expected baseline multiplier=1.0, got \(action.multiplier)")
            }
        }
    }

    // MARK: - Matrix D: three stimuli within coalesce window stack twice

    /// Three stimuli at 5ms apart all land within coalesce. First sets
    /// pending, second/third stack. Multiplier formula:
    ///   m₀ = 1.0; m₁ = m₀ + intensity*0.5; m₂ = m₁ + intensity*0.5
    /// .acConnected intensity = 0.4 → 1.0 → 1.2 → 1.4 (capped at 2.0).
    func testThreeStimuliStackTwice() async throws {
        let bus = await makeBus()
        let spy = MatrixSpyOutput()
        spy.actionDuration = .milliseconds(5)
        let provider = MockConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: CITiming.scaledDuration(ms: 10))
        // Spacing of 5ms × 3 publishes = 10ms span; under CI the cumulative
        // sleep can drift to 20-30ms (past the 16ms coalesce window) and
        // produce 2 actions instead of 1. Drop to 1ms spacing so even with
        // 5x scheduler drift the three publishes still land inside coalesce.
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(1))
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(1))
        await bus.publish(.acConnected)
        // Wait for the coalesce timer + action to run, scaled for CI.
        try await Task.sleep(for: CITiming.scaledDuration(ms: 120))
        // Poll until the coalesced action lands (or timeout) — robust against
        // a slow CI scheduler taking longer than the bare 120ms tail.
        _ = await awaitUntil(timeout: 1.0) {
            spy.actions().count >= 1
        }

        let actions = spy.actions()
        XCTAssertEqual(actions.count, 1,
            "[count=3 spacing=1ms] three stimuli within coalesce must coalesce → 1 action, got \(actions.count)")
        let multiplier = actions.first?.multiplier ?? 0
        // 1.0 + 0.4*0.5 + 0.4*0.5 = 1.4 (well below 2.0 cap)
        XCTAssertEqual(multiplier, 1.4, accuracy: 0.01,
            "[count=3 spacing=1ms intensity=0.4] expected multiplier≈1.4, got \(multiplier)")
    }
}
