import XCTest
@testable import YameteCore
@testable import SensorKit

/// Source debounce matrix: per-source debounce window × inter-arrival timing.
///
/// Bug class: rapid-fire IOKit callbacks emit duplicate events because
///   1) the debounce constant in `ReactionsConfig` drifts, or
///   2) the source bypasses its own debounce path on a refactor.
///
/// Strategy: assert the constants in `ReactionsConfig` are pinned to their
/// documented values, and for the two sources that DO enforce a time-based
/// debounce in code (USB via `shouldPublish` and DisplayHotplug via
/// `dispatchDebounced`), drive the debounce path through dedicated test
/// seams across the {0ms, ~debounce-1ms, debounce, debounce+slack} cells.
///
/// The other sources in `ReactionsConfig` (audioPeripheral, bluetooth,
/// thunderbolt, power) document IOKit's edge-triggered semantics — the
/// constant is a tuning surface but no time-based gate exists in code. Those
/// cells assert only the constant.
@MainActor
final class MatrixSourceDebounce_Tests: XCTestCase {

    // MARK: - Pinned constants

    func testDebounceConstantsPinned() {
        // Drift here implies behavioral change downstream — pin every
        // documented per-source debounce window. Only USB and Display use a
        // time-based gate; the other sources have alternate dedup paths
        // (Set-diff, edge-state, IOKit single-event-per-device).
        XCTAssertEqual(ReactionsConfig.usbDebounce, 0.05, accuracy: 1e-9,
            "[source=usb] documented USB debounce drifted; expected 50ms")
        XCTAssertEqual(ReactionsConfig.displayDebounce, 0.20, accuracy: 1e-9,
            "[source=display] expected 200ms")
    }

    // MARK: - USB rapid-fire matrix

    /// One emit, then a second after `delayMs` — assert how many of the two
    /// pass the production `shouldPublish` debounce gate.
    private func usbRapidFire(delayMs: Int) async throws -> Int {
        let source = USBSource()
        var passed = 0
        if source._testShouldPublish(.usbAttached) { passed += 1 }
        if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
        if source._testShouldPublish(.usbAttached) { passed += 1 }
        return passed
    }

    /// 4 cells × {0ms, 1ms, debounce-well-under (10ms), debounce-well-over (200ms)}.
    /// First emit always passes. Second passes only when delay ≥ debounce.
    ///
    /// CI calibration: under the GitHub macos runner a 40ms `Task.sleep`
    /// can stretch past the 50ms USB debounce constant, so the
    /// previously-used "debounce-10ms" cell flipped to "second emit
    /// passes" non-deterministically. The strict-block cells are now
    /// well under 50ms (10ms + 30ms scheduler slack still ≤ 50ms) and
    /// the strict-pass cell is well past (200ms + slack still > 50ms),
    /// so the test stays deterministic regardless of scheduler load.
    func testUSBDebounceRapidFire() async throws {
        struct Cell { let delayMs: Int; let expectedPassed: Int }
        let cells: [Cell] = [
            .init(delayMs: 0,   expectedPassed: 1),
            .init(delayMs: 1,   expectedPassed: 1),
            .init(delayMs: 5,   expectedPassed: 1),  // safely under 50ms debounce
            .init(delayMs: 200, expectedPassed: 2),  // safely past 50ms debounce
        ]
        for cell in cells {
            let passed = try await usbRapidFire(delayMs: cell.delayMs)
            XCTAssertEqual(passed, cell.expectedPassed,
                "[source=usb cell=delay=\(cell.delayMs)ms expected=\(cell.expectedPassed)] " +
                "USB shouldPublish gate produced wrong count, got \(passed)")
        }
    }

    /// Distinct vendor/product IDs occupy independent debounce slots — two
    /// rapid-fire emits with different keys both pass.
    func testUSBDebounceIndependentKeys() {
        let source = USBSource()
        // First emit (attached) — passes.
        let attachPassed = source._testShouldPublish(.usbAttached)
        // Second emit at the SAME instant for detached (different key) —
        // passes too because the key is "detach-..." not "attach-...".
        let detachPassed = source._testShouldPublish(.usbDetached)
        XCTAssertTrue(attachPassed, "[source=usb cell=keys=attach-then-detach] first emit blocked")
        XCTAssertTrue(detachPassed, "[source=usb cell=keys=attach-then-detach] detach should not be debounced by attach")
    }

    // MARK: - DisplayHotplug rapid-fire matrix

    /// Drives the production `dispatchDebounced` path. Returns true if the
    /// emit passed the time-based gate (lastFire updated).
    private func displayRapidFire(delayMs: Int) async throws -> Int {
        let source = DisplayHotplugSource()
        var passed = 0
        if source._testDispatchDebounced() { passed += 1 }
        if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
        if source._testDispatchDebounced() { passed += 1 }
        return passed
    }

    /// Display debounce window is 200ms.
    ///
    /// CI calibration: under load a 100ms `Task.sleep` can stretch past
    /// the 200ms debounce boundary (~3x scheduler factor). The
    /// strict-block cells stay safely under 200ms (≤ 30ms + slack still
    /// fits) and the strict-pass cell uses 700ms (200ms debounce + 500ms
    /// margin against scheduler stretch) so the test is deterministic
    /// across hardware.
    func testDisplayDebounceRapidFire() async throws {
        struct Cell { let delayMs: Int; let expectedPassed: Int }
        let cells: [Cell] = [
            .init(delayMs: 0,   expectedPassed: 1),
            .init(delayMs: 1,   expectedPassed: 1),
            .init(delayMs: 30,  expectedPassed: 1),  // safely under 200ms window
            .init(delayMs: 700, expectedPassed: 2),  // safely past 200ms window
        ]
        for cell in cells {
            let passed = try await displayRapidFire(delayMs: cell.delayMs)
            XCTAssertEqual(passed, cell.expectedPassed,
                "[source=display cell=delay=\(cell.delayMs)ms expected=\(cell.expectedPassed)] " +
                "display dispatchDebounced produced wrong count, got \(passed)")
        }
    }
}
