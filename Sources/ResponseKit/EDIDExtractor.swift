#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import CoreAudio
import Foundation
@preconcurrency import IOKit

private let log = AppLog(category: "EDIDExtractor")

/// Walks the IORegistry to extract EDID identifiers from display-class
/// audio devices (transport type DisplayPort/HDMI). Pairs them with
/// `CGDisplay*Number` values from `DisplayPairing` so the menu can
/// render "attached to <display name>" beneath the audio row.
///
/// ## How it works
///
/// CoreAudio exposes audio devices via `AudioDeviceID` and a textual
/// `kAudioDevicePropertyDeviceUID`. Display-class audio (DP/HDMI) lives
/// in the IORegistry under an `AppleHDAEngineOutput` (or similar)
/// node, which has an `IOHDMIServiceClass` ancestor whose `EDID`
/// property contains the raw 128-byte EDID block from the attached
/// display. We resolve the audio device's IORegistry path via
/// `IOServiceMatching` keyed off the device UID, walk parents until we
/// find an entry with an `EDID` (or `IODisplayEDID`) property, and
/// parse the standard EDID layout:
///
/// - bytes 8–9   → manufacturer ID (3-letter code packed into 15 bits)
/// - bytes 10–11 → product code (little-endian 16-bit)
/// - bytes 12–15 → serial number (little-endian 32-bit)
///
/// These three fields match exactly what `CGDisplayVendorNumber` /
/// `CGDisplayModelNumber` / `CGDisplaySerialNumber` return for the
/// associated display, so a triple-equality test gives a precise
/// pairing.
///
/// ## Limitations (documented for users in docs/)
///
/// - **USB-C docks**: many docks present a single composite USB device
///   that exposes audio under transport type `usb` rather than
///   `displayPort` / `hdmi`. The EDID never reaches CoreAudio in that
///   case and we cannot pair the audio to the display.
/// - **KVMs**: KVM switches may rewrite the EDID or attach to a
///   different display on different sources. Pairing made under one
///   source can become stale.
/// - **Adapter chains**: HDMI→DP, DP→HDMI, mDP→HDMI, etc. sometimes
///   strip or rewrite EDID bytes. Pairing fails silently in that case.
/// - **Cheap monitors**: many monitors leave the EDID serial as 0,
///   which limits the pairing to vendor+product. If two identical
///   monitors are connected, both may "match" the same audio device.
internal enum EDIDExtractor {

    /// Returns the EDID identifiers for an audio device, walking the
    /// IORegistry from the device's IOService entry up through parents
    /// until an `EDID` / `IODisplayEDID` property turns up. Returns
    /// nil for non-display-class devices, devices whose IOService
    /// lookup fails, or devices whose ancestors carry no EDID.
    static func edid(forAudioDeviceUID uid: String) -> AudioDeviceEDID? {
        guard let bytes = edidBytes(forAudioDeviceUID: uid) else { return nil }
        return parseEDID(bytes)
    }

    /// Walks the IORegistry to find the EDID byte block. Exposed for
    /// tests via `_testParseEDID`.
    private static func edidBytes(forAudioDeviceUID uid: String) -> Data? {
        // Try IOAudioEngine first, then its predecessors. The exact class
        // name varies across macOS versions and audio backends — we walk
        // every match for `IOAudioEngine` and inspect parents until we
        // find one carrying an EDID property.
        let engineMatching = IOServiceMatching("IOAudioEngine") as NSMutableDictionary?
        guard let engineMatching else { return nil }
        // The IOAudioEngine doesn't expose the audio device UID directly;
        // we have to walk every audio engine and check whether its
        // parent chain reports a matching DeviceUID property. CoreAudio
        // mirrors the UID into the IORegistry as `IOAudioEngineGlobalUniqueID`
        // on some macOS versions and as `IOAudioDeviceUID` on others.
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, engineMatching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard entryMatchesAudioUID(entry, uid: uid) else { continue }
            if let edid = walkParentsForEDID(entry) { return edid }
        }
        // Fallback: many recent macOS versions register HDMI/DP audio
        // under `AppleHDAEngineOutput` instead of `IOAudioEngine`. Same
        // walk pattern, different class name.
        let hdaMatching = IOServiceMatching("AppleHDAEngineOutput") as NSMutableDictionary?
        guard let hdaMatching else { return nil }
        var hdaIter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, hdaMatching, &hdaIter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(hdaIter) }
        while case let entry = IOIteratorNext(hdaIter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard entryMatchesAudioUID(entry, uid: uid) else { continue }
            if let edid = walkParentsForEDID(entry) { return edid }
        }
        return nil
    }

    /// True when the IORegistry entry's recorded UID matches the
    /// CoreAudio device UID. Some macOS versions store the UID under
    /// `IOAudioDeviceUID`, others under `IOAudioEngineGlobalUniqueID`,
    /// others as a sub-property of the parent. We check both common
    /// keys before giving up.
    private static func entryMatchesAudioUID(_ entry: io_object_t, uid: String) -> Bool {
        for key in ["IOAudioDeviceUID", "IOAudioEngineGlobalUniqueID"] {
            if let prop = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let s = prop as? String, s == uid {
                return true
            }
        }
        return false
    }

    /// Walks parent entries up the IORegistry tree looking for an
    /// `EDID` or `IODisplayEDID` property. Returns the first hit's
    /// raw bytes, or nil if no ancestor carries an EDID.
    private static func walkParentsForEDID(_ entry: io_object_t) -> Data? {
        var current = entry
        IOObjectRetain(current)
        for _ in 0..<16 {  // Bounded walk — registry trees are shallow; this is a safety belt against any cycle bugs upstream.
            for key in ["EDID", "IODisplayEDID"] {
                if let prop = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                   let data = prop as? Data, data.count >= 16 {
                    IOObjectRelease(current)
                    return data
                }
            }
            var parent: io_object_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS, parent != 0 else { return nil }
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }

    /// Parses the standard EDID 1.x identifier triplet from a 128-byte
    /// EDID block. Exposed for tests so we can pin the byte-layout
    /// contract without touching IORegistry.
    internal static func parseEDID(_ data: Data) -> AudioDeviceEDID? {
        guard data.count >= 16 else { return nil }
        // Vendor: bytes 8-9, big-endian, 5-bit letter codes A=1..Z=26
        // packed into 15 bits with the high bit reserved as zero.
        let vendorRaw = (UInt32(data[8]) << 8) | UInt32(data[9])
        // Product code: bytes 10-11, little-endian.
        let productID = UInt32(data[10]) | (UInt32(data[11]) << 8)
        // Serial: bytes 12-15, little-endian.
        let serialNumber =
            UInt32(data[12])
            | (UInt32(data[13]) << 8)
            | (UInt32(data[14]) << 16)
            | (UInt32(data[15]) << 24)
        // CGDisplayVendorNumber returns the same 16-bit raw value the
        // EDID stores, so we keep the packed form for direct equality
        // testing rather than decoding to a 3-letter string.
        return AudioDeviceEDID(vendorID: vendorRaw, productID: productID, serialNumber: serialNumber)
    }
}
