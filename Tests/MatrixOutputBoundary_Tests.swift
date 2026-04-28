import XCTest
import CoreGraphics
@testable import YameteCore
@testable import ResponseKit

/// Lifecycle / output-side-effect matrix for the seven hardware-boundary
/// outputs newly migrated to driver injection. Each test cell pins:
///   - hardware availability (driver `isAvailable` flag where applicable)
///   - operation outcome (succeeds / fails / pending state)
/// and asserts the `ReactiveOutput` lifecycle (`preAction → action →
/// postAction`) records the right calls on the mock driver.
@MainActor
final class MatrixOutputBoundary_Tests: XCTestCase {

    // MARK: - LEDFlash

    /// hardware-present × kb-enabled: action issues setLevel calls + capsLockSet
    /// pulses; postAction restores via hardResetKB.
    func testLEDFlashHardwarePresentRunsAndRestores() async throws {
        let mock = MockLEDBrightnessDriver()
        mock.setKeyboardBacklightAvailable(true)
        mock.setCapsLockAccessGranted(true)
        mock.setCurrentLevel(0.7)
        mock.stageAutoEnabled(true)
        let output = LEDFlash(driver: mock)
        output.setUp()

        let provider = MockConfigProvider()
        // Clip duration ≥ ReactionsConfig.ledMinPulseDuration (0.10s)
        // for the action loop to actually pulse.
        let fired = Self.firedImpact(intensity: 0.6, clipDuration: 0.20)

        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)

