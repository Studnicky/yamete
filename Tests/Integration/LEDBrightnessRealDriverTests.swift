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

    /// `keyboardBacklightAvailable` must honour the XPC-channel probe:
    /// when the driver advertises `true`, a follow-up `currentLevel()` MUST
    /// return a non-nil, finite, in-range value. Under SPM `swift test` the
    /// process is unsandboxed and the property either:
    ///   (a) returns `false` because the host has no backlit keyboard or
    ///       the `KeyboardBrightnessClient` class can't construct;
    ///   (b) returns `true` AND the readback succeeds, satisfying the
    ///       contract.
    /// Under host-app `xcodebuild test` the YameteHostTest target inherits
    /// the App Store sandbox; the probe must catch the `com.apple.backlightd`
    /// XPC rejection and downgrade to `false` so the test is satisfied via
    /// branch (a) instead of asserting against a silently-broken channel.
    /// The catch is the regression: prior to the probe being added,
    /// `keyboardBacklightAvailable` returned `true` under sandbox and this
    /// assertion failed because `currentLevel()` returned a non-finite or
    /// out-of-range value.
    func testKeyboardBacklightAvailableHonoursXPCProbe() {
        let driver = RealLEDBrightnessDriver()
        guard driver.keyboardBacklightAvailable else {
            // Probe correctly downgraded to false (no hardware, no client,
            // or sandbox rejection). Contract holds vacuously.
            return
        }
        // If we're advertising the surface, the readback must succeed and
        // produce a sane value.
        guard let level = driver.currentLevel() else {
            XCTFail("keyboardBacklightAvailable=true but currentLevel() returned nil — XPC probe missed a sandbox rejection")
            return
        }
        XCTAssertTrue(level.isFinite, "currentLevel must be finite (got \(level))")
        XCTAssertGreaterThanOrEqual(level, 0.0, "currentLevel must be ≥ 0 (got \(level))")
        XCTAssertLessThanOrEqual(level, 1.0, "currentLevel must be ≤ 1 (got \(level))")
    }
}
