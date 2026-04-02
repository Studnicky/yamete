import CoreAudio
import Foundation

/// Enumerates macOS audio output devices via Core Audio.
struct AudioOutputDevice: Identifiable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceManager {
    /// Returns all audio devices that have output channels.
    static func outputDevices() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasOutputChannels(deviceID) else { return nil }
            guard let uid = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioOutputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    /// UID of the current default output device.
    static var defaultDeviceUID: String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Private

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let buf = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr else { return false }
        let channelCount = buf.pointee.mNumberBuffers > 0 ? Int(buf.pointee.mBuffers.mNumberChannels) : 0
 return channelCount > 0
    }

    private static func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return nil }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr else { return nil }
        return buf.load(as: CFString.self) as String
    }
}
