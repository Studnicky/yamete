import XCTest
@testable import YameteCore
@testable import SensorKit

/// Ring 2 onion-skin for `PowerSource` — DOCUMENTED RING 3 GAP.
///
/// `PowerSource` subscribes via `IOPSNotificationCreateRunLoopSource`, which
/// returns a `CFRunLoopSource` that fires the registered C callback whenever
/// the kernel power-management subsystem detects an AC plug/unplug or any
/// IOPM-tracked power-source change. The transport layer is the IOPM
/// notification stream — a kernel facility with no
/// `NSNotificationCenter` / `NSWorkspace` mirror. Userspace cannot trigger
/// the callback without root + an actual `IOPMPowerSource` IORegistry write,
/// and even with root that would mutate the host's true AC state for every
/// other process on the system.
///
/// Why this is a TRANSPORT-LAYER gap, not a logic-layer gap:
///   Ring 1 (`Tests/MatrixPowerSource_Tests.swift`) drives `_injectPowerChange`,
///   which calls the SAME `handlePowerChange(onAC:)` edge-trigger the
///   production callback calls after `IOPSCopyPowerSourcesInfo` resolves the
///   AC state. The only path NOT covered is the kernel→userspace runloop
///   notification hop and the `IOPSCopyPowerSourcesInfo` /
///   `IOPSGetProvidingPowerSourceType` snapshot read — both are kernel-mediated.
///
/// Manual validation procedure for the transport layer:
///   1. Build & run the app on a Mac laptop (or a Mac mini with a UPS that
///      surfaces as `kIOPMUPSPowerKey`).
///   2. With AC connected, unplug. Observe one `.acDisconnected` within
///      ~250 ms (the IOPM debounce is system-internal).
///   3. Plug AC back. Observe one `.acConnected`.
///   4. Toggle AC 3x rapidly. Confirm edge-trigger collapses identical
///      consecutive states (e.g. on→on emits nothing).
@MainActor
final class MatrixL2_System_Power_Tests: XCTestCase {

    func test_l3_gap_iopsnotification_runloop_source_unpostable() throws {
        throw XCTSkip("""
            PowerSource subscribes via IOPSNotificationCreateRunLoopSource. \
            The IOPM notification stream is kernel-emitted and not \
            postable from userspace. Ring 1 _injectPowerChange covers the \
            handlePowerChange(onAC:) edge-trigger logic. Transport-layer-only \
            gap. See file header for manual validation procedure.
            """)
    }

    func test_l3_gap_iopscopypowersourcesinfo_unmockable() throws {
        throw XCTSkip("""
            The production callback runs IOPSCopyPowerSourcesInfo + \
            IOPSGetProvidingPowerSourceType to resolve current AC state. \
            Both are kernel-backed reads; userspace cannot mutate their \
            return values without root + IOPMPowerSource write (which \
            would also affect every other process). Ring 1 _injectPowerChange \
            takes the resolved Bool directly. Manual validation: unplug AC \
            and confirm currentlyOnAC() flips before the callback fires.
            """)
    }

    func test_l3_gap_edge_trigger_against_real_state_unobservable() throws {
        throw XCTSkip("""
            The edge-trigger compares against lastWasOnAC seeded from \
            currentlyOnAC() at start. From userspace we cannot drive the \
            REAL power-source change that mutates currentlyOnAC()'s return. \
            Ring 1 _injectPowerChange drives the post-resolution edge-trigger. \
            Manual validation: power-cycle AC and verify the source emits \
            exactly one reaction per real edge.
            """)
    }

    func test_l3_gap_edge_collapse_no_emit_unobservable() throws {
        throw XCTSkip("""
            Real-world: IOPS sometimes re-broadcasts on the same state \
            (e.g. UPS battery threshold change while still onAC). The \
            edge-trigger silently swallows these. From userspace we cannot \
            generate a same-state callback to verify the silent-swallow. \
            Ring 1 _injectPowerChange covers the same-state guard. Manual \
            validation: while on AC, change UPS load and verify no spurious \
            .acConnected fires.
            """)
    }
}