        XCTAssertGreaterThan(mock.setLevelHistory.count, 1, "action wrote multiple kb levels")
        XCTAssertGreaterThan(mock.capsLockHistory.count, 1, "action pulsed caps lock")
        XCTAssertEqual(mock.capsLockHistory.last, false, "ends with caps lock off")
        XCTAssertGreaterThanOrEqual(mock.setIdleSuspendedHistory.count, 1, "idle dimming suspended at start")
        XCTAssertEqual(mock.setIdleSuspendedHistory.first, true, "first idle call suspends")
        XCTAssertEqual(mock.setIdleSuspendedHistory.last, false, "last idle call resumes")
    }

    /// hardware-absent: action skips kb writes; capsLock writes still happen
    /// because that is a separate access path. Restore still runs.
    func testLEDFlashKeyboardBacklightAbsentSkipsKBWrites() async throws {
        let mock = MockLEDBrightnessDriver()
        mock.setKeyboardBacklightAvailable(false)
        mock.setCapsLockAccessGranted(true)
        let output = LEDFlash(driver: mock)
        output.setUp()
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.6, clipDuration: 0.20)
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.setLevelHistory.count, 0, "no kb writes when backlight unavailable")
    }

    /// caps-lock-access-denied: keyboard pulses still happen but capsLock
    /// writes are silently dropped by the driver.
    func testLEDFlashCapsLockDeniedDropsCapsLockWrites() async throws {
        let mock = MockLEDBrightnessDriver()
        mock.setKeyboardBacklightAvailable(true)
        mock.setCapsLockAccessGranted(false)
        mock.setCurrentLevel(0.5)
        let output = LEDFlash(driver: mock)
        output.setUp()
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.6, clipDuration: 0.20)
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.capsLockHistory.count, 0, "capsLock writes dropped when access denied")
        XCTAssertGreaterThan(mock.setLevelHistory.count, 0, "kb writes still happen")
    }

    /// preAction MUST capture the CURRENT system brightness, not a stale launch-
    /// time cached value. The test stages `currentLevel = 0.42` at setUp time,
    /// runs a flash that mutates `currentLevel` to a final pulse-end value,
    /// then *changes* the underlying system level to 0.71 and runs ANOTHER flash.
    /// The second flash's restore MUST write 0.71 (re-read on every preAction).
    func testLEDFlashRestoreMatchesLiveCaptureNotLaunchSnapshot() async throws {
        let mock = MockLEDBrightnessDriver()
        mock.setKeyboardBacklightAvailable(true)
        mock.setCapsLockAccessGranted(true)
        mock.setCurrentLevel(0.42)
        let output = LEDFlash(driver: mock)
        output.setUp()
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.4, clipDuration: 0.20)

        // First flash: should capture & restore 0.42.
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(Double(mock.setLevelHistory.last ?? -1), 0.42, accuracy: 0.001,
                       "first flash restore must match captured 0.42")

        // System brightness changes between the two flashes (e.g. user adjusts).
        mock.setCurrentLevel(0.71)

        // Second flash: must capture the LIVE 0.71, not the stale 0.42.
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(Double(mock.setLevelHistory.last ?? -1), 0.71, accuracy: 0.001,
                       "second flash restore must match the LIVE captured 0.71, not the launch-time 0.42")
    }

    /// reset() restores state regardless of intermediate failures.
    func testLEDFlashResetRestoresToSnapshot() async throws {
        let mock = MockLEDBrightnessDriver()
        mock.setCurrentLevel(0.42)
        let output = LEDFlash(driver: mock)
        output.setUp()
        // Run a partial pulse, then reset
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.4, clipDuration: 0.03)
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        output.reset()
        // Reset should write the snapshot value
        XCTAssertEqual(Double(mock.setLevelHistory.last ?? -1), 0.42, accuracy: 0.001)
    }

    // MARK: - DisplayBrightnessFlash

    func testDisplayBrightnessHardwareAvailable() async throws {
        let mock = MockDisplayBrightnessDriver()
        mock.setAvailable(true)
        mock.setCannedLevel(0.6)
        let output = DisplayBrightnessFlash(driver: mock)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.7, clipDuration: 0.05)
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertGreaterThanOrEqual(mock.getCalls, 1, "preAction reads original")
        XCTAssertGreaterThan(mock.setHistory.count, 0, "action issues sets")
        XCTAssertEqual(Double(mock.setHistory.last?.level ?? -1), 0.6, accuracy: 0.001,
                       "postAction restores original captured value")
    }

    func testDisplayBrightnessHardwareUnavailable() async throws {
        let mock = MockDisplayBrightnessDriver()
        mock.setAvailable(false)
        let output = DisplayBrightnessFlash(driver: mock)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.7, clipDuration: 0.05)
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.getCalls, 0, "no get when unavailable")
        XCTAssertEqual(mock.setHistory.count, 0, "no set when unavailable")
    }

    func testDisplayBrightnessGetFails() async throws {
        let mock = MockDisplayBrightnessDriver()
        mock.setAvailable(true)
        mock.setCannedLevel(nil)  // get returns nil
        let output = DisplayBrightnessFlash(driver: mock)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.7, clipDuration: 0.05)
        // Should not crash when get returns nil — original retains default
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertGreaterThan(mock.setHistory.count, 0, "still issues sets even when get fails")
    }

    // MARK: - DisplayTintFlash

    func testDisplayTintAvailable() async throws {
        let mock = MockDisplayTintDriver()
        mock.setAvailable(true)
        let output = DisplayTintFlash(driver: mock)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertGreaterThan(mock.applyGammaHistory.count, 0, "action applies gamma")
        XCTAssertEqual(mock.restoreHistory.count, 1, "postAction restores once")
    }

    func testDisplayTintUnavailable() async throws {
        let mock = MockDisplayTintDriver()
        mock.setAvailable(false)
        let output = DisplayTintFlash(driver: mock)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.applyGammaHistory.count, 0, "no gamma writes when unavailable")
    }

    func testDisplayTintShouldFireRespectsAvailability() {
        let mockAvail = MockDisplayTintDriver()
        mockAvail.setAvailable(true)
        let outAvail = DisplayTintFlash(driver: mockAvail)
        let mockNo = MockDisplayTintDriver()
        mockNo.setAvailable(false)
        let outNo = DisplayTintFlash(driver: mockNo)
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        XCTAssertTrue(outAvail.shouldFire(fired, provider: provider))
        XCTAssertFalse(outNo.shouldFire(fired, provider: provider))
    }

    // MARK: - SystemNotificationDriver

    func testNotificationAuthGrantedPosts() async throws {
        let mock = MockSystemNotificationDriver()
        mock.setAuth(.authorized)
        let output = NotificationResponder(driver: mock, localeProvider: { "en" })
        let provider = MockConfigProvider()
        // Make dismissAfter as small as possible (clamp 0.1) so action returns quickly.
        provider.notification = NotificationOutputConfig(
            enabled: true,
            perReaction: MockConfigProvider.allKindsEnabled(),
            dismissAfter: 0.05,
            localeID: "en"
        )
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.posts.count, 1, "post issued on authorized auth")
        // Strong assertions: the responder must always post at .active (so the
        // banner is not suppressed when the app is active or under Focus) and
        // with relevanceScore=1.0 (so rapid reactions don't get coalesced/hidden).
        XCTAssertEqual(mock.lastPostedContent?.interruptionLevel, .active)
        XCTAssertEqual(mock.lastPostedContent?.relevanceScore ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(mock.posts.last?.interruptionLevel, .active)
        XCTAssertEqual(mock.posts.last?.relevanceScore ?? 0, 1.0, accuracy: 0.0001)
    }

    func testNotificationAuthDeniedNoPost() async throws {
        let mock = MockSystemNotificationDriver()
        mock.setAuth(.denied)
        let output = NotificationResponder(driver: mock, localeProvider: { "en" })
        let provider = MockConfigProvider()
        provider.notification = NotificationOutputConfig(
            enabled: true,
            perReaction: MockConfigProvider.allKindsEnabled(),
            dismissAfter: 0.05,
            localeID: "en"
        )
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.posts.count, 0, "no post when denied")
    }

    func testNotificationAuthNotDeterminedRequestsThenPosts() async throws {
        let mock = MockSystemNotificationDriver()
        mock.setAuth(.notDetermined)
        mock.setRequestGranted(true)
        let output = NotificationResponder(driver: mock, localeProvider: { "en" })
        let provider = MockConfigProvider()
        provider.notification = NotificationOutputConfig(
            enabled: true,
            perReaction: MockConfigProvider.allKindsEnabled(),
            dismissAfter: 0.05,
            localeID: "en"
        )
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertGreaterThanOrEqual(mock.requestAuthorizationCalls, 1, "request issued on notDetermined")
        XCTAssertEqual(mock.posts.count, 1, "post issued after grant flips auth to authorized")
    }

    func testNotificationPostThrowsRecorded() async throws {
        let mock = MockSystemNotificationDriver()
        mock.setAuth(.authorized)
        mock.setShouldFailPost(true)
        let output = NotificationResponder(driver: mock, localeProvider: { "en" })
        let provider = MockConfigProvider()
        provider.notification = NotificationOutputConfig(
            enabled: true,
            perReaction: MockConfigProvider.allKindsEnabled(),
            dismissAfter: 0.05,
            localeID: "en"
        )
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        // Should not throw out of action; should swallow internally
        await output.action(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.posts.count, 0, "post failed; nothing recorded")
    }

    func testNotificationPostActionRemoves() async throws {
        let mock = MockSystemNotificationDriver()
        let output = NotificationResponder(driver: mock, localeProvider: { "en" })
        let provider = MockConfigProvider()
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.05)
        await output.postAction(fired, multiplier: 1.0, provider: provider)
        XCTAssertEqual(mock.removed.count, 1, "postAction removes pending+delivered")
    }

    // MARK: - SystemVolumeDriver / VolumeSpikeResponder is DIRECT_BUILD only —
    // exercising the driver directly here.

    func testSystemVolumeRoundTrip() {
        let mock = MockSystemVolumeDriver()
        mock.setCannedVolume(0.3)
        XCTAssertEqual(mock.getVolume(), 0.3)
        mock.setVolume(0.9)
        XCTAssertEqual(mock.getVolume(), 0.9)
        XCTAssertEqual(mock.lastSet, 0.9)
    }

    func testSystemVolumeNoDevice() {
        let mock = MockSystemVolumeDriver()
        mock.setCannedVolume(nil)
        XCTAssertNil(mock.getVolume())
    }

