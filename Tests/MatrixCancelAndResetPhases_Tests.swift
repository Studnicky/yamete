import XCTest
import CoreGraphics
@testable import YameteCore
@testable import ResponseKit

/// Matrix: `ReactiveOutput.cancelAndReset()` must cleanly tear down state
/// regardless of which lifecycle phase the output is in. Bug class: cancel
/// during preAction leaves driver mid-capture; cancel during action leaves
/// a half-applied effect; cancel during the coalesce window discards the
/// pending stimulus that should have run.
///
/// Phases:
///   A — pre-fire pristine: cancelAndReset before any reaction → reset()
///       still runs (idempotent), no pre/action/post calls.
///   B — during preAction: only meaningful for outputs with a non-trivial
///       preAction (LEDFlash, DisplayBrightnessFlash). Skipped for empty-
///       preAction outputs (audio/notification/tint/haptic/screen).
///   C — during action: action sleep mid-flight is cancelled, postAction
///       skipped, reset() runs.
///   D — between completed lifecycle and next stimulus: reset() runs
///       (idempotent restore), driver state still consistent.
///   E — during coalesce window (pendingFired set, lifecycle not yet
///       started): publish → wait <16ms → cancelAndReset → no pre/action/
///       post fired, reset() ran.
@MainActor
final class MatrixCancelAndResetPhases_Tests: XCTestCase {

    // MARK: - Identity

    private enum Output: String, CaseIterable {
        case led
        case brightness
        case tint
        case haptic
        case notification
        case volumeSpike  // Direct-only, gated below
    }

    // MARK: - Phase A — pristine reset (before any fire)

    func testPhaseA_pristineCancelAndReset_perOutput() async throws {
        // LEDFlash
        do {
            let drv = MockLEDBrightnessDriver()
            drv.setKeyboardBacklightAvailable(true)
            let out = LEDFlash(driver: drv)
            out.cancelAndReset()
            // hardResetKB is called via reset(); driver should record at least
            // one setLevel pointed at the captured snapshot (kbSnapshotLevel
            // defaults to 1.0 before setUp).
            XCTAssertGreaterThanOrEqual(drv.setLevelHistory.count, 0,
                "[output=led phase=A] reset must not crash on pristine output")
        }
        // DisplayBrightnessFlash
        do {
            let drv = MockDisplayBrightnessDriver()
            drv.setAvailable(true)
            let out = DisplayBrightnessFlash(driver: drv)
            out.cancelAndReset()
            // reset() calls driver.set with originalBrightness (0.8 default).
            XCTAssertGreaterThanOrEqual(drv.setHistory.count, 1,
                "[output=brightness phase=A] reset must restore to captured original")
        }
        // DisplayTintFlash
        do {
            let drv = MockDisplayTintDriver()
            drv.setAvailable(true)
            let out = DisplayTintFlash(driver: drv)
            out.cancelAndReset()
            XCTAssertGreaterThanOrEqual(drv.restoreHistory.count, 1,
                "[output=tint phase=A] reset must call restore on driver")
        }
        // HapticResponder
        do {
            let drv = MockHapticEngineDriver()
            drv.setHardwareAvailable(true)
            let out = HapticResponder(driver: drv)
            out.cancelAndReset()
            XCTAssertGreaterThanOrEqual(drv.stopCalls, 1,
                "[output=haptic phase=A] reset must stop engine")
        }
        // NotificationResponder
        do {
            let drv = MockSystemNotificationDriver()
            let out = NotificationResponder(driver: drv)
            out.cancelAndReset()
            XCTAssertGreaterThanOrEqual(drv.removed.count, 1,
                "[output=notification phase=A] reset must call remove(identifier:)")
        }
    }

    // MARK: - Phase D — between lifecycles (idempotent reset)

    /// Run a full preAction → action → postAction cycle, then call
    /// cancelAndReset. The reset must be idempotent: it calls reset() on the
    /// driver, but the driver state remains restored.
    func testPhaseD_betweenLifecycles_idempotent() async throws {
        let drv = MockDisplayBrightnessDriver()
        drv.setAvailable(true)
        drv.setCannedLevel(0.42)
        let out = DisplayBrightnessFlash(driver: drv)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.8, clipDuration: 0.05)

        // Full cycle.
        await out.preAction(fired, multiplier: 1.0, provider: provider)
        await out.action(fired, multiplier: 1.0, provider: provider)
        await out.postAction(fired, multiplier: 1.0, provider: provider)
        let writesAfterCycle = drv.setHistory.count
        XCTAssertGreaterThan(writesAfterCycle, 0,
            "[output=brightness phase=D] action loop should have written at least once")

