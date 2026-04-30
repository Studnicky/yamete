#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import Foundation

// MARK: - Audio playback driver protocol
//
// Abstracts the `NSSound`-based playback used by `AudioPlayer`. The real
// driver wraps the NSSound construction + play machinery and delegates
// "did-finish" callbacks back to a sink. Mocks record every play/stop
// call and let tests verify the URL, device UID, and volume passed in.
//
// MainActor-isolated: `NSSound` is documented as main-thread only and the
// `AudioPlayer` consumer is already MainActor-confined.

@MainActor
public protocol AudioPlaybackDriver: AnyObject {
    /// Load the duration of the clip at `url`. Returns `nil` if the URL
    /// cannot be loaded as a sound. Used at preload time.
    func loadDuration(url: URL) -> Double?

    /// Begin playback of the given URL. `deviceUID = nil` means the
    /// system default device. The sound retains itself for the duration
    /// of playback. Returns the clip duration in seconds (0 if the clip
    /// failed to load).
    @discardableResult
    func play(url: URL, deviceUID: String?, volume: Float) -> Double

    /// Stop every active sound. Idempotent.
    func stop()
}

// MARK: - Real implementation

/// Production NSSound-backed driver.
@MainActor
public final class RealAudioPlaybackDriver: NSObject, AudioPlaybackDriver, NSSoundDelegate {
    private var activeSounds: [NSSound] = []

    public override init() {
        super.init()
    }

    public func loadDuration(url: URL) -> Double? {
        guard let s = NSSound(contentsOf: url, byReference: true) else { return nil }
        return s.duration
    }

    @discardableResult
    public func play(url: URL, deviceUID: String?, volume: Float) -> Double {
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return 0 }
        if let deviceUID {
            sound.playbackDeviceIdentifier = deviceUID
        }
        sound.volume = volume
        sound.delegate = self
        activeSounds.append(sound)
        sound.play()
        return sound.duration
    }

    public func stop() {
        for sound in activeSounds { sound.stop() }
        activeSounds.removeAll()
    }

    public func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        activeSounds.removeAll { $0 === sound }
    }
}
