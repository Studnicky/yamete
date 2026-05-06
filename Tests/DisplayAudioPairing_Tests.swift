import XCTest
import CoreAudio
import CoreGraphics
@testable import ResponseKit

/// Behavioural cells for `DisplayAudioPairing.pair(audioDevices:displayInfos:)`.
/// The production overload that takes `[NSScreen]` cannot be driven without
/// real hardware (CGDisplay*Number reads from the live IORegistry), so the
/// pure helper is the test surface — it accepts pre-built `DisplayInfo`
/// triples that synthesise vendor / product / serial / built-in from
/// whatever the cell wants to model.
final class DisplayAudioPairing_Tests: XCTestCase {

    /// Built-in laptop speakers (transport `.builtIn`) implicitly pair
    /// to whatever display reports `isBuiltin == true`. EDID is not
    /// involved on this path — the mapping is structural.
    func testBuiltInAudio_pairsToBuiltInDisplay() {
        let audio = audio(uid: "speakers-builtin", transport: .builtIn, edid: nil)
        let info = DisplayAudioPairing.DisplayInfo(
            displayID: 1, vendorID: 0x06_10, productID: 0xABCD, serialNumber: 0x12345678, isBuiltin: true)
        let map = DisplayAudioPairing.pair(audioDevices: [audio], displayInfos: [info])
        XCTAssertEqual(map["speakers-builtin"], 1,
            "[pairing=builtin] built-in speakers must pair to the built-in display (got \(String(describing: map["speakers-builtin"])))")
    }

    /// DisplayPort audio with a populated EDID triple matching one of
    /// the connected displays must pair to that display.
    func testDisplayPortAudio_edidMatch_pairsToDisplay() {
        let edid = AudioDeviceEDID(vendorID: 0xABCD, productID: 0x1234, serialNumber: 0x99887766)
        let audio = audio(uid: "ultraFine", transport: .displayPort, edid: edid)
        let dpInfo = DisplayAudioPairing.DisplayInfo(
            displayID: 42, vendorID: 0xABCD, productID: 0x1234, serialNumber: 0x99887766, isBuiltin: false)
        let map = DisplayAudioPairing.pair(audioDevices: [audio], displayInfos: [dpInfo])
        XCTAssertEqual(map["ultraFine"], 42,
            "[pairing=edid-match] DisplayPort EDID match must pair to the display sharing all three identifiers (got \(String(describing: map["ultraFine"])))")
    }

    /// HDMI audio matched the same way as DisplayPort — the parser
    /// doesn't distinguish, only the transport class differs in the
    /// audio device.
    func testHDMIAudio_edidMatch_pairsToDisplay() {
        let edid = AudioDeviceEDID(vendorID: 0x1111, productID: 0x2222, serialNumber: 0x33333333)
        let audio = audio(uid: "tv-hdmi", transport: .hdmi, edid: edid)
        let info = DisplayAudioPairing.DisplayInfo(
            displayID: 7, vendorID: 0x1111, productID: 0x2222, serialNumber: 0x33333333, isBuiltin: false)
        let map = DisplayAudioPairing.pair(audioDevices: [audio], displayInfos: [info])
        XCTAssertEqual(map["tv-hdmi"], 7,
            "[pairing=edid-match-hdmi] HDMI transport must pair the same way as DisplayPort")
    }

    /// EDID identifiers that do not match any connected display must
    /// produce no pairing — the audio still works, the user just
    /// doesn't see the "attached to" footnote.
    func testDisplayPortAudio_edidMismatch_noPairing() {
        let edid = AudioDeviceEDID(vendorID: 0xABCD, productID: 0x1234, serialNumber: 0x99887766)
        let audio = audio(uid: "unmatched", transport: .displayPort, edid: edid)
        let info = DisplayAudioPairing.DisplayInfo(
            displayID: 99, vendorID: 0xDEAD, productID: 0xBEEF, serialNumber: 0xCAFEBABE, isBuiltin: false)
        let map = DisplayAudioPairing.pair(audioDevices: [audio], displayInfos: [info])
        XCTAssertNil(map["unmatched"],
            "[pairing=edid-mismatch] non-matching EDID triple must produce no pairing")
    }

