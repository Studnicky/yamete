import XCTest
import CoreHaptics
@testable import ResponseKit
@testable import YameteCore

// MARK: - Spy infrastructure

/// Test double for ReactiveOutput — records lifecycle calls and supports
/// configurable action duration so timing-sensitive tests stay deterministic.
@MainActor
private final class SpyOutput: ReactiveOutput {
    // Recorded calls: (FiredReaction, multiplier)
    var preActions:  [(FiredReaction, Float)] = []
    var actions:     [(FiredReaction, Float)] = []
    var postActions: [(FiredReaction, Float)] = []
    var resets = 0

    var fireEnabled = true
    var actionDuration: Duration = .milliseconds(5)

    override func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        fireEnabled
    }
    override func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        preActions.append((fired, multiplier))
    }
    override func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        actions.append((fired, multiplier))
        try? await Task.sleep(for: actionDuration)
    }
    override func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        postActions.append((fired, multiplier))
    }
    override func reset() { resets += 1 }
}

/// Minimal OutputConfigProvider for test use. Returns safe, representative
/// defaults so shouldFire checks in real outputs produce sensible results.
@MainActor
private final class FakeConfigProvider: OutputConfigProvider {
    var displayBrightnessEnabled = true
    var displayBrightnessThreshold: Double = 0.3
    var displayTintEnabled = true
    var volumeSpikeEnabled = true
    var volumeSpikeThreshold: Double = 0.3
    var hapticEnabled = true
    var flashEnabled = true
    var flashPerReaction: [ReactionKind: Bool] = [:]

    func audioConfig() -> AudioOutputConfig {
        AudioOutputConfig(enabled: true, volumeMin: 0.5, volumeMax: 1.0, deviceUIDs: [], perReaction: [:])
    }
    func flashConfig() -> FlashOutputConfig {
        FlashOutputConfig(enabled: flashEnabled, opacityMin: 0.3, opacityMax: 1.0,
                          enabledDisplayIDs: [], perReaction: flashPerReaction, dismissAfter: 3.0)
    }
    func notificationConfig() -> NotificationOutputConfig {
        NotificationOutputConfig(enabled: false, perReaction: [:], dismissAfter: 3.0, localeID: "en")
    }
    func ledConfig() -> LEDOutputConfig {
        LEDOutputConfig(enabled: false, brightnessMin: 0.3, brightnessMax: 1.0,
                        keyboardBrightnessEnabled: false, perReaction: [:])
    }
    func hapticConfig() -> HapticOutputConfig {
        HapticOutputConfig(enabled: hapticEnabled, intensity: 1.0, perReaction: [:])
    }
    func displayBrightnessConfig() -> DisplayBrightnessOutputConfig {
        DisplayBrightnessOutputConfig(enabled: displayBrightnessEnabled, boost: 0.5,
                                       threshold: displayBrightnessThreshold, perReaction: [:])
    }
    func displayTintConfig() -> DisplayTintOutputConfig {
        DisplayTintOutputConfig(enabled: displayTintEnabled, intensity: 0.5, perReaction: [:])
    }
    func volumeSpikeConfig() -> VolumeSpikeOutputConfig {
        VolumeSpikeOutputConfig(enabled: volumeSpikeEnabled, targetVolume: 0.9,
                                threshold: volumeSpikeThreshold, perReaction: [:])
    }
    func trackpadSourceConfig() -> TrackpadSourceConfig {
        TrackpadSourceConfig(windowDuration: 1.5,
                             scrollMin: 0.1, scrollMax: 0.8,
                             contactMin: 0.5, contactMax: 2.5,
                             tapMin: 2.0, tapMax: 6.0)
    }
}

// MARK: - Shared fixtures

private func makeFired(intensity: Float = 0.5, clipDuration: Double = 0.05) -> FiredReaction {
    FiredReaction(
        reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: [])),
        clipDuration: clipDuration,
        soundURL: nil,
        faceIndices: [0],
        publishedAt: Date()
    )
}

