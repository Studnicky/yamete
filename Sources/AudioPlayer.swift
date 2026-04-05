import AppKit
import Foundation

private let log = AppLog(category: "AudioPlayer")

/// Plays impact sounds on selected output devices.
/// Sound files are loaded from the `sounds` resource folder at startup,
/// sorted by duration, and cached for intensity-based selection.
@MainActor
final class AudioPlayer: AudioResponder {
    private struct SoundFile {
        let url: URL
        let duration: Double
    }

    /// Pre-sorted by duration (shortest first). Cached at startup.
    private var soundFiles: [SoundFile] = []
    private var recentlyPlayed: [URL] = []
    private let historySize = 2

    /// URL and duration of the longest loaded sound (last in sorted cache).
    var longestSoundURL: URL? { soundFiles.last?.url }

    init() { preload() }

    /// Plays a sound scaled to intensity on the specified device.
    /// Returns the clip duration (0 if nothing played).
    /// - Parameter deviceUIDs: Core Audio device UIDs. Empty = system default.
    @discardableResult
    func play(intensity: Float, volumeMin: Float, volumeMax: Float, deviceUIDs: [String] = []) -> Double {
        guard let sound = selectSound(intensity: intensity) else {
            log.warning("activity:Playback wasInvalidatedBy entity:EmptySoundPool")
            return 0
        }

        recentlyPlayed.append(sound.url)
        if recentlyPlayed.count > historySize { recentlyPlayed.removeFirst() }

        let volume = volumeMin + intensity * (volumeMax - volumeMin)

        if deviceUIDs.isEmpty {
            guard let s = NSSound(contentsOf: sound.url, byReference: true) else {
                log.error("entity:AudioPlayer wasInvalidatedBy activity:PlayerCreation file=\(sound.url.lastPathComponent)")
                return 0
            }
            s.volume = volume
            s.play()
        } else {
            for uid in deviceUIDs {
                if let s = NSSound(contentsOf: sound.url, byReference: true) {
                    s.playbackDeviceIdentifier = uid
                    s.volume = volume
                    s.play()
                }
            }
        }

        log.debug("activity:Playback used entity:SoundClip file=\(sound.url.lastPathComponent) volume=\(String(format: "%.2f", volume)) devices=\(deviceUIDs.isEmpty ? "default" : "\(deviceUIDs.count)")")
        return sound.duration
    }

    /// Plays a sound on ALL output devices simultaneously at the given volume.
    func playOnAllDevices(url: URL, volume: Float) {
        let devices = AudioDeviceManager.outputDevices()
        if devices.isEmpty {
            // No enumerable devices — play on default
            if let s = NSSound(contentsOf: url, byReference: true) {
                s.volume = volume
                s.play()
            }
            return
        }
        for device in devices {
            if let s = NSSound(contentsOf: url, byReference: true) {
                s.playbackDeviceIdentifier = device.uid
                s.volume = volume
                s.play()
            }
        }
        log.info("activity:Playback used entity:SoundClip file=\(url.lastPathComponent) devices=\(devices.count) volume=\(String(format: "%.2f", volume))")
    }

    // MARK: - Private

    private func selectSound(intensity: Float) -> SoundFile? {
        let available = soundFiles.filter { !recentlyPlayed.contains($0.url) }
        let pool = available.isEmpty ? soundFiles : available
        guard !pool.isEmpty else { return nil }

        // Pool preserves duration order from the pre-sorted cache.
        let idealIdx = Int((intensity * Float(pool.count - 1)).rounded())
        let half = max(1, pool.count / 8)
        let lo = max(0, idealIdx - half)
        let hi = min(pool.count - 1, idealIdx + half)

        return pool[Int.random(in: lo...hi)]
    }

    private func preload() {
        let urls = BundleResources.urls(in: "sounds", extensions: ["mp3", "wav", "m4a", "aac"])

        for url in urls {
            if let s = NSSound(contentsOf: url, byReference: true) {
                soundFiles.append(SoundFile(url: url, duration: s.duration))
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
