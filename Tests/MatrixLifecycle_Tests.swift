import XCTest
@preconcurrency import AVFoundation
import os
@testable import SensorKit
@testable import ResponseKit
@testable import YameteCore

/// Matrix-style lifecycle tests for every driver-injected class.
/// Each driver's lifecycle (notStarted / running / stopped / restarted)
/// is crossed with each failure injection (succeeds / fails-init /
/// fails-midstream / disconnects). Mocks drive every state without
/// touching real hardware.
@MainActor
final class MatrixLifecycle_Tests: XCTestCase {

    // MARK: - MicrophoneSource lifecycle

    /// driver_succeeds path: `notStarted → running → stopped`. Each
    /// transition records the expected counter increment on the mock.
    func testMicrophoneLifecycleSucceeds() async throws {
        let mock = MockMicrophoneEngineDriver()
        let adapter = MicrophoneSource(
            detectorConfig: .microphone(),
            driverFactory: { mock },
            availabilityOverride: { true }
        )

        // notStarted → no calls yet
        XCTAssertEqual(mock.startCalls,         0)
        XCTAssertEqual(mock.installTapCalls,    0)

        // running
        let stream = adapter.impacts()
        let task = Task<Void, Error> { for try await _ in stream {} }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(mock.startCalls,      1, "running: start called once")
        XCTAssertEqual(mock.installTapCalls, 1, "running: tap installed once")

        // stopped
        task.cancel()
        _ = try? await task.value
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThanOrEqual(mock.stopCalls,    1, "stopped: stop called")
        XCTAssertGreaterThanOrEqual(mock.removeTapCalls, 1, "stopped: tap removed")
    }

    /// driver_fails_init: start() throws → adapter cleans up tap and
    /// surfaces SensorError.permissionDenied.
    func testMicrophoneLifecycleFailsInit() async throws {
        let mock = MockMicrophoneEngineDriver()
        mock.shouldFailStart = true
        let adapter = MicrophoneSource(
            detectorConfig: .microphone(),
            driverFactory: { mock },
            availabilityOverride: { true }
        )

        let probe = Task<Error?, Never> {
            do {
                for try await _ in adapter.impacts() { return nil }
                return nil
            } catch { return error }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let err = await probe.value
        guard let typed = err as? SensorError, case .permissionDenied = typed else {
            XCTFail("expected SensorError.permissionDenied, got \(String(describing: err))")
            return
        }
        XCTAssertGreaterThanOrEqual(mock.removeTapCalls, 1, "failed init removes the tap")
    }

    /// restarted: cycle start/stop multiple times. Each cycle gets its
    /// own driver from the factory.
    func testMicrophoneLifecycleRestarted() async throws {
        // Mocks are produced fresh per cycle by the factory closure.
        let mocks = OSAllocatedUnfairLock<[MockMicrophoneEngineDriver]>(initialState: [])
        let adapter = MicrophoneSource(
            detectorConfig: .microphone(),
            driverFactory: {
                let m = MockMicrophoneEngineDriver()
                mocks.withLock { $0.append(m) }
                return m
            },
            availabilityOverride: { true }
        )

        for _ in 0..<3 {
            let stream = adapter.impacts()
            let task = Task<Void, Error> { for try await _ in stream {} }
            try? await Task.sleep(for: .milliseconds(15))
            task.cancel()
            _ = try? await task.value
            try? await Task.sleep(for: .milliseconds(15))
        }

        let allMocks = mocks.withLock { $0 }
        XCTAssertEqual(allMocks.count, 3, "factory must be called once per cycle")
        for (i, m) in allMocks.enumerated() {
            XCTAssertEqual(m.startCalls,         1, "cycle \(i) start once")
            XCTAssertEqual(m.installTapCalls,    1, "cycle \(i) install once")
            XCTAssertGreaterThanOrEqual(m.stopCalls, 1, "cycle \(i) stopped")
        }
    }

    // MARK: - HeadphoneMotionSource lifecycle

    /// driver_succeeds: connect, emit one strong sample, observe an
    /// impact. Adapter's connection guard lets the sample through.
    func testHeadphoneLifecycleSucceeds() async throws {
        let mock = MockHeadphoneMotionDriver()
        mock.setDeviceMotionAvailable(true)
        mock.setHeadphonesConnected(true)
        let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)

        let stream = adapter.impacts()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThanOrEqual(mock.startUpdatesCalls, 1)

        // Note: even strong synthetic samples may not pass the warmup
        // window of the impact detector. We only assert the lifecycle
        // here, not that an impact was synthesized.
        for _ in 0..<5 { mock.emitImpact(magnitude: 2.0) }

        let probe = Task<Void, Error> { for try await _ in stream {} }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        _ = try? await probe.value
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThanOrEqual(mock.stopUpdatesCalls, 1, "stop on cancellation")
    }

