import XCTest
@testable import ResponseKit

/// Integration tests for the real CoreAudio system-volume driver. Verifies
/// capture/set/restore round-trip against the live default output device.
/// Self-skips on hosts where the system volume API is unavailable
/// (e.g. cloud runners with no accessible output device).
final class SystemVolumeRealDriverTests: IntegrationTestCase {
    func testCaptureSetRestoreCycle() throws {
        let driver = RealSystemVolumeDriver()
        guard driver.getVolume() != nil else {
            throw XCTSkip("System volume API unavailable")
        }
        guard let original = driver.getVolume() else {
            throw XCTSkip("No accessible output device on this host")
        }

        let target: Float = 0.5
        driver.setVolume(target)
        usleep(50_000)
        let mid = driver.getVolume() ?? -1
        XCTAssertEqual(mid, target, accuracy: 0.05,
                       "after setVolume(\(target)), driver should report ~\(target) (got \(mid))")

        driver.setVolume(original)
        usleep(50_000)
        let restored = driver.getVolume() ?? -1
        XCTAssertEqual(restored, original, accuracy: 0.05,
                       "restore must return to original \(original) (got \(restored))")
    }
}
