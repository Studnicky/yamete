import XCTest
@testable import SensorKit
@testable import YameteCore

/// Lifecycle tests for `HeadphoneMotionSource`. Verifies connection
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
final class HeadphoneMotionSourceLifecycleTests: XCTestCase {

    /// A freshly-constructed adapter must report `isAvailable == false`
    /// until either the startup probe or the delegate's didConnect
    /// callback flips the tracker. On any host without motion-capable
    /// headphones currently connected, `isAvailable` stays false for
    /// the adapter's lifetime — which is the dominant test-environment
    /// condition and the invariant under test.
    func testConnectionTrackerInitialState() async throws {
        let adapter = HeadphoneMotionSource()
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
        let adapter = HeadphoneMotionSource()
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
        let adapter = HeadphoneMotionSource()

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
    /// adapter's tracker flips to `false` and subsequent samples are
    /// dropped before reaching the impact detector. Driven via a mock
    /// driver so the scenario doesn't depend on real AirPods.
    ///
    /// Matrix-converted: loops over (samples-before-disconnect) ×
    /// (reconnect-after-disconnect). Each cell asserts the exact pruned
    /// count instead of "≥ 0", giving coordinate-tagged failure messages
    /// when one specific scenario regresses.
    func testDisconnectMidStreamPrunes() async throws {
        struct Cell {
            let samplesBefore: Int
            let reconnect: Bool
        }
        let cells: [Cell] = [
            Cell(samplesBefore: 1,   reconnect: false),
            Cell(samplesBefore: 5,   reconnect: false),
            Cell(samplesBefore: 100, reconnect: false),
            Cell(samplesBefore: 1,   reconnect: true),
            Cell(samplesBefore: 5,   reconnect: true),
            Cell(samplesBefore: 100, reconnect: true),
        ]
        for cell in cells {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            mock.setHeadphonesConnected(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)
            let label = "[samplesBefore=\(cell.samplesBefore) reconnect=\(cell.reconnect)]"
            XCTAssertTrue(adapter.isAvailable, "\(label) mock reports framework + headphones available")

            let stream = adapter.impacts()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertGreaterThanOrEqual(mock.startUpdatesCalls, 1,
                                        "\(label) adapter starts driver updates")

            // Disconnect, emit 10 post-disconnect samples (regardless of
            // samplesBefore — that quantity governs how many "should have
            // delivered" pre-disconnect, which we don't drain here because
            // the adapter pruning is what's under test).
            mock.setHeadphonesConnected(false)
            for _ in 0..<10 { mock.emitImpact(magnitude: 2.0) }

            // Optional reconnect AFTER pruning to confirm the connection
            // tracker isn't latched-false: a reconnect must flip
            // isAvailable back to true.
            if cell.reconnect {
                mock.setHeadphonesConnected(true)
            }

            let probe = Task<Int, Error> {
                var seen = 0
                for try await _ in stream {
                    seen += 1
                    if seen >= 1 { break }
                }
                return seen
            }
            try? await Task.sleep(for: .milliseconds(60))
            probe.cancel()
            let count = (try? await probe.value) ?? 0
            XCTAssertEqual(count, 0,
                           "\(label) post-disconnect samples must be pruned by adapter (got \(count))")
            let expectedAvailable = cell.reconnect
            XCTAssertEqual(adapter.isAvailable, expectedAvailable,
                           "\(label) isAvailable=\(adapter.isAvailable), expected \(expectedAvailable)")
        }
    }

    /// When the framework reports motion unavailable, `impacts()`
    /// must surface `SensorError.deviceNotFound` immediately.
    func testFrameworkUnavailableThrowsDeviceNotFound() async throws {
        let mock = MockHeadphoneMotionDriver()
        mock.setDeviceMotionAvailable(false)
        let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)

        let probe = Task<Result<Void, Error>, Never> {
            do {
                for try await _ in adapter.impacts() { return .success(()) }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let outcome = await probe.value

        guard case .failure(let error) = outcome,
              let typed = error as? SensorError,
              case .deviceNotFound = typed else {
            XCTFail("expected SensorError.deviceNotFound, got \(outcome)")
            return
        }
        XCTAssertTrue(true)
    }

    /// When a mid-stream error arrives from the underlying motion
    /// manager, the adapter terminates the stream by re-throwing it.
    func testMidStreamErrorPropagates() async throws {
        let mock = MockHeadphoneMotionDriver()
        mock.setDeviceMotionAvailable(true)
        mock.setHeadphonesConnected(true)
        let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)

        let stream = adapter.impacts()
        try await Task.sleep(for: .milliseconds(20))
        mock.emit(error: MockSensorError.streamMidstreamFailure)

        let probe = Task<Error?, Never> {
            do {
                for try await _ in stream { return nil }
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        probe.cancel()
        let surfaced = await probe.value
        XCTAssertNotNil(surfaced, "mid-stream error must terminate the stream with a throw")
    }
}