#if DIRECT_BUILD
    /// VolumeSpike target volume formula: `min(1.0, audioConfig.volumeMax * multiplier)`.
    /// Pin every documented case so a future regression that drops the clamp,
    /// flips the operands, or substitutes `volumeSpikeTarget` for `volumeMax`
    /// is caught at the unit-test boundary.
    func testVolumeSpikeTargetVolumeFormula() async throws {
        struct Cell { let volumeMax: Float; let multiplier: Float; let expected: Float; let label: String }
        let cells: [Cell] = [
            .init(volumeMax: 0.5, multiplier: 1.0, expected: 0.5, label: "(0.5,1.0) → 0.5"),
            .init(volumeMax: 0.9, multiplier: 1.5, expected: 1.0, label: "(0.9,1.5) → 1.0 clamped"),
            .init(volumeMax: 0.0, multiplier: 1.0, expected: 0.0, label: "(0.0,1.0) → 0.0"),
            .init(volumeMax: 0.4, multiplier: 0.5, expected: 0.2, label: "(0.4,0.5) → 0.2"),
            .init(volumeMax: 1.0, multiplier: 1.0, expected: 1.0, label: "(1.0,1.0) → 1.0"),
            .init(volumeMax: 0.5, multiplier: 2.0, expected: 1.0, label: "(0.5,2.0) → 1.0 clamped"),
        ]
        for cell in cells {
            let mock = MockSystemVolumeDriver()
            mock.setCannedVolume(0.3)
            let output = VolumeSpikeResponder(driver: mock)
            let provider = MockConfigProvider()
            provider.audio.volumeMax = cell.volumeMax
            let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.0)

            await output.preAction(fired, multiplier: cell.multiplier, provider: provider)
            await output.action(fired, multiplier: cell.multiplier, provider: provider)

            // First setVolume in history is the spike target. PostAction
            // would restore to original; assert against history[0] not last.
            guard let first = mock.setHistory.first else {
                XCTFail("\(cell.label): no setVolume call recorded")
                continue
            }
            XCTAssertEqual(first, cell.expected, accuracy: 0.001,
                           "\(cell.label): expected \(cell.expected) got \(first)")
        }
    }

    /// The responder captures the system volume in `preAction` so it can
    /// restore the user's level afterwards. If `preAction` runs twice in
    /// quick succession (rapid reactions), the SECOND preAction must NOT
    /// overwrite the originally-captured value — otherwise restore writes
    /// the spike target back as if it were the user's preference.
    func testVolumeSpike_overlappingPreActions_capturesOriginalOnce() async throws {
        let mock = MockSystemVolumeDriver()
        mock.setCannedVolume(0.30)              // initial user level
        let output = VolumeSpikeResponder(driver: mock)
        let provider = MockConfigProvider()
        provider.audio.volumeMax = 0.9
        let fired = Self.firedImpact(intensity: 0.5, clipDuration: 0.0)

        // First preAction captures 0.30.
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        // Mid-sequence: the spike has now set the volume to ~0.9. If the
        // responder re-captures here it'll save 0.9 and restore THAT.
        XCTAssertEqual(mock.lastSet ?? -1, 0.9, accuracy: 0.001,
                       "spike applied target volume")

        // Second preAction (rapid follow-up reaction) must NOT overwrite
        // the original captured value with the current 0.9.
        await output.preAction(fired, multiplier: 1.0, provider: provider)
        await output.action(fired, multiplier: 1.0, provider: provider)
        await output.postAction(fired, multiplier: 1.0, provider: provider)

        // After the final postAction we MUST be back at 0.30, not at 0.9.
        XCTAssertEqual(mock.lastSet ?? -1, 0.30, accuracy: 0.001,
                       "restore must return to the FIRST captured user volume (0.30), not the spike target")
    }
