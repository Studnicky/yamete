#if canImport(YameteCore)
import YameteCore
#endif
import CoreAudio
import Foundation

/// Represents a macOS audio output device.
public struct AudioOutputDevice: Identifiable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    /// Disambiguated display name (appends " (2)" etc. for duplicates)
    public let displayName: String
}

public enum AudioDeviceManager {

    /// Returns all audio devices that have at least one output channel.
    public static func outputDevices() -> [AudioOutputDevice] {
        let deviceIDs = allDeviceIDs()

        var results: [AudioOutputDevice] = []
        for deviceID in deviceIDs {
            guard outputChannelCount(deviceID) > 0 else { continue }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { continue }
            results.append(AudioOutputDevice(id: deviceID, uid: uid, name: name, displayName: name))
        }

        // Disambiguate duplicate names (e.g., two "LG UltraFine Display Audio")
        var nameCounts: [String: Int] = [:]
        for d in results { nameCounts[d.name, default: 0] += 1 }

        var nameIndex: [String: Int] = [:]
        return results.map { d in
            guard nameCounts[d.name, default: 0] > 1 else { return d }
            let idx = nameIndex[d.name, default: 0] + 1
            nameIndex[d.name] = idx
            return AudioOutputDevice(id: d.id, uid: d.uid, name: d.name, displayName: "\(d.name) (\(idx))")
        }
    }

    /// UID of the current default output device.
    public static var defaultDeviceUID: String? {
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
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
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
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// Returns the number of output channels for a device (0 = input-only).
    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        // AudioBufferList is variable-length — allocate the full reported size
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr else { return 0 }

        let list = buf.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(list.pointee.mNumberBuffers)
        guard bufferCount > 0 else { return 0 }

        // Sum channels across all buffers
        var totalChannels = 0
        withUnsafeMutablePointer(to: &list.pointee.mBuffers) { firstBuffer in
            for i in 0..<bufferCount {
                totalChannels += Int(firstBuffer.advanced(by: i).pointee.mNumberChannels)
            }
        }
        return totalChannels
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}
