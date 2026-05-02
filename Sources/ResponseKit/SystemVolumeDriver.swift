#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
import AudioToolbox

// MARK: - System volume driver protocol
//
// Abstracts the CoreAudio default-output-device discovery + virtual-main
// volume property used by `VolumeSpikeResponder`. Real driver wraps the
// `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` calls. Mocks
// record reads/writes and let tests inject the captured value used by the
// "restore" path.

public protocol SystemVolumeDriver: AnyObject, Sendable {
    /// Read the current system output volume on the default output device.
    /// Returns `nil` when the volume cannot be read (no output device, etc.).
    func getVolume() -> Float?

    /// Write a new system output volume on the default output device.
    /// Implementations clamp to 0...1 internally.
    func setVolume(_ volume: Float)
}

// MARK: - Real implementation

/// Production CoreAudio-backed driver.
public final class RealSystemVolumeDriver: SystemVolumeDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: stateless wrapper over CoreAudio
    // `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` calls
    // which are documented to be safe to call from any thread.

    public init() {}

    public func getVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var vol: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr else { return nil }
        return vol
    }

    public func setVolume(_ volume: Float) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var vol = volume.clamped(to: 0...1)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }
}
