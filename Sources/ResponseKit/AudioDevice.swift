#if !RAW_SWIFTC_LUMP
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
    /// Transport class — drives the row icon in the menu and feeds the
    /// display-pairing heuristic for monitor speakers.
    public let transport: AudioTransport
    /// EDID-derived identifiers for display-class audio devices
    /// (DisplayPort/HDMI). Nil when not a display-class device or when
    /// the IORegistry walk could not extract them. Used to pair the
    /// audio device with the display whose speakers it represents.
    public let edid: AudioDeviceEDID?

    public init(id: AudioDeviceID, uid: String, name: String, displayName: String,
                transport: AudioTransport, edid: AudioDeviceEDID?) {
        self.id = id
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.transport = transport
        self.edid = edid
    }
}

/// Coarse transport class for an audio output device. Mirrors the
/// macOS `kAudioDeviceTransportType` constants but exposed as a Swift
/// enum so call-sites pattern-match without dragging the FourCharCode
/// constants into UI code.
public enum AudioTransport: Sendable, Hashable {
    /// Built-in laptop speakers (transportType == `kAudioDeviceTransportTypeBuiltIn`).
    /// On a MacBook, this is the speakers behind the internal display.
    case builtIn
    /// External display speakers carried over DisplayPort
    /// (transportType == `kAudioDeviceTransportTypeDisplayPort`).
    case displayPort
    /// External display speakers carried over HDMI
    /// (transportType == `kAudioDeviceTransportTypeHDMI`).
    case hdmi
    /// USB audio interface, USB speakers, USB headset, etc.
    case usb
    /// Bluetooth or AirPlay headphones / speakers.
    case bluetooth
    /// Wired analog headphones (3.5mm jack on Macs that still have one).
    case headphone
    /// Thunderbolt-attached audio (rare — most TB speakers identify as
    /// USB or DisplayPort downstream of the dock).
    case thunderbolt
    /// Recognised transport type that does not map to any of the above
    /// or transport type was not reported. Treated as a generic speaker
    /// in the UI.
    case unknown
}

/// EDID block extracted from a display-class audio device's IORegistry
/// node. The four identifiers here are the same fields the display
/// itself reports through `CGDisplayVendorNumber` /
/// `CGDisplayModelNumber` / `CGDisplaySerialNumber`, so they pair
/// 1:1 when both sides parse cleanly.
public struct AudioDeviceEDID: Sendable, Hashable {
    /// EDID manufacturer ID — a packed 16-bit value formed from three
    /// 5-bit letter codes (bytes 8–9 of the EDID block).
    public let vendorID: UInt32
    /// EDID product code (bytes 10–11 of the EDID block).
    public let productID: UInt32
    /// EDID serial number (bytes 12–15 of the EDID block). Often zero
    /// on cheap monitors that do not implement the optional serial
    /// descriptor.
    public let serialNumber: UInt32
}

extension AudioTransport {
    /// Maps the raw `kAudioDeviceTransportType` FourCharCode to a
    /// classified Swift case. Unknown / unhandled values fall through
    /// to `.unknown`.
    init(transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:     self = .builtIn
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeHDMI:        self = .hdmi
        case kAudioDeviceTransportTypeUSB:         self = .usb
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay:     self = .bluetooth
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case 0x686477:  // 'hdwr' — analog headphone jack on older Macs
                                                   self = .headphone
        default:                                   self = .unknown
        }
    }
}

public enum AudioDeviceManager {

    /// Returns physical audio output devices (excludes aggregate and virtual devices).
    public static func outputDevices() -> [AudioOutputDevice] {
        let devices = filterPhysicalOutputDevices(from: allDeviceIDs())
        return disambiguateNames(devices)
    }

    private static func filterPhysicalOutputDevices(from deviceIDs: [AudioDeviceID]) -> [AudioOutputDevice] {
        deviceIDs.compactMap { deviceID -> AudioOutputDevice? in
            let transport = transportType(deviceID)
            guard outputChannelCount(deviceID) > 0,
                  transport != kAudioDeviceTransportTypeAggregate,
                  transport != kAudioDeviceTransportTypeVirtual,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            let classified = AudioTransport(transportType: transport)
            // EDID extraction only meaningful for display-class audio.
            // For other transport classes we skip the IORegistry walk
            // entirely — saves work and avoids spurious matches.
            let edid: AudioDeviceEDID? = {
                switch classified {
                case .displayPort, .hdmi: return EDIDExtractor.edid(forAudioDeviceUID: uid)
                default:                  return nil
                }
            }()
            return AudioOutputDevice(id: deviceID, uid: uid, name: name, displayName: name,
                                     transport: classified, edid: edid)
        }
    }

    private static func disambiguateNames(_ devices: [AudioOutputDevice]) -> [AudioOutputDevice] {
        var counts: [String: Int] = [:]
        for d in devices { counts[d.name, default: 0] += 1 }
        var index: [String: Int] = [:]
        return devices.map { d in
            guard counts[d.name, default: 0] > 1 else { return d }
            let idx = index[d.name, default: 0] + 1
            index[d.name] = idx
            return AudioOutputDevice(id: d.id, uid: d.uid, name: d.name,
                                     displayName: "\(d.name) (\(idx))",
                                     transport: d.transport, edid: d.edid)
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

    /// Reads `kAudioDevicePropertyTransportType` for a device. Returns
    /// `0` (treated as `unknown` by `AudioTransport`) when the property
    /// is unavailable. Used both to filter aggregate/virtual devices
    /// out of the list and to drive the row icon + display-pairing
    /// heuristic for the survivors.
    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
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

    // MARK: - Device change notifications

    /// Posts to `NotificationCenter.default` when audio devices are added or removed.
    /// Call `startObserving()` once at app launch; the listener persists for the process lifetime.
    /// https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistener(_:_:_:_:)
    public static let devicesDidChangeNotification = Notification.Name("AudioDeviceManager.devicesDidChange")

    @MainActor private static var listenerInstalled = false

    @MainActor public static func startObserving() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.main
        ) { _, _ in
            NotificationCenter.default.post(name: devicesDidChangeNotification, object: nil)
        }
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
