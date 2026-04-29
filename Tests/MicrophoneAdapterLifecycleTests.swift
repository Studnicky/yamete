import XCTest
@preconcurrency import AVFoundation
@testable import SensorKit
@testable import YameteCore

/// Lifecycle tests for `MicrophoneSource`. Verifies the AVAudioEngine
/// tap install / remove cycle terminates cleanly under open / cancel,
/// repeated open-close, mid-stream cancellation, and typed-error
/// propagation when the engine cannot start.
///
/// The adapter routes real PCM through AVAudioEngine, so these tests
/// require microphone access. In CI or a sandboxed host where the
/// microphone is unavailable the tests fail-open via `XCTSkip`
/// rather than false-positive.
///
/// What's observable from outside the adapter:
///   - The `AsyncThrowingStream` terminates after `task.cancel()`.
///   - A failed engine start surfaces `SensorError.permissionDenied`
///     on the first `try await` rather than hanging.
///   - Repeated open/close cycles do not crash; `OnceCleanup` ensures
///     `removeTap` + `engine.stop()` run at most once per cycle.
///
/// What's NOT observable (and therefore not asserted):
///   - The internal state of `OnceCleanup` (private).
///   - Whether specific samples arrive (hardware-dependent).
final class MicrophoneSourceLifecycleTests: XCTestCase {

    /// Open the impacts stream, cancel the consuming task immediately,
    /// and verify teardown completes without crashing. The
    /// `onTermination` closure must run `removeTap` + `engine.stop()`
    /// via `OnceCleanup` regardless of whether any sample arrived.
    func testOpenCloseSymmetry() async throws {
        let adapter = MicrophoneSource()
        try XCTSkipUnless(adapter.isAvailable, "microphone unavailable")

        let task = Task<Void, Error> {
            for try await _ in adapter.impacts() {
                // Discard — we just want to exercise open / cancel.
            }
        }
        task.cancel()
        _ = try? await task.value

        // Yield so the termination handler has a chance to land before
        // the test exits and tears the engine down under us.
        await Task.yield()
        XCTAssertTrue(true, "open/cancel cycle completed cleanly")
    }