/// Builds a bus with a synchronous test enricher that wraps reactions into
/// FiredReaction with the given clip duration. Must be called from MainActor.
@MainActor
private func makeBus(clipDuration: Double = 0.05, intensity: Float = 0.5) async -> ReactionBus {
    let bus = ReactionBus()
    await bus.setEnricher { reaction, publishedAt in
        FiredReaction(reaction: reaction, clipDuration: clipDuration,
                      soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
    }
    return bus
}

// MARK: - ReactiveOutput lifecycle tests

@MainActor
final class ReactiveOutputLifecycleTests: XCTestCase {

    // MARK: - shouldFire gate

    /// Stimuli are dropped when shouldFire returns false — no lifecycle hooks fire.
    func testShouldFireFalseDropsStimulus() async throws {
        let bus = await makeBus()
        let spy = SpyOutput()
        spy.fireEnabled = false
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(spy.preActions.isEmpty)
        XCTAssertTrue(spy.actions.isEmpty)
        XCTAssertTrue(spy.postActions.isEmpty)
    }

    // MARK: - Normal completion sequence

    /// A single stimulus produces pre → action → post in order, multiplier = 1.0.
    func testNormalSequenceFiresAllHooksInOrder() async throws {
        let bus = await makeBus()
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(10)
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        // Wait for coalesce (16ms) + action (10ms) + buffer
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(spy.preActions.count, 1, "preAction must fire once")
        XCTAssertEqual(spy.actions.count,    1, "action must fire once")
        XCTAssertEqual(spy.postActions.count, 1, "postAction must fire once on natural completion")
        XCTAssertEqual(spy.preActions.first?.1 ?? -1, 1.0, accuracy: 0.001, "baseline multiplier is 1.0")
        XCTAssertEqual(spy.actions.first?.1    ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(spy.postActions.first?.1 ?? -1, 1.0, accuracy: 0.001)
    }

    // MARK: - Drop semantics (in-flight takes precedence)

    /// A stimulus that arrives while an action is in flight is dropped;
    /// the running action completes normally including postAction.
    func testDropDuringInFlightPreservesRunningAction() async throws {
        let bus = await makeBus()
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(80)
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)          // A — starts lifecycle after coalesce

        // Wait past coalesce window so lifecycle task is running
        try await Task.sleep(for: .milliseconds(25))
        await bus.publish(.acConnected)          // B — must be dropped (lifecycle active)

        // Wait for A to complete fully
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(spy.actions.count,     1, "B must be dropped while A in flight")
        XCTAssertEqual(spy.postActions.count, 1, "postAction must still fire for A")
    }

    /// A new stimulus IS accepted after the previous action completes.
    func testStimulusAcceptedAfterPreviousCompletes() async throws {
        let bus = await makeBus()
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(20)
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)          // A
        // Wait for A to fully complete (coalesce 16ms + action 20ms + buffer)
        try await Task.sleep(for: .milliseconds(80))
        await bus.publish(.acConnected)          // B — lifecycle is idle, must fire
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(spy.actions.count, 2, "B should be accepted after A finishes")
        XCTAssertEqual(spy.postActions.count, 2)
    }

    // MARK: - cancelAndReset

    /// cancelAndReset calls reset() and skips postAction for the in-flight action.
    func testCancelAndResetCallsResetNotPostAction() async throws {
        let bus = await makeBus()
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(200)  // long enough to cancel mid-flight
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        // Wait past coalesce so lifecycle has started
        try await Task.sleep(for: .milliseconds(30))

        spy.cancelAndReset()

        // Give cancelled task time to unwind
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(spy.resets, 1,             "reset() must be called by cancelAndReset")
        XCTAssertEqual(spy.postActions.count, 0,  "postAction must NOT fire after cancelAndReset")
    }

    // MARK: - Coalesce window / multiplier stacking

    /// Two stimuli published back-to-back (within the 16 ms coalesce window)
    /// produce one action with a multiplier > 1.0.
    func testCoalesceWindowStacksMultiplier() async throws {
        let bus = await makeBus(intensity: 0.5)
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(5)
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))

        // Publish A and B with no delay — both land within the coalesce window.
        await bus.publish(.acConnected)
        await bus.publish(.acConnected)

        // Wait for coalesce (16ms) + action (5ms) + buffer
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(spy.actions.count, 1, "Two simultaneous stimuli should coalesce into one action")
        let m = spy.actions.first?.1 ?? 0
        XCTAssertGreaterThan(m, 1.0, "Multiplier must be stacked above 1.0")
        // .acConnected intensity = 0.4: 1.0 + 0.4 * 0.5 = 1.2
        XCTAssertEqual(m, 1.2, accuracy: 0.01)
    }

    /// Multiplier is threaded through preAction and postAction as well.
    func testMultiplierPropagatedToAllHooks() async throws {
        let bus = await makeBus(intensity: 0.5)
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(5)
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        await bus.publish(.acConnected)
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(spy.preActions.first?.1  ?? 0, 1.2, accuracy: 0.01, "preAction multiplier")
        XCTAssertEqual(spy.actions.first?.1     ?? 0, 1.2, accuracy: 0.01, "action multiplier")
        XCTAssertEqual(spy.postActions.first?.1 ?? 0, 1.2, accuracy: 0.01, "postAction multiplier")
    }

    /// Third stimulus within the window stacks further but caps at 2.0.
    func testMultiplierCappedAtTwo() async throws {
        let bus = await makeBus(intensity: 1.0)
        let spy = SpyOutput()
        spy.actionDuration = .milliseconds(5)
        let provider = FakeConfigProvider()

        let task = Task { await spy.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        // Three intensity=1.0 stimuli: 1.0 + 1.0*0.5 = 1.5, then + 1.0*0.5 = 2.0
        await bus.publish(.acConnected)
        await bus.publish(.acConnected)
        await bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(100))

        let m = spy.actions.first?.1 ?? 0
        XCTAssertLessThanOrEqual(m, 2.0, "Multiplier must not exceed 2.0")
    }
}