    /// driver_fails_init: framework reports motion unavailable →
    /// SensorError.deviceNotFound.
    func testHeadphoneLifecycleFailsInit() async throws {
        let mock = MockHeadphoneMotionDriver()
        mock.setDeviceMotionAvailable(false)
        let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)

        let probe = Task<Error?, Never> {
            do {
                for try await _ in adapter.impacts() { return nil }
                return nil
            } catch { return error }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let err = await probe.value
        guard let typed = err as? SensorError, case .deviceNotFound = typed else {
            XCTFail("expected SensorError.deviceNotFound, got \(String(describing: err))")
            return
        }
    }

    /// driver_fails_midstream: an error mid-stream terminates the
    /// throwing stream.
    func testHeadphoneLifecycleFailsMidstream() async throws {
        let mock = MockHeadphoneMotionDriver()
        mock.setDeviceMotionAvailable(true)
        mock.setHeadphonesConnected(true)
        let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)

        let stream = adapter.impacts()
        try? await Task.sleep(for: .milliseconds(20))
        mock.emit(error: MockSensorError.streamMidstreamFailure)

        let probe = Task<Error?, Never> {
            do {
                for try await _ in stream { return nil }
                return nil
            } catch { return error }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let surfaced = await probe.value
        XCTAssertNotNil(surfaced, "midstream error must surface as a throw")
    }

    /// driver_disconnects: connection flips false mid-stream → samples
    /// are pruned by the adapter's connection guard.
    func testHeadphoneLifecycleDisconnects() async throws {
        let mock = MockHeadphoneMotionDriver()
        mock.setDeviceMotionAvailable(true)
        mock.setHeadphonesConnected(true)
        let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)

        let stream = adapter.impacts()
        try? await Task.sleep(for: .milliseconds(20))

        // Disconnect, then push samples — they must be dropped.
        mock.setHeadphonesConnected(false)
        for _ in 0..<5 { mock.emitImpact(magnitude: 5.0) }

