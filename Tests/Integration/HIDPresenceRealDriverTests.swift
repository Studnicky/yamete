import XCTest
@testable import SensorKit

/// Integration tests for the real IOHIDManager-backed device monitor.
/// Self-skip the trackpad-presence assertion on machines without a built-in
/// display (e.g. desktop Macs / cloud runners). Catches the bug class where
/// matcher-CFDictionary serialization is wrong and the unit-mock would
/// happily report devices the real IOKit query rejects.
final class HIDPresenceRealDriverTests: IntegrationTestCase {

    /// On a MacBook (built-in display present), `TrackpadActivitySource.isPresent`
    /// must return true. Skipped on hardware without a built-in display so cloud
    /// runners and Mac minis don't fail this check spuriously.
    func testTrackpadActivitySource_isPresent_onMacBook() throws {
        let monitor = RealHIDDeviceMonitor()
        guard monitor.hasBuiltInDisplay() else {
            throw XCTSkip("No built-in display — non-laptop hardware")
        }
        let present = TrackpadActivitySource.isPresent(monitor: monitor)
        XCTAssertTrue(present,
                      "On a MacBook (built-in display), TrackpadActivitySource.isPresent must return true")
    }

    /// The real monitor's matcher-CFDictionary roundtrip must accept the
    /// trackpad presence matchers without crashing. Sanity-check that
    /// `queryDevices` returns successfully (the array may be empty on
    /// non-MacBooks). Always runs — does not require hardware.
    func testRealMonitor_queriesTrackpadMatchers_withoutCrash() {
        let monitor = RealHIDDeviceMonitor()
        let devices = monitor.queryDevices(matchers: TrackpadActivitySource.presenceMatchers)
        // Don't assert non-empty — desktops legitimately have no trackpad.
        // Just assert the call returned (no crash, no exception).
        XCTAssertGreaterThanOrEqual(devices.count, 0)
    }

    /// Direct probe of the matcher-CFDictionary roundtrip via the
    /// digitizer-touchpad matcher (`usagePage: 0x000D, usage: 0x0005`).
    /// On a MacBook the built-in trackpad reports as a digitizer touchpad
    /// — if `toCFDictionary` ever serializes usagePage/usage as Strings
    /// instead of Ints, IOKit silently rejects the matcher and this test
    /// goes from "found ≥1 device" to "found 0 devices". Catches the bug
    /// class where unit tests pass against the mock but real IOKit
    /// rejects the actual CFDictionary.
    func testRealMonitor_digitizerMatcher_findsBuiltInTrackpadOnLaptop() throws {
        let monitor = RealHIDDeviceMonitor()
        guard monitor.hasBuiltInDisplay() else {
            throw XCTSkip("No built-in display — non-laptop hardware")
        }
        // Use the production matcher list — the digitizer-page entry is
        // what matches the built-in MacBook trackpad. Probing the source
        // list (instead of an inline matcher) catches the bug class
        // where someone "tweaks" the usagePage/usage to a wrong value
        // and unit tests against the mock keep passing.
        let devices = monitor.queryDevices(matchers: TrackpadActivitySource.presenceMatchers)
        XCTAssertFalse(devices.isEmpty,
                       "On a MacBook (built-in display present), TrackpadActivitySource.presenceMatchers " +
                       "must match the built-in trackpad. Empty result indicates the matcher list drifted " +
                       "(wrong transport / usagePage / usage / product fields).")
    }
}
