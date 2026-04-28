#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
import Foundation

private let log = AppLog(category: "AudioPlayer")

/// Plays impact sounds on selected output devices.
///
/// Hardware boundary: `AudioPlaybackDriver`. Default initializer wires a
/// `RealAudioPlaybackDriver` (NSSound). Tests inject a mock that records
/// every `play(url:deviceUID:volume:)` call.
@MainActor
public final class AudioPlayer {
    private struct SoundFile {
        let url: URL
        let duration: Double
    }

    /// Pre-sorted by duration (shortest first). Cached at startup.
    private var soundFiles: [SoundFile] = []
    private var recentlyPlayed: [URL] = []
    private let historySize = 2

    /// Reaction gating: track when current playback ends.
    private var playbackEndsAt: Date = .distantPast

    private let driver: AudioPlaybackDriver

    /// URL and duration of the longest loaded sound (last in sorted cache).
    public var longestSoundURL: URL? { soundFiles.last?.url }

    /// Selects a sound for enrichment: filters recently played, picks randomly within
    /// the intensity-based duration window. Does NOT mutate recentlyPlayed — the
    /// consume loop records it only when actually played (preserving original dedup behaviour).
    public func peekSound(intensity: Float, reaction: Reaction) -> (url: URL, duration: Double)? {
        let available = soundFiles.filter { !recentlyPlayed.contains($0.url) }
        let pool = available.isEmpty ? soundFiles : available
        guard !pool.isEmpty else { return nil }

        let idealIdx = Int((intensity * Float(pool.count - 1)).rounded())
        let half = max(1, pool.count / 8)
        let lo = max(0, idealIdx - half)
        let hi = min(pool.count - 1, idealIdx + half)
        let sound = pool[Int.random(in: lo...hi)]
        return (sound.url, sound.duration)
    }

    public convenience init() {
        self.init(driver: RealAudioPlaybackDriver())
    }

    public init(driver: AudioPlaybackDriver) {
        self.driver = driver
        preload()
    }

    /// Test seam: injects a synthetic sound library so unit tests can drive
    /// `peekSound` without bundled `.mp3` resources. The SPM test bundle has
    /// no `sounds/` directory, so the production `preload()` path leaves
    /// `soundFiles` empty — every `peekSound` returns nil and tests cannot
    /// distinguish "no sounds" from "kind-specific gating".
    public func _testInjectSoundLibrary(_ urls: [URL], duration: Double = 1.0) {
        soundFiles = urls.map { SoundFile(url: $0, duration: duration) }
        soundFiles.sort { $0.duration < $1.duration }
    }

    /// Test seam variant: injects a sound library with explicit per-clip
    /// durations so intensity-band selection tests can verify duration-based
    /// pool slicing.
    public func _testInjectSoundLibrary(_ entries: [(url: URL, duration: Double)]) {
        soundFiles = entries.map { SoundFile(url: $0.url, duration: $0.duration) }
        soundFiles.sort { $0.duration < $1.duration }
    }

    /// Test seam: returns the count of recently-played URLs so dedup tests
    /// can verify the sliding-window invariant.
    public var _testRecentlyPlayedCount: Int { recentlyPlayed.count }

    /// Test seam: drives one `peekSound` + commit cycle so dedup tests can
    /// simulate sequential plays without standing up a full bus consumer.
    /// Mirrors the production consume() commit: peek, then `recordPlayed`.
    public func _testPeekAndCommit(intensity: Float) -> URL? {
        guard let pick = peekSound(
            intensity: intensity,
            reaction: .impact(.init(timestamp: Date(), intensity: intensity, confidence: 1, sources: []))
        ) else { return nil }
        recordPlayed(pick.url)
        return pick.url
    }

    public func consume(from bus: ReactionBus, configProvider: OutputConfigProvider) async {
        let stream = await bus.subscribe()
        for await fired in stream {
            let config = configProvider.audioConfig()
            guard config.enabled, config.perReaction[fired.kind] != false else { continue }
            guard Date() >= playbackEndsAt else { continue }
            // Use the pre-selected URL from enrichment — no re-selection needed.
            guard let url = fired.soundURL else { continue }

            recordPlayed(url)

            if !config.deviceUIDs.isEmpty {
                let volume = config.volumeMin + fired.intensity * (config.volumeMax - config.volumeMin)
                for uid in config.deviceUIDs {
                    driver.play(url: url, deviceUID: uid, volume: volume)
                }
            }
            playbackEndsAt = Date().addingTimeInterval(fired.clipDuration)
        }
    }

    /// Plays a sound scaled to intensity on the specified device.
    /// Returns the clip duration (0 if nothing played).
    /// - Parameter deviceUIDs: Core Audio device UIDs. Empty = system default.
    @discardableResult
    public func play(intensity: Float, volumeMin: Float, volumeMax: Float, deviceUIDs: [String] = []) -> Double {
        guard let (url, duration) = peekSound(intensity: intensity, reaction: .impact(.init(timestamp: Date(), intensity: intensity, confidence: 1, sources: []))) else {
            log.warning("activity:Playback wasInvalidatedBy entity:EmptySoundPool")
            return 0
        }

        recordPlayed(url)

        guard !deviceUIDs.isEmpty else { return 0 }

        let volume = volumeMin + intensity * (volumeMax - volumeMin)

        for uid in deviceUIDs {
            driver.play(url: url, deviceUID: uid, volume: volume)
        }

        log.debug("activity:Playback used entity:SoundClip file=\(url.lastPathComponent) volume=\(String(format: "%.2f", volume)) devices=\(deviceUIDs.count)")
        return duration
    }

    /// Plays a sound on ALL output devices simultaneously at the given volume.
    public func playOnAllDevices(url: URL, volume: Float) {
        let devices = AudioDeviceManager.outputDevices()
        if devices.isEmpty {
            // No enumerable devices — play on default
            driver.play(url: url, deviceUID: nil, volume: volume)
            return
        }
        for device in devices {
            driver.play(url: url, deviceUID: device.uid, volume: volume)
        }
        log.info("activity:Playback used entity:SoundClip file=\(url.lastPathComponent) devices=\(devices.count) volume=\(String(format: "%.2f", volume))")
    }

    // MARK: - Private

    private func recordPlayed(_ url: URL) {
        recentlyPlayed.append(url)
        if recentlyPlayed.count > historySize { recentlyPlayed.removeFirst() }
    }

    private func preload() {
        let urls = BundleResources.urls(in: "sounds", extensions: ["mp3", "wav", "m4a", "aac"])

        for url in urls {
            if let duration = driver.loadDuration(url: url) {
                soundFiles.append(SoundFile(url: url, duration: duration))
            } else {
                log.error("entity:SoundClip wasInvalidatedBy activity:Preload file=\(url.lastPathComponent)")
            }
        }

        soundFiles.sort { $0.duration < $1.duration }

        if soundFiles.isEmpty {
            log.error("entity:SoundLibrary wasInvalidatedBy activity:Preload — no sound files in bundle/sounds")
        } else {
            log.info("entity:SoundLibrary wasGeneratedBy activity:Preload count=\(soundFiles.count) shortest=\(String(format: "%.2f", soundFiles.first?.duration ?? 0))s longest=\(String(format: "%.2f", soundFiles.last?.duration ?? 0))s")
        }
    }
}
