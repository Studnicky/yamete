import XCTest
@testable import YameteCore
@testable import SensorKit

/// Ring 2 onion-skin for `BluetoothSource` — DOCUMENTED RING 3 GAP.
///
/// `BluetoothSource` subscribes to IOKit `IOBluetoothDevice` lifecycle via
/// `IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
/// IOServiceMatching("IOBluetoothDevice"), ...)` and the matching
/// `kIOTerminatedNotification`. This is the pure IOKit path — the source
/// deliberately AVOIDS `IOBluetooth.framework` (which would have its own
/// `IOBluetoothDevice` ObjC class with KVO/delegate notifications) so we
/// don't drag the private-symbol bridge into the build.
///
/// Therefore the transport layer is a kernel mach-port from the
/// `IOBluetoothHCIController` family, identical in shape to the USB and
/// Thunderbolt sources. Userspace has no way to post these notifications:
///   - `NSNotificationCenter` does NOT mirror `IOBluetoothDevice` lifecycle.
///   - `IOBluetooth.framework` does post some `IOBluetoothDevice*Notification`
///     names via NSNotificationCenter, but our source is NOT subscribed to
///     them — it bypasses IOBluetooth deliberately.
///   - Real Bluetooth pair/unpair would require actual hardware.
///
/// Why this is a TRANSPORT-LAYER gap, not a logic-layer gap:
///   Ring 1 (`Tests/MatrixBluetoothSource_Tests.swift`) drives
///   `_injectConnect` / `_injectDisconnect`, which yield through the SAME
///   `AsyncStream` continuation the IOKit callback yields into and run
///   through the same `bus.publish` fan-out.
///
/// Manual validation procedure for the transport layer:
///   1. Build & run the app.
///   2. From System Settings → Bluetooth, connect a paired peripheral
///      (e.g. AirPods, Magic Mouse). Observe one `.bluetoothConnected`
///      with the device address + name.
///   3. Disconnect the same peripheral. Observe one `.bluetoothDisconnected`.
///   4. Pair a new device. Observe attach (kIOFirstMatchNotification fires
///      for newly-registered IOBluetoothDevice nodes too).
@MainActor
final class MatrixL2_System_Bluetooth_Tests: XCTestCase {

    func test_l3_gap_iobluetooth_iokit_matching_notification_unpostable() throws {
        throw XCTSkip("""
            BluetoothSource subscribes to IOServiceAddMatchingNotification on \
            IOServiceMatching("IOBluetoothDevice") — the IOKit class, not \
            the IOBluetooth.framework class. Mach-port notifications from \
            the IOKit kernel family cannot be synthesized from userspace. \
            Ring 1 _injectConnect/_injectDisconnect covers the production \
            handler logic. Transport-layer-only gap.
            """)
    }

    func test_l3_gap_iobluetooth_framework_path_not_used() throws {
        throw XCTSkip("""
            IOBluetooth.framework DOES post IOBluetoothDeviceConnectionNotification \
            via NSNotificationCenter, but BluetoothSource deliberately does \
            NOT subscribe to it (to avoid the IOBluetooth private-symbol \
            bridge). Therefore posting that notification name would not \
            trigger our source — it's listening on the IOKit side. Ring 1 \
            covers the IOKit-callback path. If a future refactor switches \
            to IOBluetooth.framework, this gap becomes Ring 2-testable; \
            until then it stays Ring 3.
            """)
    }

    func test_l3_gap_iobluetoothdevice_address_lookup_unmockable() throws {
        throw XCTSkip("""
            The production callback runs IORegistryEntryCreateCFProperty for \
            BluetoothDeviceAddress + DeviceName from the IOBluetoothDevice \
            io_object_t. From userspace we cannot create a fake \
            io_object_t with arbitrary properties without root + IOService \
            kext. Ring 1 _injectConnect takes the resolved name+address \
            directly. Manual validation: connect a real BT device, verify \
            the published BluetoothDeviceInfo.address matches \
            `system_profiler SPBluetoothDataType` output.
            """)
    }

    func test_l3_gap_kIOFirstMatchNotification_replay_burst_unpostable() throws {
        throw XCTSkip("""
            Like USBSource, BluetoothSource suppresses the boot-time replay \
            burst (one kIOFirstMatchNotification per currently-paired device \
            in the IORegistry). Userspace cannot drive the burst without \
            actually rebooting with N paired devices. Ring 1 covers the \
            isInitialReplay flag's suppress-on-startup logic. Manual \
            validation: launch the app with already-connected BT devices \
            and verify no .bluetoothConnected fires at startup.
            """)
    }
}
