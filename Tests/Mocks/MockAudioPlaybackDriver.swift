import Foundation
import os
@testable import ResponseKit

/// Test double for `AudioPlaybackDriver`. Records every play call.
/// Defaults: every URL "loads" with a 1.0 second duration; tests can
/// inject specific durations or `nil` to drive the missing-clip path.
@MainActor
final class MockAudioPlaybackDriver: AudioPlaybackDriver {
    struct PlayRecord: Sendable, Equatable {
        let url: URL
        let deviceUID: String?
        let volume: Float
    }

    var defaultDuration: Double? = 1.0
    var perURLDuration: [URL: Double?] = [:]
    var playHistory: [PlayRecord] = []
    var stopCalls: Int = 0

    func loadDuration(url: URL) -> Double? {
        if let override = perURLDuration[url] { return override }
        return defaultDuration
    }

    @discardableResult
    func play(url: URL, deviceUID: String?, volume: Float) -> Double {
        playHistory.append(PlayRecord(url: url, deviceUID: deviceUID, volume: volume))
        return loadDuration(url: url) ?? 0
    }

    func stop() {
        stopCalls += 1
    }
}
