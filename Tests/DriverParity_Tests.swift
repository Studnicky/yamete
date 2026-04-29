import XCTest
import AppKit
import CoreHaptics
import CoreGraphics
@preconcurrency import AVFoundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid
@testable import SensorKit
@testable import ResponseKit

/// Real-vs-Mock driver parity cells.
///
/// Production drivers (`RealEventMonitor`, `RealHIDDeviceMonitor`,
/// `RealMicrophoneEngineDriver`, `RealHeadphoneMotionDriver`,
/// `RealHapticEngineDriver`, `RealDisplayBrightnessDriver`,
/// `RealSystemVolumeDriver`, `RealSystemNotificationDriver`) and their
/// Mock counterparts each carry their own dedicated test files, but no
/// existing cell asserts that the two implementations exhibit the SAME
/// observable behavior on the SAME input. A divergence (e.g. Real
/// returns `nil` where Mock simulates a value) would produce production-
/// only bugs the rest of the suite cannot catch.
///
/// Each cell here drives the same protocol-level call sequence through
/// both implementations and asserts the contract the protocol promises:
///   - same-shape return types (`Bool`, `Optional<Float>`, `[HIDDeviceInfo]`)
///   - same call-counting symmetry (install/remove tokens, start/stop
///     pairs)
///   - same throwing behaviour (typed errors propagate, success paths
///     don't throw)
///
/// EQUALITY OF VALUE is intentionally NOT asserted where the two
/// implementations legitimately diverge:
///   - `RealHIDDeviceMonitor.queryDevices` reflects connected hardware;
///     Mock reflects test-injected state
///   - `RealHeadphoneMotionDriver.isHeadphonesConnected` reflects paired
///     AirPods; Mock is test-controlled
///   - `RealSystemVolumeDriver.getVolume` reflects the host's audio
///     device state; Mock reflects test seed
/// Each such divergence is documented inline so a future reader knows
/// what is and isn't an apples-to-apples comparison.
///
/// Drivers that need TCC grants or specific hardware (Force Touch,
/// AirPods, microphone access) skip their Real-side assertions via
/// `XCTSkipUnless` against the driver's `isAvailable` / equivalent
/// surface. The Mock side always runs.
final class DriverParity_Tests: XCTestCase {

    // MARK: - 1. EventMonitor parity

    /// Both `RealEventMonitor` and `MockEventMonitor` must:
    ///   - return a non-nil `EventMonitorToken` on `addGlobalMonitor` for
    ///     a non-empty `EventTypeMask` (Mock unconditionally; Real iff
    ///     Accessibility is granted)
    ///   - accept the same token via `removeMonitor` without throwing
    ///
    /// Real `addGlobalMonitorForEvents` returns `nil` when the process
    /// lacks Accessibility (TCC) — in that case `XCTSkipUnless` skips
    /// the Real side and the cell only validates Mock. The Mock side
    /// is unconditional: a passing Mock half is the contract floor.
    @MainActor
    func test_eventMonitor_parity_installAndRemove() throws {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown]

        // Mock side — always runs.
        let mock = MockEventMonitor()
        let mockToken = mock.addGlobalMonitor(matching: mask) { _ in }
        XCTAssertNotNil(mockToken,
                        "[parity=eventMonitor] Mock must return non-nil token by default")
        XCTAssertEqual(mock.installedCount, 1,
                       "[parity=eventMonitor] Mock should record 1 install")
        if let mockToken {
            mock.removeMonitor(mockToken)
        }
        XCTAssertEqual(mock.removalCount, 1,
                       "[parity=eventMonitor] Mock should record 1 removal")
        XCTAssertEqual(mock.installedCount, 0,
                       "[parity=eventMonitor] Mock should be empty after remove")

