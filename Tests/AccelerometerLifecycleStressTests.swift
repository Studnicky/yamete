import XCTest
@testable import SensorKit
@testable import YameteCore

/// Stress test for `SPUAccelerometerAdapter` lifecycle: opens and closes the
/// HID stream many times in sequence to catch callback-after-free races,
/// double-free, leaked OnceCleanup state, or stuck run-loop threads.
///
/// Most useful when run with `swift test --sanitize=thread` on a real
/// Apple Silicon MacBook with the BMI286 SPU device available. On hardware
/// without an SPU device the adapter is not available and the test exits
/// early via `XCTSkipUnless`. Uses `hardwarePresent` (not `isAvailable`)
/// because the tests exercise lifecycle cleanup paths that don't require
/// the sensor to be actively streaming — a cold sensor is a valid test
/// condition, and exits via the 50ms drain timeout rather than delivering
/// actual reports.
///
/// Goal: each open/close cycle must complete cleanly without:
///   - crashing on the report callback after teardown
///   - leaking the dedicated HID run-loop thread
///   - leaking the retained `ReportContext`
///   - leaving the SPU driver in an activated state
@MainActor
final class AccelerometerLifecycleStressTests: XCTestCase {

    /// Repeatedly create-and-cancel an accelerometer stream. The exact
    /// iteration count is small enough to keep CI fast but large enough
    /// to surface state-leak races on a real device.
    func testRepeatedOpenClose() async throws {
        let adapter = SPUAccelerometerAdapter()
        try XCTSkipUnless(adapter.hardwarePresent, "SPU accelerometer not available on this host")

        let cycles = 25
        for cycle in 0..<cycles {
            // Drain a couple of impacts (or hit a quick timeout) then drop
            // the task — `onTermination` runs the OnceCleanup teardown.
            let task = Task<Int, Error> {
                var count = 0
                for try await _ in adapter.impacts() {
                    count += 1
                    if count >= 2 { break }
                }
                return count
            }

            // Give the run loop a small window. The point of this test is
            // not to verify report delivery (covered elsewhere) but to make
            // sure repeated open/close converges cleanly.
            try? await Task.sleep(for: .milliseconds(50))
            task.cancel()
            _ = try? await task.value

            // Yield to let the OnceCleanup termination handler complete
            // before starting the next cycle. Without this, two cleanup
            // closures can race the SPU driver activation state.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))

            if cycle == cycles - 1 {
                // Final cycle: explicit assertion that we made it here at all.
                XCTAssertTrue(true, "completed \(cycles) open/close cycles without crashing")
            }
        }
    }

    /// Open and immediately cancel the stream before any reports arrive.
    /// Catches the "cancelled before first delivery" race where the cleanup
    /// closure runs before the report callback has been registered.
    func testCancelBeforeFirstReport() async throws {
        let adapter = SPUAccelerometerAdapter()
        try XCTSkipUnless(adapter.hardwarePresent, "SPU accelerometer not available on this host")

        for _ in 0..<10 {
            let task = Task<Void, Error> {
                for try await _ in adapter.impacts() {
                    // Discard
                }
            }
            // Cancel ASAP — no sleep, no yield. The teardown must handle
            // the case where the run-loop thread is still spinning up.
            task.cancel()
            _ = try? await task.value
        }
        XCTAssertTrue(true, "10 cancel-before-first-report cycles completed cleanly")
    }
}
