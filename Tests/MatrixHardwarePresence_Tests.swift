import XCTest
@testable import SensorKit

/// Drives the three activity-source `isPresent(monitor:)` static functions
/// with a `MockHIDDeviceMonitor` returning various device sets, and
/// asserts the boolean result matches the expected presence semantics.
final class MatrixHardwarePresence_Tests: XCTestCase {

    // MARK: - Trackpad presence

    func testTrackpadPresentBuiltInSPI() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "SPI", product: "Apple Internal Trackpad", vendorID: 0x05ac, productID: 0x027c)
        ])
        XCTAssertTrue(TrackpadActivitySource.isPresent(monitor: monitor))
    }

    func testTrackpadPresentBluetoothMagic() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "Bluetooth", product: "Magic Trackpad", vendorID: 0x05ac, productID: 0x0265)
        ])
        XCTAssertTrue(TrackpadActivitySource.isPresent(monitor: monitor))
    }

    func testTrackpadPresentDigitizerFallback() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "USB", product: "Touch Pad", vendorID: 0, productID: 0)
        ])
        XCTAssertTrue(TrackpadActivitySource.isPresent(monitor: monitor))
    }

    func testTrackpadAbsentNoDevicesNoBuiltInDisplay() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([])
        monitor.setHasBuiltInDisplay(false)
        XCTAssertFalse(TrackpadActivitySource.isPresent(monitor: monitor))
    }

    func testTrackpadFallbackBuiltInDisplay() {
        // No devices match, but built-in display present → MacBook → trackpad assumed.
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([])
        monitor.setHasBuiltInDisplay(true)
        XCTAssertTrue(TrackpadActivitySource.isPresent(monitor: monitor))
    }

    // MARK: - Mouse presence

    func testMousePresentExternalUSB() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "USB", product: "Logitech MX Master 3", vendorID: 0x046d, productID: 0xc547)
        ])
        XCTAssertTrue(MouseActivitySource.isPresent(monitor: monitor))
    }

    func testMouseAbsentSPIDevice() {
        // SPI = built-in trackpad. Does NOT count as a mouse.
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "SPI", product: "Apple Internal Trackpad", vendorID: 0x05ac, productID: 0x027c)
        ])
        XCTAssertFalse(MouseActivitySource.isPresent(monitor: monitor))
    }

    func testMouseAbsentBluetoothTrackpad() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "Bluetooth", product: "Magic Trackpad 2", vendorID: 0, productID: 0)
        ])
        XCTAssertFalse(MouseActivitySource.isPresent(monitor: monitor))
    }

    func testMouseAbsentNoDevices() {
        let monitor = MockHIDDeviceMonitor()
        XCTAssertFalse(MouseActivitySource.isPresent(monitor: monitor))
    }

    // MARK: - Keyboard presence

    func testKeyboardPresentExternal() {
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "Bluetooth", product: "Magic Keyboard", vendorID: 0, productID: 0)
        ])
        XCTAssertTrue(KeyboardActivitySource.isPresent(monitor: monitor))
    }

    func testKeyboardAbsentSPIBuiltIn() {
        // SPI = built-in MacBook keyboard. Excluded by design (Input Monitoring
        // tap can't grab built-in keyboard reliably on Apple Silicon).
        let monitor = MockHIDDeviceMonitor()
        monitor.setCannedDevices([
            HIDDeviceInfo(transport: "SPI", product: "Apple Internal Keyboard / Trackpad", vendorID: 0x05ac, productID: 0)
        ])
        XCTAssertFalse(KeyboardActivitySource.isPresent(monitor: monitor))
    }

    func testKeyboardAbsentNoDevices() {
        let monitor = MockHIDDeviceMonitor()
        XCTAssertFalse(KeyboardActivitySource.isPresent(monitor: monitor))
    }

    // MARK: - Matchers carry expected fields

    func testTrackpadMatchersIncludeAllVariants() {
        XCTAssertEqual(TrackpadActivitySource.presenceMatchers.count, 5)
        XCTAssertTrue(TrackpadActivitySource.presenceMatchers.contains(HIDMatcher(transport: "SPI")))
        XCTAssertTrue(TrackpadActivitySource.presenceMatchers.contains(HIDMatcher(usagePage: 0x000D, usage: 0x0005)))
    }

    func testMouseMatchersIncludeMouseAndPointer() {
        XCTAssertEqual(MouseActivitySource.presenceMatchers.count, 2)
    }

    func testKeyboardMatchersGenericDesktop() {
        XCTAssertEqual(KeyboardActivitySource.presenceMatchers.count, 1)
    }

    // MARK: - Cross-product matrix
    //
    // For each source × (devices-empty, devices-spi-only, devices-bluetooth-magic,
    // devices-mixed) verify the documented presence outcome.

    func testTrackpadCrossProduct() {
        struct Cell {
            let label: String
            let devices: [HIDDeviceInfo]
            let builtInDisplay: Bool
            let expected: Bool
        }
        let cells: [Cell] = [
            .init(label: "no devices, no display",
                  devices: [],
                  builtInDisplay: false,
                  expected: false),
            .init(label: "no devices, built-in display fallback",
                  devices: [],
                  builtInDisplay: true,
                  expected: true),
            .init(label: "SPI device",
                  devices: [HIDDeviceInfo(transport: "SPI", product: "x", vendorID: 0, productID: 0)],
                  builtInDisplay: false,
                  expected: true),
            .init(label: "Bluetooth Magic Trackpad 2",
                  devices: [HIDDeviceInfo(transport: "Bluetooth", product: "Apple Magic Trackpad 2", vendorID: 0, productID: 0)],
                  builtInDisplay: false,
                  expected: true),
            .init(label: "Bluetooth random non-trackpad",
                  devices: [HIDDeviceInfo(transport: "Bluetooth", product: "Random Mouse", vendorID: 0, productID: 0)],
                  builtInDisplay: false,
                  expected: true),  // matches via the matcher list (non-empty match → true)
        ]
        for cell in cells {
            let monitor = MockHIDDeviceMonitor()
            monitor.setCannedDevices(cell.devices)
            monitor.setHasBuiltInDisplay(cell.builtInDisplay)
            XCTAssertEqual(TrackpadActivitySource.isPresent(monitor: monitor), cell.expected,
                           "trackpad cell '\(cell.label)' expected=\(cell.expected)")
        }
    }

    func testMouseCrossProduct() {
        struct Cell {
            let label: String
            let devices: [HIDDeviceInfo]
            let expected: Bool
        }
        let cells: [Cell] = [
            .init(label: "no devices", devices: [], expected: false),
            .init(label: "SPI only",
                  devices: [HIDDeviceInfo(transport: "SPI", product: "Internal Trackpad", vendorID: 0, productID: 0)],
                  expected: false),
            .init(label: "Bluetooth Trackpad excluded",
                  devices: [HIDDeviceInfo(transport: "Bluetooth", product: "Magic Trackpad", vendorID: 0, productID: 0)],
                  expected: false),
            .init(label: "USB external mouse",
                  devices: [HIDDeviceInfo(transport: "USB", product: "Razer DeathAdder", vendorID: 0, productID: 0)],
                  expected: true),
            .init(label: "Bluetooth Magic Mouse",
                  devices: [HIDDeviceInfo(transport: "Bluetooth", product: "Magic Mouse", vendorID: 0, productID: 0)],
                  expected: true),
            .init(label: "mixed: trackpad + mouse",
                  devices: [
                    HIDDeviceInfo(transport: "SPI", product: "Internal Trackpad", vendorID: 0, productID: 0),
                    HIDDeviceInfo(transport: "USB", product: "Logitech Mouse", vendorID: 0, productID: 0),
                  ],
                  expected: true),
        ]
        for cell in cells {
            let monitor = MockHIDDeviceMonitor()
            monitor.setCannedDevices(cell.devices)
            XCTAssertEqual(MouseActivitySource.isPresent(monitor: monitor), cell.expected,
                           "mouse cell '\(cell.label)' expected=\(cell.expected)")
        }
    }

    func testKeyboardCrossProduct() {
        struct Cell {
            let label: String
            let devices: [HIDDeviceInfo]
            let expected: Bool
        }
        let cells: [Cell] = [
            .init(label: "no devices", devices: [], expected: false),
            .init(label: "SPI built-in only",
                  devices: [HIDDeviceInfo(transport: "SPI", product: "Internal Keyboard", vendorID: 0, productID: 0)],
                  expected: false),
            .init(label: "Bluetooth Magic Keyboard",
                  devices: [HIDDeviceInfo(transport: "Bluetooth", product: "Magic Keyboard", vendorID: 0, productID: 0)],
                  expected: true),
            .init(label: "USB external keyboard",
                  devices: [HIDDeviceInfo(transport: "USB", product: "Das Keyboard", vendorID: 0, productID: 0)],
                  expected: true),
            .init(label: "mixed SPI + external",
                  devices: [
                    HIDDeviceInfo(transport: "SPI", product: "Internal Keyboard", vendorID: 0, productID: 0),
                    HIDDeviceInfo(transport: "USB", product: "External Keyboard", vendorID: 0, productID: 0),
                  ],
                  expected: true),
        ]
        for cell in cells {
            let monitor = MockHIDDeviceMonitor()
            monitor.setCannedDevices(cell.devices)
            XCTAssertEqual(KeyboardActivitySource.isPresent(monitor: monitor), cell.expected,
                           "keyboard cell '\(cell.label)' expected=\(cell.expected)")
        }
    }

    // MARK: - HIDMatcher CFDictionary conversion sanity

    func testHIDMatcherToDictionaryAllFields() {
        let m = HIDMatcher(transport: "USB", product: "Foo", usagePage: 0x01, usage: 0x06)
        let dict = m.toCFDictionary() as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["Transport"] as? String, "USB")
        XCTAssertEqual(dict?["Product"]   as? String, "Foo")
    }

    func testHIDMatcherEqualityHashable() {
        let a = HIDMatcher(transport: "SPI")
        let b = HIDMatcher(transport: "SPI")
        XCTAssertEqual(a, b)
        let set: Set<HIDMatcher> = [a, b]
        XCTAssertEqual(set.count, 1)
    }

    func testHIDDeviceInfoEquality() {
        let a = HIDDeviceInfo(transport: "USB", product: "P", vendorID: 1, productID: 2)
        let b = HIDDeviceInfo(transport: "USB", product: "P", vendorID: 1, productID: 2)
        let c = HIDDeviceInfo(transport: "USB", product: "Q", vendorID: 1, productID: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