// MARK: - Per-output shouldFire gate tests

@MainActor
final class ReactiveOutputShouldFireTests: XCTestCase {

    // MARK: - DisplayBrightnessFlash

    func testDisplayBrightnessRejectsWhenDisabled() {
        let output = DisplayBrightnessFlash()
        let provider = FakeConfigProvider()
        provider.displayBrightnessEnabled = false
        XCTAssertFalse(output.shouldFire(makeFired(intensity: 0.8), provider: provider))
    }

    func testDisplayBrightnessRejectsIntensityBelowThreshold() {
        let output = DisplayBrightnessFlash()
        let provider = FakeConfigProvider()
        provider.displayBrightnessEnabled = true
        provider.displayBrightnessThreshold = 0.5
        // intensity 0.3 < threshold 0.5
        XCTAssertFalse(output.shouldFire(makeFired(intensity: 0.3), provider: provider))
    }

    func testDisplayBrightnessAcceptsIntensityAtOrAboveThreshold() {
        let output = DisplayBrightnessFlash()
        let provider = FakeConfigProvider()
        provider.displayBrightnessEnabled = true
        provider.displayBrightnessThreshold = 0.3
        XCTAssertTrue(output.shouldFire(makeFired(intensity: 0.3), provider: provider),  "at threshold")
        XCTAssertTrue(output.shouldFire(makeFired(intensity: 0.9), provider: provider),  "above threshold")
    }

    // MARK: - VolumeSpikeResponder

#if DIRECT_BUILD
    func testVolumeSpikeRejectsWhenDisabled() {
        let output = VolumeSpikeResponder()
        let provider = FakeConfigProvider()
        provider.volumeSpikeEnabled = false
        XCTAssertFalse(output.shouldFire(makeFired(intensity: 0.9), provider: provider))
    }

    func testVolumeSpikeRejectsIntensityBelowThreshold() {
        let output = VolumeSpikeResponder()
        let provider = FakeConfigProvider()
        provider.volumeSpikeEnabled = true
        provider.volumeSpikeThreshold = 0.6
        XCTAssertFalse(output.shouldFire(makeFired(intensity: 0.4), provider: provider))
    }

    func testVolumeSpikeAcceptsAtThreshold() {
        let output = VolumeSpikeResponder()
        let provider = FakeConfigProvider()
        provider.volumeSpikeEnabled = true
        provider.volumeSpikeThreshold = 0.5
        XCTAssertTrue(output.shouldFire(makeFired(intensity: 0.5), provider: provider))
    }
#endif

    // MARK: - HapticResponder

    func testHapticRejectsWhenDisabled() {
        let output = HapticResponder()
        let provider = FakeConfigProvider()
        provider.hapticEnabled = false
        XCTAssertFalse(output.shouldFire(makeFired(), provider: provider))
    }

