import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Behavioural cells for `AudioPlayer.consume`'s `activeOutputOnly`
/// branch. The flag mirrors `FlashOutputConfig.activeDisplayOnly`:
/// when on, the player must ignore the per-device list and route to
/// the system default audio output (passing `nil` to the driver).
@MainActor
final class AudioPlayerActiveOutput_Tests: XCTestCase {

    /// Active-output-only ON + populated deviceUIDs → driver receives
    /// exactly one play with `deviceUID == nil`. The configured device
    /// list is intentionally ignored.
    func testActiveOutputOnly_routesToDefaultIgnoringDeviceUIDs() async throws {
        let driver = MockAudioPlaybackDriver()
        let player = AudioPlayer(driver: driver)
        let url = URL(fileURLWithPath: "/tmp/yamete-active-output-on.mp3")
        player._testInjectSoundLibrary([url], duration: 0.05)

        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 0.05,
                          soundURL: url, faceIndices: [0], publishedAt: publishedAt)
        }
        let provider = MockConfigProvider()
        provider.audio.activeOutputOnly = true
        provider.audio.deviceUIDs = ["device-A", "device-B", "device-C"]

        let task = Task { await player.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        let impact = Reaction.impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1, sources: []))
        await bus.publish(impact)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(driver.playHistory.count, 1,
            "[audio=activeOutputOnly-on count] expected exactly one play call when activeOutputOnly is set, got \(driver.playHistory.count)")
        XCTAssertNil(driver.playHistory.first?.deviceUID,
            "[audio=activeOutputOnly-on uid] expected deviceUID=nil (system default routing), got \(String(describing: driver.playHistory.first?.deviceUID))")
    }

    /// Active-output-only OFF + populated deviceUIDs → driver receives
    /// one play per UID, each with the matching deviceUID set. This
    /// pins the existing fan-out behaviour as a regression guard.
    func testActiveOutputOnly_off_fansOutToEachDeviceUID() async throws {
        let driver = MockAudioPlaybackDriver()
        let player = AudioPlayer(driver: driver)
        let url = URL(fileURLWithPath: "/tmp/yamete-active-output-off.mp3")
        player._testInjectSoundLibrary([url], duration: 0.05)

        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 0.05,
                          soundURL: url, faceIndices: [0], publishedAt: publishedAt)
        }
        let provider = MockConfigProvider()
        provider.audio.activeOutputOnly = false
        provider.audio.deviceUIDs = ["device-A", "device-B", "device-C"]

        let task = Task { await player.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        let impact = Reaction.impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1, sources: []))
        await bus.publish(impact)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(driver.playHistory.count, 3,
            "[audio=activeOutputOnly-off count] expected one play per configured device, got \(driver.playHistory.count)")
        let observedUIDs = driver.playHistory.compactMap { $0.deviceUID }.sorted()
        XCTAssertEqual(observedUIDs, ["device-A", "device-B", "device-C"],
            "[audio=activeOutputOnly-off uids] each configured deviceUID must receive its own play call (got \(observedUIDs))")
    }

    /// Active-output-only ON + EMPTY deviceUIDs → driver still receives
    /// one play with nil UID. The flag overrides device routing
    /// independently of whether the user has any per-device toggles
    /// enabled, matching the user mental model of "always route to
    /// the system default."
    func testActiveOutputOnly_emptyDeviceUIDs_stillRoutesToDefault() async throws {
        let driver = MockAudioPlaybackDriver()
        let player = AudioPlayer(driver: driver)
        let url = URL(fileURLWithPath: "/tmp/yamete-active-output-empty.mp3")
        player._testInjectSoundLibrary([url], duration: 0.05)

        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 0.05,
                          soundURL: url, faceIndices: [0], publishedAt: publishedAt)
        }
        let provider = MockConfigProvider()
        provider.audio.activeOutputOnly = true
        provider.audio.deviceUIDs = []

        let task = Task { await player.consume(from: bus, configProvider: provider) }
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(10))
        let impact = Reaction.impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1, sources: []))
        await bus.publish(impact)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(driver.playHistory.count, 1,
            "[audio=activeOutputOnly-empty count] activeOutputOnly must route even when deviceUIDs is empty (got \(driver.playHistory.count))")
        XCTAssertNil(driver.playHistory.first?.deviceUID,
            "[audio=activeOutputOnly-empty uid] route must still be system default")
    }
}
