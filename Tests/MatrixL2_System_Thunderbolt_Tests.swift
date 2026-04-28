import XCTest
@testable import YameteCore
@testable import SensorKit

/// Ring 2 onion-skin for `ThunderboltSource` — DOCUMENTED RING 3 GAP.
///
/// `ThunderboltSource` subscribes to IOKit `IOThunderboltPort` lifecycle via
/// `IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
/// IOServiceMatching("IOThunderboltPort"), ...)` and the matching
/// `kIOTerminatedNotification`. The transport layer is a kernel mach-port
/// from the `IOThunderboltFamily` driver. Userspace cannot synthesize these
/// notifications — there is no `NSNotificationCenter` mirror, and no
/// public Thunderbolt framework on macOS.
///
/// Why this is a TRANSPORT-LAYER gap, not a logic-layer gap:
///   Ring 1 (`Tests/MatrixThunderboltSource_Tests.swift`) drives
///   `_injectAttach` / `_injectDetach`, which yield through the SAME
///   `AsyncStream` continuation the IOKit callback yields into.
///
/// Manual validation procedure for the transport layer:
///   1. Build & run the app on a Thunderbolt-equipped Mac.
///   2. Plug in a Thunderbolt device (e.g. Apple Pro Display XDR, or
///      a Thunderbolt dock). Observe one `.thunderboltAttached` with
///      the IORegistry IOName for the port.
///   3. Unplug. Observe one `.thunderboltDetached`.
///   4. NOTE: Apple silicon Macs may surface Thunderbolt ports as
///      `IOThunderboltSwitchType3` instead of `IOThunderboltPort`.
///      The current source matches only `IOThunderboltPort` — verify
///      whichever class the host machine actually publishes via
///      `ioreg -l | grep -i thunderbolt`.
@MainActor
final class MatrixL2_System_Thunderbolt_Tests: XCTestCase {

    func test_l3_gap_iothunderboltport_iokit_notification_unpostable() throws {
        throw XCTSkip("""
            ThunderboltSource subscribes to IOServiceAddMatchingNotification \
            on IOServiceMatching("IOThunderboltPort"). Mach-port notifications \
            from the IOThunderboltFamily kernel driver cannot be synthesized \
            from userspace — there is no NSNotificationCenter or public \
            Thunderbolt framework. Ring 1 _injectAttach/_injectDetach covers \
            the production handler logic (AsyncStream drainer + bus.publish). \
            Transport-layer-only gap.
            """)
    }

    func test_l3_gap_io_iterator_next_unpostable() throws {
        throw XCTSkip("""
            The production callback runs IOIteratorNext + \
            IORegistryEntryCreateCFProperty("IOName") to resolve port name \
            from the io_object_t. The io_iterator_t is kernel-supplied and \
            cannot be synthesized from userspace. Ring 1 _injectAttach takes \
            the resolved name string directly. Manual validation: confirm \
            published .thunderboltAttached.name matches the device's IOName \
            in `ioreg -c IOThunderboltPort`.
            """)
    }

    func test_l3_gap_iothunderboltswitchtype3_class_mismatch_unobservable() throws {
        throw XCTSkip("""
            On Apple silicon, Thunderbolt ports may register under \
            IOThunderboltSwitchType3 instead of IOThunderboltPort. The \
            production source only matches the latter — a class-mismatch \
            gap. From userspace we cannot toggle which class the kernel \
            publishes. Ring 1 cannot cover this either (it bypasses the \
            matching dictionary). Manual validation: on Apple silicon, run \
            `ioreg -l | grep -i thunderbolt`, identify the actual class, \
            and if it's not IOThunderboltPort, file a bug.
            """)
    }

    func test_l3_gap_kIOFirstMatchNotification_replay_burst_unpostable() throws {
        throw XCTSkip("""
            Like USB and Bluetooth, ThunderboltSource suppresses the boot-time \
            replay burst. Userspace cannot drive the burst without rebooting \
            with N attached TB devices. Ring 1 covers the isInitialReplay \
            flag. Manual validation: launch the app with a TB dock attached \
            and verify no .thunderboltAttached fires at startup.
            """)
    }
}