    func testHapticAcceptsWhenEnabled() {
        // shouldFire also gates on hardware support. Inject a mock
        // driver that reports hardware available so the test runs on
        // any machine, regardless of Force Touch availability.
        //
        // Matrix-converted: cross hardware × enabled × reaction so every
        // accept/reject combination is asserted with coordinate-tagged
        // failure messages. The original single-cell assertion is the
        // (hardware=true, enabled=true, .impact) cell.
        struct ReactionCell {
            let label: String
            let make: () -> Reaction
        }
        let cells: [ReactionCell] = [
            ReactionCell(label: "impact",      make: { .impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1.0, sources: [])) }),
            ReactionCell(label: "acConnected", make: { .acConnected }),
            ReactionCell(label: "willSleep",   make: { .willSleep }),
            ReactionCell(label: "keyboardTyped", make: { .keyboardTyped }),
        ]
        for hardware in [false, true] {
            for enabled in [false, true] {
                for cell in cells {
                    let mock = MockHapticEngineDriver()
                    mock.setHardwareAvailable(hardware)
                    let output = HapticResponder(driver: mock)
                    let provider = FakeConfigProvider()
                    provider.hapticEnabled = enabled
                    let fired = FiredReaction(
                        reaction: cell.make(),
                        clipDuration: 0.05,
                        soundURL: nil,
                        faceIndices: [0],
                        publishedAt: Date()
                    )
                    let actual = output.shouldFire(fired, provider: provider)
                    let expected = hardware && enabled
                    XCTAssertEqual(actual, expected,
                                   "[hardware=\(hardware) enabled=\(enabled) reaction=\(cell.label)] " +
                                   "shouldFire=\(actual), expected \(expected)")
                }
            }
        }
    }

    func testHapticRejectsWhenHardwareUnavailable() {
        let mock = MockHapticEngineDriver()
        mock.setHardwareAvailable(false)
        let output = HapticResponder(driver: mock)
        let provider = FakeConfigProvider()
        provider.hapticEnabled = true
        XCTAssertFalse(output.shouldFire(makeFired(), provider: provider),
                       "Without Force Touch hardware, shouldFire must be false even when the user enabled haptics")
    }

    // MARK: - ScreenFlash

    func testScreenFlashRejectsWhenDisabled() {
        let output = ScreenFlash()
        let provider = FakeConfigProvider()
        provider.flashEnabled = false
        XCTAssertFalse(output.shouldFire(makeFired(), provider: provider))
    }

    func testScreenFlashRejectsBlockedReactionKind() {
        let output = ScreenFlash()
        let provider = FakeConfigProvider()
        provider.flashEnabled = true
        // Explicitly block .acConnected kind
        provider.flashPerReaction[.acConnected] = false
        let fired = FiredReaction(
            reaction: .acConnected,
            clipDuration: 0.05, soundURL: nil, faceIndices: [0], publishedAt: Date()
        )
        XCTAssertFalse(output.shouldFire(fired, provider: provider))
    }

    func testScreenFlashAcceptsAllowedKind() {
        let output = ScreenFlash()
        let provider = FakeConfigProvider()
        provider.flashEnabled = true
        provider.flashPerReaction[.acConnected] = true
        let fired = FiredReaction(
            reaction: .acConnected,
            clipDuration: 0.05, soundURL: nil, faceIndices: [0], publishedAt: Date()
        )
        XCTAssertTrue(output.shouldFire(fired, provider: provider))
    }

    // MARK: - DisplayTintFlash (macOS version gate)

    func testDisplayTintShouldFireReflectsEnabledState() {
        let output = DisplayTintFlash()
        let provider = FakeConfigProvider()
        // On the current OS (< 26 in CI), enabled=true should pass.
        // If running on macOS 26+, shouldFire will always be false regardless.
        let onModernOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
        provider.displayTintEnabled = true
        let result = output.shouldFire(makeFired(), provider: provider)
        if onModernOS {
            XCTAssertTrue(result, "Tint should fire on < macOS 26 when enabled")
        } else {
            XCTAssertFalse(result, "Tint skipped on macOS 26+")
        }
    }

    func testDisplayTintDisabledReturnsFalse() {
        let output = DisplayTintFlash()
        let provider = FakeConfigProvider()
        provider.displayTintEnabled = false
        // Even if OS allows it, disabled config must block
        let onModernOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
        if onModernOS {
            XCTAssertFalse(output.shouldFire(makeFired(), provider: provider))
        }
    }
}
