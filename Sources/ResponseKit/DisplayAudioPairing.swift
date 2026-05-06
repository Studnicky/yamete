#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import CoreGraphics
import Foundation

private let log = AppLog(category: "DisplayAudioPairing")

/// Pairs CoreAudio output devices with `CGDirectDisplayID`s when the
/// audio device represents the speakers built into a particular
/// monitor. Two strategies, in order of confidence:
///
/// 1. **EDID match** — `AudioOutputDevice.edid` is populated for
///    DisplayPort/HDMI audio by `EDIDExtractor`. We compute the same
///    `(vendor, product, serial)` triple per display via
///    `CGDisplayVendorNumber` / `CGDisplayModelNumber` /
///    `CGDisplaySerialNumber` and match on full equality.
/// 2. **Built-in special case** — the built-in laptop speakers
///    (transport `.builtIn`) implicitly belong to the display where
///    `CGDisplayIsBuiltin == 1`. This pairing is not EDID-based; it's
///    structural. `MacBook` chassis are guaranteed to have exactly one
///    built-in display, so the mapping is unambiguous.
///
/// Strings (display names, audio device names) are NOT used for
/// matching — they're locale-dependent and unstable across reconnects.
/// The cost of skipping name-fallback is that some setups under
/// adapters / docks will report no pairing; that's an honest "we
/// don't know" rather than a possibly-wrong guess.
public enum DisplayAudioPairing {

    /// Identifier triple per display, plus its built-in flag. Intermediate
    /// representation that lets the pure pairing helper stay free of
    /// CoreGraphics + NSScreen calls so tests can drive it with synthetic
    /// values.
    public struct DisplayInfo: Sendable, Hashable {
        public let displayID: CGDirectDisplayID
        public let vendorID: UInt32
        public let productID: UInt32
        public let serialNumber: UInt32
        public let isBuiltin: Bool

        public init(displayID: CGDirectDisplayID, vendorID: UInt32,
                    productID: UInt32, serialNumber: UInt32, isBuiltin: Bool) {
            self.displayID = displayID
            self.vendorID = vendorID
            self.productID = productID
            self.serialNumber = serialNumber
            self.isBuiltin = isBuiltin
        }
    }

    /// Builds the (audioDeviceUID → CGDirectDisplayID) map. Caller
    /// supplies the live audio device list and live display list so
    /// the production wrapper stays free of test-only seams; the
    /// pure helper underneath (`pair(audioDevices:displayInfos:)`)
    /// is what cells drive directly.
    @MainActor
    public static func pair(audioDevices: [AudioOutputDevice],
                            displays: [NSScreen]) -> [String: CGDirectDisplayID] {
        let infos = displays.map { screen -> DisplayInfo in
            let id = CGDirectDisplayID(screen.displayID)
            return DisplayInfo(
                displayID: id,
                vendorID: CGDisplayVendorNumber(id),
                productID: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
        return pair(audioDevices: audioDevices, displayInfos: infos)
    }

    /// Pure-functional pairing logic. Takes the audio device list and
    /// the per-display identifier triples and returns the
    /// (audioUID → CGDirectDisplayID) map. Exposed for tests.
    public static func pair(audioDevices: [AudioOutputDevice],
                            displayInfos: [DisplayInfo]) -> [String: CGDirectDisplayID] {
        var result: [String: CGDirectDisplayID] = [:]

        // Build a side-lookup keyed by the EDID triple for fast
        // O(audio + display) matching.
        var displaysByEDID: [DisplayEDID: CGDirectDisplayID] = [:]
        var builtInDisplay: CGDirectDisplayID?
        for info in displayInfos {
            if info.isBuiltin {
                builtInDisplay = info.displayID
            }
            let edid = DisplayEDID(vendorID: info.vendorID,
                                   productID: info.productID,
                                   serialNumber: info.serialNumber)
            displaysByEDID[edid] = info.displayID
        }

        for device in audioDevices {
            switch device.transport {
            case .builtIn:
                if let id = builtInDisplay {
                    result[device.uid] = id
                }
            case .displayPort, .hdmi:
                guard let edid = device.edid else { continue }
                let key = DisplayEDID(vendorID: edid.vendorID,
                                      productID: edid.productID,
                                      serialNumber: edid.serialNumber)
                if let id = displaysByEDID[key] {
                    result[device.uid] = id
                }
            default:
                continue
            }
        }
        return result
    }
}

/// EDID identifier triple. Used as the dictionary key when matching
/// audio devices to displays. The struct is a value type so it can
/// participate in `Hashable` lookups without bridging.
private struct DisplayEDID: Hashable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    init(vendorID: UInt32, productID: UInt32, serialNumber: UInt32) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }
}