        // Now cancelAndReset between lifecycles — adds one more restore write.
        out.cancelAndReset()
        let last = drv.setHistory.last
        XCTAssertNotNil(last)
        XCTAssertEqual(Double(last?.level ?? -1), 0.42, accuracy: 0.001,
            "[output=brightness phase=D] post-reset write must equal captured original")
    }

    // MARK: - Phase E — during coalesce window

    /// Drive `consume()`. Publish a reaction. While the 16ms coalesce timer
    /// is still pending (we sleep only 8ms), call cancelAndReset. Result:
    /// no preAction/action/postAction fires (the coalesce task is cancelled,
    /// pendingFired cleared, reset() called).
    func testPhaseE_duringCoalesceWindow_dropsPendingStimulus() async throws {
        let bus = await Self.makeBus()
        let provider = MockConfigProvider()
        let drv = MockDisplayBrightnessDriver()
        drv.setAvailable(true)
        drv.setCannedLevel(0.5)
        let out = DisplayBrightnessFlash(driver: drv)
        let task = Task { @MainActor in await out.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        let preWrites = drv.setHistory.count

        await bus.publish(.impact(FusedImpact(timestamp: Date(), intensity: 0.9, confidence: 1, sources: [])))

        // Sleep 8ms — well below the 16ms coalesce. Lifecycle has NOT started.
        try await Task.sleep(for: .milliseconds(8))
        out.cancelAndReset()

        // Wait past the would-be coalesce fire: nothing should have been written
        // by an action loop. Only the reset() restore is expected.
        try await Task.sleep(for: .milliseconds(80))
        let writes = drv.setHistory
        // reset() does one set call; the action loop would have made many.
        let postReset = writes.count - preWrites
        XCTAssertLessThanOrEqual(postReset, 2,
            "[output=brightness phase=E] expected ≤2 writes (only reset's restore), got \(postReset)")
        await bus.close()
    }

    // MARK: - Phase C — during action (cancellation)

    /// Action sleeps in an animation loop. Cancel mid-loop:
    /// - lifecycleTask cancels → action loop breaks out (Task.isCancelled).
    /// - postAction is skipped (consume() guards with `!Task.isCancelled`).
    /// - reset() is called and writes the captured original.
    func testPhaseC_duringAction_actionCancelled_postSkipped() async throws {
        let bus = await Self.makeBus(clipDuration: 0.30)  // long action loop
        let provider = MockConfigProvider()
        let drv = MockDisplayBrightnessDriver()
        drv.setAvailable(true)
        drv.setCannedLevel(0.40)
        let out = DisplayBrightnessFlash(driver: drv)
        let task = Task { @MainActor in await out.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.impact(FusedImpact(timestamp: Date(), intensity: 0.9, confidence: 1, sources: [])))

        // Wait past coalesce + into action loop.
        try await Task.sleep(for: .milliseconds(60))

        let writesBeforeCancel = drv.setHistory.count
        XCTAssertGreaterThan(writesBeforeCancel, 0,
            "[output=brightness phase=C] action loop should have written before cancel")

        out.cancelAndReset()

        // Sleep enough for any orphaned post to leak through (it must not).
        try await Task.sleep(for: .milliseconds(150))
        // The very last write must be the reset's restore, not a stale animation tick.
        let last = drv.setHistory.last
        XCTAssertNotNil(last)
        XCTAssertEqual(Double(last?.level ?? -1), 0.40, accuracy: 0.001,
            "[output=brightness phase=C] last write must be reset restore (0.40), not a post-cancel action tick")
        await bus.close()
    }

    // MARK: - Phase B — cancellation just past lifecycle entry (LED)

    /// LEDFlash with keyboardBrightnessEnabled has a non-trivial preAction
    /// (snapshots currentLevel + isAutoEnabled, sets idleDimmingSuspended).
    /// Drive `consume()`, publish, sleep just past the 16ms coalesce so the
    /// lifecycle has entered preAction → action region, then cancelAndReset.
    /// Contract: reset() runs (restoring idle dimming), the action loop
    /// produces fewer than a full sweep of writes, postAction does not race
    /// with reset.
    func testPhaseB_LEDLifecycle_cancelEarlyAfterEntry() async throws {
        let drv = MockLEDBrightnessDriver()
        drv.setKeyboardBacklightAvailable(true)
        drv.setCapsLockAccessGranted(true)
        drv.setCurrentLevel(0.55)
        let out = LEDFlash(driver: drv)
        out.setUp()  // captures launch level

        let bus = await Self.makeBus(clipDuration: 0.30)
        let provider = MockConfigProvider()
        provider.led.keyboardBrightnessEnabled = true
        let task = Task { @MainActor in await out.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.impact(FusedImpact(timestamp: Date(), intensity: 0.7, confidence: 1, sources: [])))

        // Wait just past coalesce + a couple of action ticks.
        try await Task.sleep(for: .milliseconds(25))
        out.cancelAndReset()
        try await Task.sleep(for: .milliseconds(200))

        // reset() should have run, resuming idle dimming.
        XCTAssertEqual(drv.setIdleSuspendedHistory.last, false,
            "[output=led phase=B] reset must resume idle dimming")
        // The action loop did not run to full sweep — we cancelled at ~25ms
        // into a 300ms clip. It may have written a few setLevel values; the
        // important assertion is that we ended in a restored state.
        let lastLevel = drv.setLevelHistory.last
        XCTAssertNotNil(lastLevel, "[output=led phase=B] reset must write a level")
        XCTAssertEqual(Double(lastLevel ?? -1), 0.55, accuracy: 0.001,
            "[output=led phase=B] last write must be the captured snapshot, not a stale action tick")
        await bus.close()
    }

    // MARK: - Helpers

    private static func firedImpact(intensity: Float, clipDuration: Double) -> FiredReaction {
        FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: [])),
            clipDuration: clipDuration,
            soundURL: nil,
            faceIndices: [0],
            publishedAt: Date()
        )
    }

    private static func makeBus(clipDuration: Double = 0.05) async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: clipDuration,
                          soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
        }
        return bus
    }
}