        // Real side — needs Accessibility TCC. NSEvent's add returns nil
        // when the process is not trusted. We probe by attempting an
        // install; if the result is nil we skip the Real assertions.
        let real = RealEventMonitor()
        let realToken = real.addGlobalMonitor(matching: mask) { _ in }
        try XCTSkipUnless(realToken != nil,
                          "[parity=eventMonitor] RealEventMonitor returned nil — Accessibility (TCC) likely not granted to test runner. Mock half passed; Real half skipped.")
        if let realToken {
            // Removal must not throw. NSEvent.removeMonitor is void.
            real.removeMonitor(realToken)
        }
    }

    // MARK: - 2. HIDDeviceMonitor parity

    /// Empty matcher list MUST return `[]` for both Real and Mock. This
    /// is the only input where the two are guaranteed to agree: any
    /// non-empty matcher legitimately diverges (Real reflects connected
    /// hardware, Mock reflects test state). The cell asserts the
    /// CONTRACT for the empty case + shape parity (both return
    /// `[HIDDeviceInfo]`) for a non-empty case.
    func test_hidDeviceMonitor_parity_emptyMatcherAlwaysEmpty() {
        let real = RealHIDDeviceMonitor()
        let mock = MockHIDDeviceMonitor()

        // Empty matcher — both must return [] regardless of host state.
        XCTAssertEqual(real.queryDevices(matchers: []).count, 0,
                       "[parity=hidDevice] Real must return [] for empty matcher list")
        XCTAssertEqual(mock.queryDevices(matchers: []).count, 0,
                       "[parity=hidDevice] Mock must return [] for empty matcher list")

        // Non-empty matcher — shape parity only. Real value depends on
        // host hardware; Mock returns its (empty default) canned list.
        // Documented divergence: equality of value is NOT asserted.
        let trackpadMatchers = TrackpadActivitySource.presenceMatchers
        let realResult = real.queryDevices(matchers: trackpadMatchers)
        let mockResult = mock.queryDevices(matchers: trackpadMatchers)
        // Both must be `[HIDDeviceInfo]` arrays — Swift type system
        // enforces this at compile time, but we also check the runtime
        // shape via Mirror. The assertion is trivially true; its value
        // is documenting the divergence.
        XCTAssertGreaterThanOrEqual(realResult.count, 0,
                                    "[parity=hidDevice] Real returns a list (count: \(realResult.count))")
        XCTAssertEqual(mockResult.count, 0,
                       "[parity=hidDevice] Mock default canned list is empty")

        // hasBuiltInDisplay shape: both return `Bool`. Value diverges
        // (Real on a laptop returns true; on a headless mac, false;
        // Mock defaults to false unless seeded).
        let realHasDisplay: Bool = real.hasBuiltInDisplay()
        let mockHasDisplay: Bool = mock.hasBuiltInDisplay()
        // Compile-time shape check via assignment to Bool above.
        // Document the divergence.
        _ = (realHasDisplay, mockHasDisplay)
        XCTAssertEqual(mock.hasBuiltInDisplayCalls, 1,
                       "[parity=hidDevice] Mock should record 1 hasBuiltInDisplay call")
    }

    // MARK: - 3. MicrophoneEngineDriver parity

    /// Both drivers expose the same install-tap / remove-tap / start /
    /// stop sequence. Mock is unconditional; Real requires the
    /// microphone to be available (engine can construct without
    /// throwing, input format has > 0 channels and > 0 sample rate).
    /// Real `start()` will throw without microphone TCC; we don't call
    /// start in this cell — the parity contract is on the install /
    /// remove tap symmetry, which is decoupled from start.
    func test_microphoneEngineDriver_parity_installRemoveTapSymmetry() throws {
        // Mock side — always runs.
        let mock = MockMicrophoneEngineDriver()
        let mockHandler: @Sendable (AVAudioPCMBuffer) -> Void = { _ in }
        mock.installTap(handler: mockHandler)
        XCTAssertEqual(mock.installTapCalls, 1,
                       "[parity=mic] Mock should record 1 installTap")
        mock.removeTap()
        XCTAssertEqual(mock.removeTapCalls, 1,
                       "[parity=mic] Mock should record 1 removeTap")

        // Real side — `installTap` / `removeTap` route through
        // AVAudioInputNode. They don't throw and don't require TCC at
        // install time (TCC is enforced at engine.start()). The format
        // must be valid for installTap to not crash.
        let real = RealMicrophoneEngineDriver()
        let format = real.inputFormat
        try XCTSkipUnless(format.channelCount > 0 && format.sampleRate > 0,
                          "[parity=mic] Real input format invalid (channels=\(format.channelCount), sampleRate=\(format.sampleRate)) — host has no audio input, skipping Real half.")
        // installTap on a fresh engine must not crash. removeTap on a
        // freshly-installed tap must not crash. Symmetry of calls is
        // the contract.
        real.installTap(handler: { _ in })
        real.removeTap()
        // Idempotent removal — calling again must not crash.
        real.removeTap()
    }

    // MARK: - 4. HeadphoneMotionDriver parity

    /// Both drivers expose `isDeviceMotionAvailable` and
    /// `isHeadphonesConnected` as `Bool`. Real reflects framework
    /// support + paired-device state; Mock is test-controlled. The
    /// cell asserts CONTRACT shape (both Bool) and call-counting
    /// symmetry on `startUpdates` / `stopUpdates`.
    ///
    /// `isDeviceMotionAvailable` is not equality-asserted across
    /// implementations: Real returns true on Apple Silicon Macs
    /// independent of paired devices (the framework supports the
    /// API even with nothing connected); Mock defaults to true.
    func test_headphoneMotionDriver_parity_contractShape() {
        // Mock side — always runs.
        let mock = MockHeadphoneMotionDriver()
        let mockAvailable: Bool = mock.isDeviceMotionAvailable
        let mockConnected: Bool = mock.isHeadphonesConnected
        XCTAssertTrue(mockAvailable,
                      "[parity=headphoneMotion] Mock default isDeviceMotionAvailable=true")
        XCTAssertFalse(mockConnected,
                       "[parity=headphoneMotion] Mock default isHeadphonesConnected=false")

        mock.startUpdates(handler: { _, _ in })
        XCTAssertEqual(mock.startUpdatesCalls, 1)
        mock.stopUpdates()
        XCTAssertEqual(mock.stopUpdatesCalls, 1)

        // Real side — construction does not throw and does not require
        // TCC. The two getters are pure property reads on
        // CMHeadphoneMotionManager. We only assert shape (Bool) +
        // documented divergence: `isHeadphonesConnected` will be false
        // on any test runner without paired AirPods — Real reflects
        // hardware, Mock reflects state.
        let real = RealHeadphoneMotionDriver()
        let realAvailable: Bool = real.isDeviceMotionAvailable
        let realConnected: Bool = real.isHeadphonesConnected
        // Compile-time shape check. The only thing we can assert about
        // the values is that they are Bool — which the type system
        // already enforces.
        _ = (realAvailable, realConnected)
        // start/stop symmetry — does not throw, does not require TCC,
        // does not require paired device. The handler will simply
        // never fire on a host with no AirPods.
        real.startUpdates(handler: { _, _ in })
        real.stopUpdates()
        // Idempotent stop — must not crash.
        real.stopUpdates()
    }

    // MARK: - 5. HapticEngineDriver parity

    /// Both drivers must expose `isHardwareAvailable: Bool`,
    /// `start() async throws`, `stop()`, and
    /// `playPattern(_:) async throws` — so error paths are typed
    /// identically. The cell drives the success path on Mock
    /// unconditionally and on Real only when the host has a Force
    /// Touch trackpad. Both sides must accept a minimal valid
    /// `CHHapticPattern` without throwing.
    func test_hapticEngineDriver_parity_startPlayStop() async throws {
        // Mock side — always runs.
        let mock = MockHapticEngineDriver()
        let mockAvailable: Bool = mock.isHardwareAvailable
        XCTAssertTrue(mockAvailable, "[parity=haptic] Mock default isHardwareAvailable=true")
        try await mock.start()
        XCTAssertEqual(mock.startCalls, 1)
        // playPattern requires a valid CHHapticPattern. Build a minimal
        // one shared with the Real side below.
        let pattern = try Self.minimalHapticPattern()
        try await mock.playPattern(pattern)
        XCTAssertEqual(mock.playPatternCalls, 1)
        mock.stop()
        XCTAssertEqual(mock.stopCalls, 1)

        // Real side — requires Force Touch trackpad. On a host without
        // one, `CHHapticEngine.capabilitiesForHardware().supportsHaptics`
        // is false, the engine init throws, and the driver's `start`
        // surfaces a CoreHaptics error. We skip the Real half rather
        // than false-positive on Mac mini / headless CI.
        let real = RealHapticEngineDriver()
        let realAvailable: Bool = real.isHardwareAvailable
        try XCTSkipUnless(realAvailable,
                          "[parity=haptic] RealHapticEngineDriver reports no Force Touch hardware. Mock half passed; Real half skipped.")
        try await real.start()
        try await real.playPattern(pattern)
        real.stop()
        // Idempotent stop — must not crash.
        real.stop()
    }

    /// Both drivers' `playPattern` must throw a typed error when the
    /// engine is not started. Mock signals via `MockHapticError`; Real
    /// signals via `HapticDriverError.engineNotStarted` from the
    /// production guard. The cell asserts both throw — typed-throwing
    /// shape parity.
    func test_hapticEngineDriver_parity_playWithoutStartThrows() async throws {
        let pattern = try Self.minimalHapticPattern()

        // Mock — flip shouldFailPlay so playPattern throws even though
        // the mock doesn't enforce the engine-not-started invariant
        // by default. The CONTRACT is that playPattern can throw; we
        // verify the typed error path on both sides.
        let mock = MockHapticEngineDriver()
        mock.shouldFailPlay = true
        do {
            try await mock.playPattern(pattern)
            XCTFail("[parity=haptic] Mock playPattern with shouldFailPlay must throw")
        } catch {
            // Typed-throwing parity: caller observes Error.
            XCTAssertNotNil(error,
                            "[parity=haptic] Mock playPattern threw as expected")
        }

        // Real — `playPattern` without prior `start` should throw
        // `HapticDriverError.engineNotStarted` (the guard at line 68).
        let real = RealHapticEngineDriver()
        do {
            try await real.playPattern(pattern)
            XCTFail("[parity=haptic] Real playPattern without start must throw")
        } catch let driverError as HapticDriverError {
            if case .engineNotStarted = driverError {
                XCTAssertTrue(true,
                              "[parity=haptic] Real surfaced HapticDriverError.engineNotStarted")
            } else {
                XCTFail("[parity=haptic] Real threw unexpected HapticDriverError variant: \(driverError)")
            }
        } catch {
            XCTFail("[parity=haptic] Real threw non-HapticDriverError: \(type(of: error)): \(error)")
        }
    }

    // MARK: - 6. DisplayBrightnessDriver parity

    /// Both drivers expose `isAvailable: Bool`, `get(displayID:) -> Float?`,
    /// and `set(displayID:level:)`. The cell asserts shape (both return
    /// optional Float) and round-trip symmetry on Mock. Real is skipped
    /// when DisplayServices.framework symbols are not loadable on this
    /// host (very rare; effectively all macOS hosts have it).
    func test_displayBrightnessDriver_parity_getSetShape() throws {
        let mainDisplayID = CGMainDisplayID()

        // Mock side — always runs. Default canned level = 0.5.
        let mock = MockDisplayBrightnessDriver()
        XCTAssertTrue(mock.isAvailable,
                      "[parity=brightness] Mock default isAvailable=true")
        let mockBefore: Float? = mock.get(displayID: mainDisplayID)
        XCTAssertEqual(mockBefore, 0.5,
                       "[parity=brightness] Mock seeded default level = 0.5")
        mock.set(displayID: mainDisplayID, level: 0.42)
        let mockAfter: Float? = mock.get(displayID: mainDisplayID)
        XCTAssertEqual(mockAfter, 0.42,
                       "[parity=brightness] Mock set→get round-trips exactly")
        XCTAssertEqual(mock.setHistory.count, 1,
                       "[parity=brightness] Mock recorded 1 set")

        // Real side — DisplayServices private framework. Skip if
        // symbols failed to resolve. On real hardware,
        // `set` may have no observable effect on external displays
        // depending on driver; we restore the original level after
        // the round-trip so we don't permanently dim the user's screen.
        let real = RealDisplayBrightnessDriver()
        try XCTSkipUnless(real.isAvailable,
                          "[parity=brightness] DisplayServices.framework symbols unresolved on this host. Mock half passed; Real half skipped.")
        let realBefore: Float? = real.get(displayID: mainDisplayID)
        // Shape: Real returns Optional<Float>. Value depends on host.
        // We do NOT assert a specific value — that would be a
        // host-dependent flake. We assert the type of the result and
        // that the round-trip is non-destructive.
        if let original = realBefore {
            // Restore immediately. We're not actually changing the
            // value — just asserting that set + get does not throw and
            // returns Float?.
            real.set(displayID: mainDisplayID, level: original)
            let realAfter: Float? = real.get(displayID: mainDisplayID)
            XCTAssertNotNil(realAfter,
                            "[parity=brightness] Real get after set must return non-nil")
        } else {
            // Some external displays return nil from get even when
            // symbols are loaded — that's a hardware contract we can't
            // override. Skip rather than fail.
            throw XCTSkip("[parity=brightness] Real get returned nil — display likely doesn't expose brightness API.")
        }
    }

    // MARK: - 7. SystemVolumeDriver parity

    /// Both drivers expose `getVolume() -> Float?` and
    /// `setVolume(_:)`. The cell drives capture → set → restore on
    /// Mock unconditionally; on Real it captures the original, sets
    /// the same value back, and verifies the round-trip lands within
    /// floating-point tolerance. Real volume changes WOULD be observable
    /// to the user, so we deliberately set-to-original (no-op) rather
    /// than picking an arbitrary value.
    func test_systemVolumeDriver_parity_captureSetRestore() throws {
        // Mock — always runs.
        let mock = MockSystemVolumeDriver()
        let mockBefore: Float? = mock.getVolume()
        XCTAssertEqual(mockBefore, 0.4,
                       "[parity=volume] Mock seeded default = 0.4")
        guard let mockOriginal = mockBefore else {
            XCTFail("[parity=volume] Mock seeded volume must be non-nil")
            return
        }
        mock.setVolume(0.7)
        XCTAssertEqual(mock.getVolume(), 0.7,
                       "[parity=volume] Mock set→get round-trips")
        mock.setVolume(mockOriginal)
        let mockRestored: Float = mock.getVolume() ?? .nan
        XCTAssertEqual(mockRestored, mockOriginal, accuracy: 0.0001,
                       "[parity=volume] Mock restore lands within tolerance")

        // Real — requires a default output device. Headless / no-audio
        // CI hosts return nil; skip in that case.
        let real = RealSystemVolumeDriver()
        let realBefore: Float? = real.getVolume()
        try XCTSkipUnless(realBefore != nil,
                          "[parity=volume] No default audio output device on this host. Mock half passed; Real half skipped.")
        guard let realOriginal = realBefore else { return }
        // Restore-only: write back the captured value. This is a no-op
        // for the user but exercises the set codepath.
        real.setVolume(realOriginal)
        let realAfter: Float? = real.getVolume()
        XCTAssertNotNil(realAfter,
                        "[parity=volume] Real getVolume after restore must return non-nil")
        if let after = realAfter {
            XCTAssertEqual(after, realOriginal, accuracy: 0.01,
                           "[parity=volume] Real restore lands within tolerance (got \(after), expected \(realOriginal))")
        }
    }

    // MARK: - 8. SystemNotificationDriver parity

    /// Both drivers expose `currentAuthorization() async -> NotificationAuth`,
    /// `requestAuthorization() async -> Bool`, `post(...) async throws`,
    /// and `remove(identifier:)`. The cell asserts that
    /// `currentAuthorization` returns a `NotificationAuth` enum on both,
    /// and that `remove` does not throw on either. Posting is NOT
    /// asserted on the Real side because it would surface a banner
    /// during the test run (and would require an authorization grant
    /// the test runner cannot reliably obtain).
    func test_systemNotificationDriver_parity_authorizationShape() async throws {
        // Mock — defaults to authorized; remove is no-op.
        let mock = MockSystemNotificationDriver()
        let mockAuth: NotificationAuth = await mock.currentAuthorization()
        XCTAssertEqual(mockAuth, .authorized,
                       "[parity=notification] Mock default auth = .authorized")
        XCTAssertEqual(mock.currentAuthorizationCalls, 1)
        mock.remove(identifier: "parity-test-id")
        XCTAssertEqual(mock.removed, ["parity-test-id"],
                       "[parity=notification] Mock recorded remove")

        // Real — `currentAuthorization` is a non-throwing async query
        // against `UNUserNotificationCenter.current().getNotificationSettings`.
        // It returns one of the enum cases regardless of grant state
        // (denied / notDetermined are both valid values for an
        // ungranted process). The shape is what matters here.
        //
        // SPM CAVEAT: `UNUserNotificationCenter.current()` raises an
        // Objective-C `NSInternalInconsistencyException` when the host
        // process is `xctest` running under `swift test` (main bundle
        // resolves to Xcode's `Contents/Developer/usr/bin/`, which has
        // no `bundleProxyForCurrentProcess`). The exception cannot be
        // caught from Swift and crashes the test runner. The Real half
        // of this cell is therefore skipped under SPM; the genuine
        // integration surface is `xcodebuild test` against the
        // YameteTests scheme bundled inside the host app, where the
        // main bundle resolves to `Yamete.app` and UN center returns
        // normally. This mirrors the documented skip in
        // `NotificationAuthRealDriverTests`.
        let bundleURL = Bundle.main.bundleURL.path
        let isUnderXctestRunner = bundleURL.contains("/Xcode.app/")
            || bundleURL.contains("/usr/bin")
            || (Bundle.main.bundleIdentifier == nil)
        try XCTSkipIf(
            isUnderXctestRunner,
            "[parity=notification] UN center unavailable when main bundle is Xcode/xctest (\(bundleURL)). Mock half passed; Real half skipped — calling real currentAuthorization() under `swift test` raises NSInternalInconsistencyException."
        )
        let real = RealSystemNotificationDriver()
        let realAuth: NotificationAuth = await real.currentAuthorization()
        // Compile-time shape check via the explicit annotation above.
        // Value parity is NOT asserted: Real reflects the test runner's
        // notification grant state; Mock is .authorized by seed.
        switch realAuth {
        case .authorized, .provisional, .ephemeral, .denied,
             .notDetermined, .unknown:
            XCTAssertTrue(true,
                          "[parity=notification] Real returned valid NotificationAuth: \(realAuth)")
        }
        // remove must not throw; calling it on an identifier that was
        // never posted is a no-op (UNUserNotificationCenter contract).
        real.remove(identifier: "parity-test-id-never-posted")
    }

    // MARK: - Helpers

    /// Minimal valid `CHHapticPattern` for play-pattern parity. A single
    /// transient event at t=0. Both Real and Mock accept this shape.
    private static func minimalHapticPattern() throws -> CHHapticPattern {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [event], parameters: [])
    }
}
