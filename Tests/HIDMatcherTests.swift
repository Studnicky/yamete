import XCTest
@testable import SensorKit
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

/// `HIDMatcher.toCFDictionary()` is the bridge to IOKit's `[String: Any]`
/// dictionary shape. A typo or accidental type coercion in this conversion
/// silently breaks every IOHIDManager call that consumes a matcher list —
/// presence checks return false negatives, device-matching callbacks never
/// fire. These tests assert the exact key strings, value types, and value
/// content for every documented matcher form (transport-only, transport +
/// product, usagePage + usage).
final class HIDMatcherTests: XCTestCase {

    // MARK: - Field-by-field round trips

    func testTransportOnly_RoundTripsAsString() {
        let m = HIDMatcher(transport: "SPI")
        let dict = m.toCFDictionary() as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?[kIOHIDTransportKey] as? String, "SPI")
        XCTAssertEqual(dict?.count, 1, "only transport set, dict must have exactly 1 key")
        XCTAssertNil(dict?[kIOHIDProductKey], "product must NOT appear when nil")
        XCTAssertNil(dict?[kIOHIDDeviceUsagePageKey], "usagePage must NOT appear when nil")
        XCTAssertNil(dict?[kIOHIDDeviceUsageKey], "usage must NOT appear when nil")
    }

    func testBluetoothPlusProduct_RoundTrip() {
        let m = HIDMatcher(transport: "Bluetooth", product: "Magic Trackpad")
        let dict = m.toCFDictionary() as? [String: Any]
        XCTAssertEqual(dict?[kIOHIDTransportKey] as? String, "Bluetooth")
        XCTAssertEqual(dict?[kIOHIDProductKey]   as? String, "Magic Trackpad")
        XCTAssertEqual(dict?.count, 2)
    }

    func testUsagePageUsageOnly_RoundTrip() {
        let m = HIDMatcher(usagePage: 0x000D, usage: 0x0005)
        let dict = m.toCFDictionary() as? [String: Any]
        XCTAssertEqual(dict?[kIOHIDDeviceUsagePageKey] as? Int, 0x000D)
        XCTAssertEqual(dict?[kIOHIDDeviceUsageKey]     as? Int, 0x0005)
        XCTAssertEqual(dict?.count, 2)
        XCTAssertNil(dict?[kIOHIDTransportKey])
        XCTAssertNil(dict?[kIOHIDProductKey])
    }

    /// Spread-loaded dictionary: every field set. Locks the full key set, so
    /// adding a new HIDMatcher field without updating `toCFDictionary` is
    /// caught here.
    func testAllFieldsRoundTrip() {
        let m = HIDMatcher(transport: "USB",
                           product: "Foo",
                           usagePage: 0x01,
                           usage: 0x06)
        let dict = m.toCFDictionary() as? [String: Any]
        XCTAssertEqual(dict?.count, 4, "all four optional fields populated → exactly 4 keys")
        XCTAssertEqual(dict?[kIOHIDTransportKey]        as? String, "USB")
        XCTAssertEqual(dict?[kIOHIDProductKey]          as? String, "Foo")
        XCTAssertEqual(dict?[kIOHIDDeviceUsagePageKey]  as? Int, 0x01)
        XCTAssertEqual(dict?[kIOHIDDeviceUsageKey]      as? Int, 0x06)
    }

    /// `Int` → `kCFNumberType` bridging: assert the values are NOT
    /// accidentally NSString-typed (a common regression when the field type
    /// drifts from Int to String). IOKit's matching layer requires CFNumber
    /// for the usage page/usage entries.
    func testUsagePageIsNumberNotString() {
        let m = HIDMatcher(usagePage: 0x01, usage: 0x06)
        let dict = m.toCFDictionary() as? [String: Any]
        XCTAssertNil(dict?[kIOHIDDeviceUsagePageKey] as? String,
                     "usagePage must not bridge as String")
        XCTAssertNil(dict?[kIOHIDDeviceUsageKey] as? String,
                     "usage must not bridge as String")
        XCTAssertNotNil(dict?[kIOHIDDeviceUsagePageKey] as? Int)
        XCTAssertNotNil(dict?[kIOHIDDeviceUsageKey] as? Int)
    }

    // MARK: - Production matchers

    /// Trackpad uses the SPI matcher first, then HID digitizer page 0x000D /
    /// 0x0005, then three bluetooth product variants. Round-trip every entry.
    func testTrackpadProductionMatchersRoundTrip() {
        let matchers = TrackpadActivitySource.presenceMatchers
        XCTAssertEqual(matchers.count, 5)
        let dicts = matchers.map { $0.toCFDictionary() as? [String: Any] }
        // SPI
        XCTAssertEqual(dicts[0]?[kIOHIDTransportKey] as? String, "SPI")
        // Digitizer
        XCTAssertEqual(dicts[1]?[kIOHIDDeviceUsagePageKey] as? Int, 0x000D)
        XCTAssertEqual(dicts[1]?[kIOHIDDeviceUsageKey] as? Int, 0x0005)
        // Bluetooth Magic Trackpad variants
        for i in 2...4 {
            XCTAssertEqual(dicts[i]?[kIOHIDTransportKey] as? String, "Bluetooth")
            XCTAssertNotNil(dicts[i]?[kIOHIDProductKey] as? String)
        }
    }

    func testKeyboardProductionMatcherRoundTrip() {
        let matchers = KeyboardActivitySource.presenceMatchers
        XCTAssertEqual(matchers.count, 1)
        let dict = matchers[0].toCFDictionary() as? [String: Any]
        XCTAssertEqual(dict?[kIOHIDDeviceUsagePageKey] as? Int, 0x01)
        XCTAssertEqual(dict?[kIOHIDDeviceUsageKey] as? Int, 0x06)
    }

    func testMouseProductionMatchersRoundTrip() {
        let matchers = MouseActivitySource.presenceMatchers
        XCTAssertEqual(matchers.count, 2)
        for matcher in matchers {
            let dict = matcher.toCFDictionary() as? [String: Any]
            XCTAssertNotNil(dict?[kIOHIDDeviceUsagePageKey] as? Int)
            XCTAssertNotNil(dict?[kIOHIDDeviceUsageKey]     as? Int)
        }
    }
}