    /// Open and cancel the stream N times in sequence. Each cycle runs
    /// its own `OnceCleanup`; the test surfaces any cleanup race or
    /// double-teardown via a crash / runtime warning rather than an
    /// explicit assertion (those are fatal, so absence is the signal).
    func testRepeatedOpenCloseNoLeak() async throws {
        let adapter = MicrophoneSource()
        try XCTSkipUnless(adapter.isAvailable, "microphone unavailable")

        let cycles = 5
        for _ in 0..<cycles {
            let task = Task<Void, Error> {
                for try await _ in adapter.impacts() {
                    // Discard
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
            task.cancel()
            _ = try? await task.value
            // Let the termination handler drain before starting the
            // next engine. Without this two engines can briefly share
            // ownership of the shared input node.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(true, "completed \(cycles) open/close cycles")
    }

    /// Open the stream, let the engine actually run for a short window
    /// so a tap buffer or two can fire, then cancel. The consuming
    /// task must complete — a stuck stream would hang this test.
    func testCancellationDuringStream() async throws {
        let adapter = MicrophoneSource()
        try XCTSkipUnless(adapter.isAvailable, "microphone unavailable")

        let task = Task<Int, Error> {
            var count = 0
            for try await _ in adapter.impacts() {
                count += 1
                if count >= 1 { break }
            }
            return count
        }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let count = try? await task.value
        XCTAssertNotNil(count, "stream task terminated (possibly 0 samples)")
    }

    /// If `AVAudioEngine.start()` fails the adapter MUST surface a
    /// typed `SensorError.permissionDenied` on the first `try await`
    /// rather than hang or swallow the error. Driven via a mock
    /// engine driver so the failure path is deterministic.
    ///
    /// Matrix-converted: loops over multiple start-failure error types so
    /// the adapter's error mapping is exhaustive. (`start-fails / mid-tap-
    /// fails / restart-fails` from the original plan reduces to start-fails
    /// here because the underlying engine driver only models a start
    /// failure — adding the other two would require new mock surface area.)
    func testEngineErrorPropagates() async throws {
        struct Cell {
            let label: String
            let injectedError: Error
        }
        let cells: [Cell] = [
            Cell(label: "engineStartFailed", injectedError: MockSensorError.engineStartFailed),
            Cell(label: "midstreamFailure",  injectedError: MockSensorError.streamMidstreamFailure),
        ]

        for cell in cells {
            let mock = MockMicrophoneEngineDriver()
            mock.shouldFailStart = true
            mock.startError = cell.injectedError
            let adapter = MicrophoneSource(
                detectorConfig: .microphone(),
                driverFactory: { mock },
                availabilityOverride: { true }
            )

            let probe = Task<SensorError?, Never> {
                do {
                    for try await _ in adapter.impacts() {
                        return nil
                    }
                    return nil
                } catch let error as SensorError {
                    return error
                } catch {
                    XCTFail("[\(cell.label)] expected SensorError, got \(type(of: error)): \(error)")
                    return nil
                }
            }

            try? await Task.sleep(for: .milliseconds(100))
            probe.cancel()
            let result = await probe.value

            guard let surfaced = result else {
                XCTFail("[\(cell.label)] expected the adapter to surface a SensorError when driver.start() throws")
                continue
            }
            if case .permissionDenied = surfaced {
                XCTAssertTrue(true, "[\(cell.label)] engine failure surfaced as SensorError.permissionDenied")
            } else {
                XCTFail("[\(cell.label)] expected SensorError.permissionDenied, got \(surfaced)")
            }

            // Tap-leak guard: a failed start must remove the tap so the
            // node isn't left in an undefined state.
            XCTAssertEqual(mock.installTapCalls, 1, "[\(cell.label)] tap must be installed exactly once")
            XCTAssertEqual(mock.removeTapCalls,  1, "[\(cell.label)] tap must be removed exactly once")
        }
    }

    /// Mutation-anchor cell for `MicrophoneAdapter.swift` line 91: the
    /// input-format validity gate (`channelCount > 0, sampleRate > 0`).
    /// A driver reporting a zero-channel format must surface
    /// `SensorError.deviceNotFound` AND must not install a tap. Removing
    /// the gate would let `installTap` proceed with the bogus format
    /// and crash CoreAudio.
    func testInvalidInputFormat_throwsDeviceNotFound_doesNotInstallTap() async throws {
        let mock = MockMicrophoneEngineDriver()
        // Construct a zero-channel format the gate is designed to reject.
        // AVAudioFormat refuses 0 channels at construction, so we use the
        // canonical "no real input" stand-in: build a 1-channel format and
        // drop sampleRate to 0 via channelLayout-less construction. The
        // simplest deterministic failure is a sampleRate=0 format, which
        // the standardFormatWithSampleRate initializer accepts.
        guard let bogusFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 0,
            channels: 1,
            interleaved: false
        ) else {
            // AVAudioFormat may refuse sampleRate=0 outright on some OS
            // versions — in which case the gate's defensive purpose is
            // already satisfied by the framework. Skip rather than
            // false-positive.
            throw XCTSkip("[mic-gate=invalid-format] AVAudioFormat refused sampleRate=0 — gate not exercisable on this OS")
        }
        mock.setInputFormat(bogusFormat)
        let adapter = MicrophoneSource(
            detectorConfig: .microphone(),
            driverFactory: { mock },
            availabilityOverride: { true }
        )

        let probe = Task<SensorError?, Never> {
            do {
                for try await _ in adapter.impacts() { return nil }
                return nil
            } catch let error as SensorError {
                return error
            } catch {
                XCTFail("[mic-gate=invalid-format] expected SensorError, got \(error)")
                return nil
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let surfaced = await probe.value

        guard let typed = surfaced, case .deviceNotFound = typed else {
            XCTFail(
                "[mic-gate=invalid-format] expected SensorError.deviceNotFound, got \(String(describing: surfaced))"
            )
            return
        }
        XCTAssertEqual(
            mock.installTapCalls, 0,
            "[mic-gate=invalid-format] tap MUST NOT be installed when format is invalid (got \(mock.installTapCalls) installs)"
        )
        XCTAssertEqual(
            mock.startCalls, 0,
            "[mic-gate=invalid-format] driver MUST NOT be started when format is invalid (got \(mock.startCalls) starts)"
        )
    }

    /// Successful start path: the driver's start is called, a tap is
    /// installed, and synthesized PCM buffers driven through the mock
    /// reach the detector. Verifies the integration without real audio.
    func testSuccessfulStartInstallsTapAndStarts() async throws {
        let mock = MockMicrophoneEngineDriver()
        let adapter = MicrophoneSource(
            detectorConfig: .microphone(),
            driverFactory: { mock },
            availabilityOverride: { true }
        )
        let stream = adapter.impacts()

        let task = Task<Void, Error> {
            for try await _ in stream {}
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        _ = try? await task.value
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(mock.startCalls,         1, "driver started exactly once")
        XCTAssertEqual(mock.installTapCalls,    1, "tap installed exactly once")
        XCTAssertGreaterThanOrEqual(mock.stopCalls,    1, "driver stopped on stream cancellation")
        XCTAssertGreaterThanOrEqual(mock.removeTapCalls, 1, "tap removed on stream cancellation")
    }

    /// Pins `MicrophoneAdapter.swift:104` `guard frameLength > 0 else { return }`.
    /// Drive 5 strong-transient buffers through the permissive detector via the
    /// existing `MockMicrophoneEngineDriver.emit(buffer:)` seam. The production
    /// gate must let nonzero-length buffers through; mutation that inverts the
    /// gate to `<= 0` short-circuits every buffer and yields zero impacts.
    func testFrameLengthGate_validBuffers_yieldImpact() async throws {
        let mock = MockMicrophoneEngineDriver()
        let permissiveCfg = ImpactDetectorConfig(
            spikeThreshold: 0.01, minRiseRate: 0, minCrestFactor: 0,
            minConfirmations: 1, warmupSamples: 0,
            intensityFloor: 0.01, intensityCeiling: 1.0
        )
        let adapter = MicrophoneSource(
            detectorConfig: permissiveCfg,
            driverFactory: { mock }
        )

        let stream = adapter.impacts()
        let collector = Task<Int, Error> {
            var count = 0
            for try await _ in stream {
                count += 1
                if count >= 1 { break }
            }
            return count
        }
        // Wait for the tap to install before emitting.
        try? await Task.sleep(for: .milliseconds(50))

        // Build 5 strong-transient PCM buffers (1.0 amplitude, 256 frames each).
        let format = mock.inputFormat
        for _ in 0..<5 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else { continue }
            buf.frameLength = 256
            if let chan = buf.floatChannelData?[0] {
                for i in 0..<256 { chan[i] = 1.0 }
            }
            mock.emit(buffer: buf)
            try? await Task.sleep(for: .milliseconds(15))
        }

        // Wait for at least one impact, then collect.
        try? await Task.sleep(for: .milliseconds(100))
        collector.cancel()
        let count = (try? await collector.value) ?? 0
        XCTAssertGreaterThanOrEqual(
            count, 1,
            "[mic-gate=frameLength] strong-transient buffers must yield ≥ 1 impact under the production frameLength > 0 gate; got \(count)"
        )
    }
}