    /// Display-class audio with `edid == nil` (IORegistry walk failed,
    /// cheap dock, etc.) must not pair to any display, even if a
    /// display with all-zero identifiers happens to be present.
    func testDisplayPortAudio_nilEDID_noPairing() {
        let audio = audio(uid: "nilEDID", transport: .displayPort, edid: nil)
        let info = DisplayAudioPairing.DisplayInfo(
            displayID: 55, vendorID: 0, productID: 0, serialNumber: 0, isBuiltin: false)
        let map = DisplayAudioPairing.pair(audioDevices: [audio], displayInfos: [info])
        XCTAssertNil(map["nilEDID"],
            "[pairing=nil-edid] display-class audio with nil EDID must not pair to a zero-EDID display by accident")
    }

    /// USB / Bluetooth / Headphone / Thunderbolt / Unknown transports
    /// never pair to a display regardless of identifier values —
    /// they're not display-class so the question is meaningless.
    func testNonDisplayClassTransports_neverPair() {
        let edid = AudioDeviceEDID(vendorID: 0xABCD, productID: 0x1234, serialNumber: 0x99887766)
        let info = DisplayAudioPairing.DisplayInfo(
            displayID: 1, vendorID: 0xABCD, productID: 0x1234, serialNumber: 0x99887766, isBuiltin: true)
        for transport in [AudioTransport.usb, .bluetooth, .headphone, .thunderbolt, .unknown] {
            let device = audio(uid: "device-\(transport)", transport: transport, edid: edid)
            let map = DisplayAudioPairing.pair(audioDevices: [device], displayInfos: [info])
            XCTAssertNil(map["device-\(transport)"],
                "[pairing=non-display-class-\(transport)] non-display-class transport must never pair regardless of EDID match")
        }
    }

    /// Mixed scenario: built-in laptop speakers + external DisplayPort
    /// monitor speakers + USB headphones. All three pairings produce
    /// the right results in one call.
    func testMixedScenario_independentPairings() {
        let builtinAudio = audio(uid: "macbook-speakers", transport: .builtIn, edid: nil)
        let lgEDID = AudioDeviceEDID(vendorID: 0x1E6D, productID: 0x5B11, serialNumber: 0x000F00F0)  // realistic LG triple
        let lgAudio = audio(uid: "lg-ultraFine", transport: .displayPort, edid: lgEDID)
        let usbAudio = audio(uid: "usb-headset", transport: .usb, edid: nil)

        let builtinInfo = DisplayAudioPairing.DisplayInfo(
            displayID: 1, vendorID: 0x06_10, productID: 0xA050, serialNumber: 0x00000000, isBuiltin: true)
        let lgInfo = DisplayAudioPairing.DisplayInfo(
            displayID: 2, vendorID: 0x1E6D, productID: 0x5B11, serialNumber: 0x000F00F0, isBuiltin: false)

        let map = DisplayAudioPairing.pair(audioDevices: [builtinAudio, lgAudio, usbAudio],
                                           displayInfos: [builtinInfo, lgInfo])

        XCTAssertEqual(map["macbook-speakers"], 1,
            "[pairing=mixed-builtin] built-in audio pairs to built-in display in mixed scenario")
        XCTAssertEqual(map["lg-ultraFine"], 2,
            "[pairing=mixed-edid] external DP audio pairs to its EDID-matching display in mixed scenario")
        XCTAssertNil(map["usb-headset"],
            "[pairing=mixed-usb] USB audio remains unpaired in mixed scenario")
        XCTAssertEqual(map.count, 2,
            "[pairing=mixed-count] only the two display-class devices appear in the result map (got \(map.count))")
    }

    /// No connected displays + any audio configuration produces an
    /// empty map. The function must not crash on the empty-displays
    /// edge case (machine in clamshell with no external monitor at
    /// the moment of the call, etc.).
    func testNoDisplays_emptyMap() {
        let audio = audio(uid: "anything", transport: .builtIn, edid: nil)
        let map = DisplayAudioPairing.pair(audioDevices: [audio], displayInfos: [])
        XCTAssertTrue(map.isEmpty,
            "[pairing=no-displays] empty display list must produce empty pairing map")
    }

    // MARK: - Helpers

    /// Synthesises an `AudioOutputDevice` with the supplied transport
    /// and optional EDID. Other fields are filled with sensible
    /// defaults so cells stay readable.
    private func audio(uid: String, transport: AudioTransport, edid: AudioDeviceEDID?) -> AudioOutputDevice {
        AudioOutputDevice(id: 0, uid: uid, name: uid, displayName: uid, transport: transport, edid: edid)
    }
}
