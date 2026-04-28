import XCTest
@testable import ResponseKit

/// Integration tests for the real LED brightness driver. Skipped on hosts
/// without a backlit Apple keyboard. Verifies the capture/set/restore cycle
/// the unit-level MockLEDBrightnessDriver promises but cannot enforce
/// against real hardware.
final class LEDBrightnessRealDriverTests: IntegrationTestCase {
    func testCaptureSetRestoreCycle() throws {
        let driver = RealLEDBrightnessDriver()
        guard driver.keyboardBacklightAvailable else {
            throw XCTSkip("No keyboard backlight on this machine")
        }
        guard let original = driver.currentLevel() else {
            throw XCTSkip("Cannot read current level (driver returned nil)")
        }

        // Set midpoint, give the framework a beat to commit, then read back.
        driver.setLevel(0.42)
        usleep(50_000)
        let mid = driver.currentLevel() ?? -1
        XCTAssertEqual(mid, 0.42, accuracy: 0.05,
                       "after setLevel(0.42), driver should report ~0.42 (got \(mid))")

        // Restore to original and re-verify.
        driver.setLevel(original)
        usleep(50_000)
        let restored = driver.currentLevel() ?? -1
        XCTAssertEqual(restored, original, accuracy: 0.05,
                       "restore must return to original \(original) (got \(restored))")
    }
}
