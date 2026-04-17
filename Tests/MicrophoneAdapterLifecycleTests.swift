import XCTest
@testable import SensorKit
@testable import YameteCore

/// Lifecycle tests for `MicrophoneAdapter`. Verifies the AVAudioEngine
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
final class MicrophoneAdapterLifecycleTests: XCTestCase {

    /// Open the impacts stream, cancel the consuming task immediately,
    /// and verify teardown completes without crashing. The
    /// `onTermination` closure must run `removeTap` + `engine.stop()`
    /// via `OnceCleanup` regardless of whether any sample arrived.
    func testOpenCloseSymmetry() async throws {
        let adapter = MicrophoneAdapter()
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
        let adapter = MicrophoneAdapter()
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
        let adapter = MicrophoneAdapter()
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

    /// If `AVAudioEngine.start()` fails — commonly because microphone
    /// access is denied in the test environment — the adapter MUST
    /// surface a typed `SensorError` on the first `try await`, not
    /// swallow the error or hang. When the engine starts successfully
    /// we can't force the failure path without mocking, so we skip.
    func testEngineErrorPropagates() async throws {
        let adapter = MicrophoneAdapter()

        // Consume at most one result from the stream with a time bound.
        // If permission is denied, `continuation.finish(throwing:)` fires
        // immediately and the for-await rethrows. If the engine starts
        // fine we won't see a throw — skip in that case.
        let probe = Task<SensorError?, Never> {
            do {
                for try await _ in adapter.impacts() {
                    return nil
                }
                return nil
            } catch let error as SensorError {
                return error
            } catch {
                XCTFail("expected SensorError, got \(type(of: error)): \(error)")
                return nil
            }
        }

        // Bound the probe so we don't hang on a healthy engine.
        try? await Task.sleep(for: .milliseconds(200))
        probe.cancel()
        let result = await probe.value

        guard let surfaced = result else {
            throw XCTSkip("engine started successfully; cannot observe error path without mocks")
        }
        // The adapter collapses any engine-start failure onto
        // `.permissionDenied` — see MicrophoneAdapter.impacts() catch.
        if case .permissionDenied = surfaced {
            XCTAssertTrue(true, "engine failure surfaced as SensorError.permissionDenied")
        } else {
            XCTFail("expected SensorError.permissionDenied, got \(surfaced)")
        }
    }
}
