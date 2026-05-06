import XCTest
import CoreAudio
@testable import ResponseKit

/// Behavioural cells for `AudioTransport(transportType:)`. The mapping
/// from `kAudioDeviceTransportType*` FourCharCodes to the Swift enum
/// is the contract every audio-row icon and the EDID-extraction gate
/// relies on. These cells pin each branch independently so a future
/// refactor that drops a case (e.g., conflating Bluetooth and
/// AirPlay under separate cases) breaks loudly.
final class AudioTransport_Tests: XCTestCase {

    func testBuiltIn_mapsToBuiltIn() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeBuiltIn), .builtIn,
            "[transport=builtIn] kAudioDeviceTransportTypeBuiltIn must map to .builtIn")
    }

    func testDisplayPort_mapsToDisplayPort() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeDisplayPort), .displayPort,
            "[transport=displayPort] kAudioDeviceTransportTypeDisplayPort must map to .displayPort")
    }

    func testHDMI_mapsToHDMI() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeHDMI), .hdmi,
            "[transport=hdmi] kAudioDeviceTransportTypeHDMI must map to .hdmi")
    }

    func testUSB_mapsToUSB() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeUSB), .usb,
            "[transport=usb] kAudioDeviceTransportTypeUSB must map to .usb")
    }

    /// Bluetooth, BluetoothLE, and AirPlay are intentionally collapsed
    /// into the single `.bluetooth` icon class — they all render with
    /// `headphones.bluetooth` in the menu because the user's mental
    /// model is "wireless headphones / wireless speaker." Splitting
    /// them into distinct cases would force three icon variants for
    /// no useful UX win.
    func testBluetoothFamily_mapsToBluetooth() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeBluetooth), .bluetooth,
            "[transport=bluetooth] classic Bluetooth must map to .bluetooth")
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeBluetoothLE), .bluetooth,
            "[transport=bluetoothLE] Bluetooth LE must collapse onto .bluetooth (same icon class)")
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeAirPlay), .bluetooth,
            "[transport=airPlay] AirPlay must collapse onto .bluetooth (wireless icon class)")
    }

    func testThunderbolt_mapsToThunderbolt() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeThunderbolt), .thunderbolt,
            "[transport=thunderbolt] kAudioDeviceTransportTypeThunderbolt must map to .thunderbolt")
    }

    /// 'hdwr' = analog headphone jack on older Macs. The constant is
    /// not exported as a public symbol — we hardcode 0x68647772 to
    /// match the FourCharCode literal.
    func testAnalogHeadphone_mapsToHeadphone() {
        XCTAssertEqual(AudioTransport(transportType: 0x686477), .headphone,
            "[transport=headphone] 'hdwr' FourCharCode must map to .headphone")
    }

    /// Aggregate and virtual transports never reach
    /// `AudioTransport.init` in production (the device-list filter
    /// drops them earlier) — but if they ever did, falling through
    /// to `.unknown` is safer than asserting.
    func testUnknownTransport_fallsThroughToUnknown() {
        XCTAssertEqual(AudioTransport(transportType: 0), .unknown,
            "[transport=zero] zero must map to .unknown (CoreAudio returns 0 when property is unavailable)")
        XCTAssertEqual(AudioTransport(transportType: 0xDEADBEEF), .unknown,
            "[transport=arbitrary] arbitrary unhandled FourCharCode must map to .unknown rather than crash")
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeAggregate), .unknown,
            "[transport=aggregate] aggregate transport (filtered upstream) must still map cleanly to .unknown if it ever reaches us")
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeVirtual), .unknown,
            "[transport=virtual] virtual transport (filtered upstream) must still map cleanly to .unknown if it ever reaches us")
    }
}
