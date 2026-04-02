import AppKit
import Foundation

private let log = AppLog(category: "AudioPlayer")

/// Plays sound clips scaled by intensity, routable to a specific audio device.
/// Uses NSSound for its `playbackDeviceIdentifier` support.
final class AudioPlayer {
    private struct SoundFile {
        let url: URL
        let duration: Double
    }

    private var soundFiles: [SoundFile] = []
    private var recentlyPlayed: [URL] = []
    private let historySize = 2

    init() { preload() }

    /// Plays a sound scaled to intensity on the specified device.
    /// Returns the clip duration (0 if nothing played).
    /// - Parameter deviceUID: Core Audio device UID, or nil for system default.
    @discardableResult
    func play(intensity: Float, volumeMin: Float, volumeMax: Float, deviceUID: String? = nil) -> Double {
        guard let sound = selectSound(intensity: intensity) else {
            log.warning("activity:Playback wasInvalidatedBy entity:EmptySoundPool")
            return 0
        }

        recentlyPlayed.append(sound.url)
        if recentlyPlayed.count > historySize { recentlyPlayed.removeFirst() }

        let volume = volumeMin + intensity * (volumeMax - volumeMin)

        guard let nsSound = NSSound(contentsOf: sound.url, byReference: true) else {
            log.error("entity:AudioPlayer wasInvalidatedBy activity:PlayerCreation file=\(sound.url.lastPathComponent)")
            return 0
        }

        if let uid = deviceUID {
            nsSound.playbackDeviceIdentifier = uid
        }
        nsSound.volume = volume
        nsSound.play()

        log.debug("activity:Playback used entity:SoundClip file=\(sound.url.lastPathComponent) volume=\(String(format: "%.2f", volume)) device=\(deviceUID ?? "default")")
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

        let sorted = pool.sorted { $0.duration < $1.duration }
        let idealIdx = Int((intensity * Float(sorted.count - 1)).rounded())
        let half = max(1, sorted.count / 8)
        let lo = max(0, idealIdx - half)
        let hi = min(sorted.count - 1, idealIdx + half)

        return sorted[Int.random(in: lo...hi)]
    }

    private func preload() {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: resourcePath)) ?? []
        let urls = files
            .filter { $0.hasPrefix("sound_") && ($0.hasSuffix(".mp3") || $0.hasSuffix(".wav")) }
            .sorted()
            .compactMap { URL(fileURLWithPath: resourcePath + "/" + $0) }

        for url in urls {
            if let s = NSSound(contentsOf: url, byReference: true) {
                soundFiles.append(SoundFile(url: url, duration: s.duration))
            } else {
                log.error("entity:SoundClip wasInvalidatedBy activity:Preload file=\(url.lastPathComponent)")
            }
        }
        if soundFiles.isEmpty {
            log.error("entity:SoundLibrary wasInvalidatedBy activity:Preload — no sound files in bundle")
        } else {
            log.info("entity:SoundLibrary wasGeneratedBy activity:Preload count=\(soundFiles.count)")
        }
    }
}
