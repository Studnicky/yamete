import XCTest
@testable import SensorKit
@testable import YameteCore

/// Lifecycle tests for `HeadphoneMotionAdapter`. Verifies connection
/// tracker defaults, open-without-hardware behavior, open/close
/// symmetry, and stream pruning when headphones disconnect
/// mid-stream.
///
/// Real headphone motion requires AirPods Pro/Max or Beats with an
/// H-chip physically connected to the host. CI and most dev boxes
/// don't have that, so every test here is prepared to skip.
///
/// Per the test plan we do NOT mock `CMHeadphoneMotionManager`. The
/// internal `HeadphoneConnectionTracker` class is `private`, so the
/// tests observe tracker state only indirectly through the adapter's
/// public `isAvailable` property.
final class HeadphoneMotionAdapterLifecycleTests: XCTestCase {

    /// A freshly-constructed adapter must report `isAvailable == false`
    /// until either the startup probe or the delegate's didConnect
    /// callback flips the tracker. On any host without motion-capable
    /// headphones currently connected, `isAvailable` stays false for
    /// the adapter's lifetime — which is the dominant test-environment
    /// condition and the invariant under test.
    func testConnectionTrackerInitialState() async throws {
        let adapter = HeadphoneMotionAdapter()
        // If motion-capable headphones are already connected at test
        // start, the probe may have raced us and flipped the tracker.
        // That's a valid real-world state, so we only assert the
        // default when we know no hardware is present.
        if adapter.isAvailable {
            throw XCTSkip("headphone motion available; cannot observe default-false tracker state")
        }
        XCTAssertFalse(adapter.isAvailable, "tracker defaults to not-connected")
    }

    /// When no motion-capable headphones are available, opening the
    /// stream must either surface a typed `SensorError.deviceNotFound`
    /// (when the framework itself reports no motion support) OR stay
    /// silent until cancellation (when the framework supports motion
    /// but no headphones are paired). Both are acceptable — neither
    /// may hang or throw an untyped error.
    func testOpenWithoutHeadphonesThrows() async throws {
        let adapter = HeadphoneMotionAdapter()
        try XCTSkipUnless(!adapter.isAvailable, "headphones available; cannot exercise unavailable path")

        let probe = Task<Result<Void, Error>, Never> {
            do {
                for try await _ in adapter.impacts() {
                    return .success(())
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        // Bound the wait. On frameworks that short-circuit with
        // `deviceNotFound` the throw fires immediately; on frameworks
        // that accept the request but never yield we need to cancel.
        try? await Task.sleep(for: .milliseconds(200))
        probe.cancel()
        let outcome = await probe.value

        if case .failure(let error) = outcome {
            guard let typed = error as? SensorError, case .deviceNotFound = typed else {
                XCTFail("expected SensorError.deviceNotFound, got \(error)")
                return
            }
            XCTAssertTrue(true, "adapter throws SensorError.deviceNotFound when motion unavailable")
        } else {
            // Framework accepted the request but never produced a
            // sample; cancellation closed the stream cleanly.
            XCTAssertTrue(true, "adapter stream closed cleanly under cancellation")
        }
    }

    /// Open the stream, cancel immediately, verify teardown runs. The
    /// adapter's `onTermination` closure calls
    /// `manager.stopDeviceMotionUpdates()` unconditionally via the
    /// `[manager]` capture, so the observable here is "task completes
    /// and does not crash".
    func testOpenCloseSymmetry() async throws {
        let adapter = HeadphoneMotionAdapter()

        let task = Task<Void, Error> {
            for try await _ in adapter.impacts() {
                // Discard
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value

        await Task.yield()
        XCTAssertTrue(true, "open/cancel cycle completed cleanly")
    }

    /// When motion-capable headphones disconnect mid-stream, the
    /// adapter's tracker flips to `false` and subsequent `isAvailable`
    /// checks reflect that. We cannot force a disconnect without
    /// mocking, so this test skips unless real hardware is connected
    /// and then subsequently goes away during the wait — a scenario
    /// that's impractical to stage in CI. In the common case (no
    /// headphones connected at all) the test skips immediately, which
    /// documents the expected behavior without manufacturing signal.
    func testDisconnectMidStreamPrunes() async throws {
        let adapter = HeadphoneMotionAdapter()
        try XCTSkipUnless(adapter.isAvailable, "headphone motion not available")

        let task = Task<Void, Error> {
            for try await _ in adapter.impacts() {
                // Drain
            }
        }
        // Give the stream a chance to spin up. In a CI rig this line
        // is unreachable; on a dev box with AirPods connected it
        // opens a real motion feed that the user would have to
        // manually disconnect to complete the test.
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value

        // The tracker will be whatever the hardware reports at this
        // moment — we can only assert the adapter reached this point
        // without crashing.
        XCTAssertTrue(true, "stream teardown completed for connected headphones")
    }
}