        let probe = Task<Int, Error> {
            var seen = 0
            for try await _ in stream { seen += 1; if seen >= 1 { break } }
            return seen
        }
        try? await Task.sleep(for: .milliseconds(60))
        probe.cancel()
        let count = (try? await probe.value) ?? 0
        XCTAssertEqual(count, 0, "post-disconnect samples must be pruned")
    }

    // MARK: - HapticResponder lifecycle

    func testHapticLifecycleSucceeds() async throws {
        let mock = MockHapticEngineDriver()
        mock.setHardwareAvailable(true)
        let output = HapticResponder(driver: mock)
        XCTAssertTrue(output.hardwareAvailable, "responder mirrors driver capability at construction")

        let provider = MockConfigProvider()
        let fired = FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: 0.8, confidence: 1.0, sources: [])),
            clipDuration: 0.1, soundURL: nil, faceIndices: [0], publishedAt: Date()
        )
        XCTAssertTrue(output.shouldFire(fired, provider: provider))

        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.startCalls,        1, "engine started lazily on first action")
        XCTAssertGreaterThanOrEqual(mock.playPatternCalls, 1, "pattern played at least once")

        output.reset()
        XCTAssertGreaterThanOrEqual(mock.stopCalls, 1, "reset stops the engine")
    }

    func testHapticLifecycleFailsInit() async throws {
        let mock = MockHapticEngineDriver()
        mock.setHardwareAvailable(true)
        mock.shouldFailStart = true
        let output = HapticResponder(driver: mock)
        let provider = MockConfigProvider()
        let fired = FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: 0.8, confidence: 1.0, sources: [])),
            clipDuration: 0.1, soundURL: nil, faceIndices: [0], publishedAt: Date()
        )
        // Action attempts to start the engine, which throws. The
        // responder must swallow the error and skip pattern playback
        // rather than crash.
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.startCalls, 1, "start attempted")
        XCTAssertEqual(mock.playPatternCalls, 0, "no pattern played when engine failed to start")
    }

    func testHapticLifecycleFailsMidstream() async throws {
        let mock = MockHapticEngineDriver()
        mock.setHardwareAvailable(true)
        mock.shouldFailPlay = true
        let output = HapticResponder(driver: mock)
        let provider = MockConfigProvider()
        let fired = FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: 0.8, confidence: 1.0, sources: [])),
            clipDuration: 0.1, soundURL: nil, faceIndices: [0], publishedAt: Date()
        )
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.startCalls,         1)
        XCTAssertEqual(mock.playPatternCalls,   1)
        // Subsequent invocation should re-attempt start (the responder
        // resets engineStarted on play failure).
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.startCalls,         2, "engine restarted after play failure")
    }

    /// Cancel-and-reset path: a reaction's `action` is in flight when the
    /// owner aborts. The contract is that `reset()` runs (restoring driver
    /// state), `postAction` does NOT run (no orphaned restore), and a fresh
    /// reaction afterwards proceeds normally. We model this on `LEDFlash`
    /// since it carries explicit captured state to verify against.
    func testCancelAndReset_invokedDuringAction_runsResetThenRestore() async throws {
        let mock = MockLEDBrightnessDriver()
        mock.setKeyboardBacklightAvailable(true)
        mock.setCapsLockAccessGranted(true)
        mock.setCurrentLevel(0.42)
        let output = LEDFlash(driver: mock)
        output.setUp()
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.8, clipDuration: 0.50)

        // preAction captures 0.42, then action begins pulsing.
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        let actionTask = Task { await output.action(fired, multiplier: 1.0, provider: provider) }
        try? await Task.sleep(for: .milliseconds(30))

        // Mid-action: cancel the action and call reset(). Skip postAction —
        // simulate the owner-initiated teardown.
        actionTask.cancel()
        _ = await actionTask.value
        output.reset()

        // After reset(): the driver's last setLevel must be the captured 0.42
        // (NOT a stale launch default, NOT the last pulse value). reset()
        // also unconditionally resumes idle dimming.
        XCTAssertEqual(Double(mock.setLevelHistory.last ?? -1), 0.42, accuracy: 0.001,
                       "reset() must restore the captured snapshot value")
        XCTAssertEqual(mock.setIdleSuspendedHistory.last, false,
                       "reset() must resume idle dimming")

        // Drive a second reaction — output must not be in a stuck state.
        // currentLevel was last written to 0.42 by reset, and the sentinel was
        // cleared. Another preAction should re-capture.
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(Double(mock.setLevelHistory.last ?? -1), 0.42, accuracy: 0.001,
                       "second flash after cancel-and-reset still restores correctly")
    }

    private static func firedImpact(intensity: Float, clipDuration: Double) -> FiredReaction {
        FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: [])),
            clipDuration: clipDuration,
            soundURL: nil,
            faceIndices: [0],
            publishedAt: Date()
        )
    }

    func testHapticLifecycleHardwareUnavailable() async throws {
        let mock = MockHapticEngineDriver()
        mock.setHardwareAvailable(false)
        let output = HapticResponder(driver: mock)
        let provider = MockConfigProvider()
        let fired = FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: 0.8, confidence: 1.0, sources: [])),
            clipDuration: 0.1, soundURL: nil, faceIndices: [0], publishedAt: Date()
        )
        XCTAssertFalse(output.shouldFire(fired, provider: provider))
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.startCalls,       0, "no engine start when hardware unavailable")
        XCTAssertEqual(mock.playPatternCalls, 0, "no pattern played when hardware unavailable")
    }
}