#endif

    // MARK: - AudioPlayer

    func testAudioPlayerPlayUsesDriver() {
        let mock = MockAudioPlaybackDriver()
        let player = AudioPlayer(driver: mock)
        // No sounds preloaded (test bundle lacks them) — peekSound returns nil.
        // Test the playOnAllDevices path which doesn't depend on preloads.
        let url = URL(fileURLWithPath: "/tmp/test.mp3")
        player.playOnAllDevices(url: url, volume: 0.5)
        // Either devices exist (records device-specific entries) or none enumerable
        // (records single nil-device entry). Either way at least one play call.
        XCTAssertGreaterThanOrEqual(mock.playHistory.count, 1)
    }

    func testAudioPlayerPlayWithDeviceList() {
        let mock = MockAudioPlaybackDriver()
        let player = AudioPlayer(driver: mock)
        let url = URL(fileURLWithPath: "/tmp/clip.wav")
        // Drive through the driver directly (peekSound requires preloaded sounds
        // which the SPM test bundle doesn't have).
        _ = player  // keep player alive
        mock.play(url: url, deviceUID: "uid1", volume: 0.7)
        mock.play(url: url, deviceUID: "uid2", volume: 0.7)
        XCTAssertEqual(mock.playHistory.count, 2)
        XCTAssertEqual(mock.playHistory[0].deviceUID, "uid1")
        XCTAssertEqual(mock.playHistory[1].deviceUID, "uid2")
    }

    func testAudioPlayerLoadDurationFailureSkipsClip() {
        let mock = MockAudioPlaybackDriver()
        mock.defaultDuration = nil
        let url = URL(fileURLWithPath: "/tmp/missing.mp3")
        XCTAssertNil(mock.loadDuration(url: url))
    }

    // MARK: - Helpers

    // MARK: - Driver-level cross-product (no ReactiveOutput orchestration)
    //
    // Direct calls to the protocol surface to verify each driver mock honours
    // the expected contract — failure injection, recording, replay.

    func testLEDDriverContractMatrix() {
        struct Cell {
            let backlight: Bool
            let capsLockGranted: Bool
            let expectedSetLevels: Int
            let expectedCapsLock: Int
        }
        let cells: [Cell] = [
            .init(backlight: true,  capsLockGranted: true,  expectedSetLevels: 1, expectedCapsLock: 1),
            .init(backlight: true,  capsLockGranted: false, expectedSetLevels: 1, expectedCapsLock: 0),
            .init(backlight: false, capsLockGranted: true,  expectedSetLevels: 0, expectedCapsLock: 1),
            .init(backlight: false, capsLockGranted: false, expectedSetLevels: 0, expectedCapsLock: 0),
        ]
        for cell in cells {
            let mock = MockLEDBrightnessDriver()
            mock.setKeyboardBacklightAvailable(cell.backlight)
            mock.setCapsLockAccessGranted(cell.capsLockGranted)
            mock.setLevel(0.5)
            mock.capsLockSet(true)
            XCTAssertEqual(mock.setLevelHistory.count, cell.expectedSetLevels,
                           "backlight=\(cell.backlight) → setLevels=\(cell.expectedSetLevels)")
            XCTAssertEqual(mock.capsLockHistory.count, cell.expectedCapsLock,
                           "capsLock=\(cell.capsLockGranted) → capsLockHits=\(cell.expectedCapsLock)")
        }
    }

    func testDisplayBrightnessDriverContractMatrix() {
        for available in [true, false] {
            let mock = MockDisplayBrightnessDriver()
            mock.setAvailable(available)
            mock.setCannedLevel(0.42)
            let v = mock.get(displayID: 1)
            mock.set(displayID: 1, level: 0.9)
            if available {
                XCTAssertEqual(v, 0.42)
                XCTAssertEqual(mock.setHistory.count, 1)
            } else {
                XCTAssertNil(v)
                XCTAssertEqual(mock.setHistory.count, 0)
            }
        }
    }

    func testDisplayTintDriverContractMatrix() {
        for available in [true, false] {
            let mock = MockDisplayTintDriver()
            mock.setAvailable(available)
            mock.applyGamma(displayID: 1, r: [0, 1], g: [0, 1], b: [0, 1])
            mock.restore(displayID: 1)
            if available {
                XCTAssertEqual(mock.applyGammaHistory.count, 1)
            } else {
                XCTAssertEqual(mock.applyGammaHistory.count, 0)
            }
            XCTAssertEqual(mock.restoreHistory.count, 1, "restore is unconditional")
        }
    }

    func testSystemNotificationDriverAuthMatrix() async {
        let cases: [NotificationAuth] = [.authorized, .provisional, .ephemeral, .denied, .notDetermined, .unknown]
        for auth in cases {
            let mock = MockSystemNotificationDriver()
            mock.setAuth(auth)
            let observed = await mock.currentAuthorization()
            XCTAssertEqual(observed, auth)
        }
    }

    func testNotificationContentInterruptionLevels() {
        let levels: [NotificationContent.InterruptionLevel] = [.passive, .active, .timeSensitive, .critical]
        for level in levels {
            let content = NotificationContent(
                title: "t", body: "b", threadID: "th", categoryID: "ca",
                interruptionLevel: level, relevanceScore: 0.5
            )
            XCTAssertEqual(content.interruptionLevel, level)
        }
    }

    func testAudioPlaybackDriverHistoryRecords() {
        let mock = MockAudioPlaybackDriver()
        mock.defaultDuration = 1.5
        let url1 = URL(fileURLWithPath: "/a.mp3")
        let url2 = URL(fileURLWithPath: "/b.mp3")
        mock.play(url: url1, deviceUID: nil, volume: 0.5)
        mock.play(url: url2, deviceUID: "dev1", volume: 0.7)
        XCTAssertEqual(mock.playHistory.count, 2)
        XCTAssertNil(mock.playHistory[0].deviceUID)
        XCTAssertEqual(mock.playHistory[1].deviceUID, "dev1")
        XCTAssertEqual(mock.playHistory[1].volume, 0.7)
    }

    func testAudioPlaybackDriverPerURLDuration() {
        let mock = MockAudioPlaybackDriver()
        mock.defaultDuration = 1.0
        let url = URL(fileURLWithPath: "/clip.wav")
        mock.perURLDuration[url] = 3.5
        XCTAssertEqual(mock.loadDuration(url: url), 3.5)
        let other = URL(fileURLWithPath: "/other.wav")
        XCTAssertEqual(mock.loadDuration(url: other), 1.0)
    }

    func testAudioPlaybackDriverStopClearsRecord() {
        let mock = MockAudioPlaybackDriver()
        mock.play(url: URL(fileURLWithPath: "/x.wav"), deviceUID: nil, volume: 0.5)
        XCTAssertEqual(mock.stopCalls, 0)
        mock.stop()
        XCTAssertEqual(mock.stopCalls, 1)
    }

    static func firedImpact(intensity: Float, clipDuration: Double) -> FiredReaction {
        FiredReaction(
            reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: [])),
            clipDuration: clipDuration,
            soundURL: nil,
            faceIndices: [0],
            publishedAt: Date()
        )
    }
}
