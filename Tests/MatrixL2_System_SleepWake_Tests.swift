import XCTest
@testable import YameteCore
@testable import SensorKit

/// Ring 2 onion-skin for `SleepWakeSource` — DOCUMENTED RING 3 GAP.
///
/// CORRECTION TO PLAN: this source was originally classified as Ring
/// 2-testable on the assumption it observed
/// `NSWorkspace.shared.notificationCenter.willSleepNotification` /
/// `.didWakeNotification`. Verified against `Sources/SensorKit/EventSources.swift`
/// (the `SleepWakeSource` class): the production source actually
/// subscribes via `IORegisterForSystemPower(context, &port, callback,
/// &notifier)` and dispatches on `kIOMessageSystemWillSleep` /
/// `kIOMessageSystemHasPoweredOn` from the IOKit power-management
/// callback. There is no `NSWorkspace.didChangeNotification` /
/// `NSWorkspace.willSleepNotification` observer registered in the source.
///
/// Therefore SleepWakeSource is a Ring 3 transport-layer gap, identical
/// in shape to PowerSource: the kernel pmRootDomain emits power-state
/// messages to registered ports, and userspace cannot synthesize them
/// without root + a real `pmset sleep` (which would actually sleep the
/// host machine and lose every other test in the suite).
///
/// Note: posting `NSWorkspace.shared.notificationCenter.post(name:
/// .willSleepNotification, object:...)` is technically possible from
/// userspace, but our source is NOT subscribed to it — the post would be
/// a no-op for our tests. If a future refactor adds an NSWorkspace
/// observer alongside (or in place of) IORegisterForSystemPower, this
/// gap becomes Ring 2-testable; until then it stays Ring 3.
///
/// Why this is a TRANSPORT-LAYER gap, not a logic-layer gap:
///   Ring 1 (`Tests/MatrixSleepWakeSource_Tests.swift`) drives
///   `_injectWillSleep` / `_injectDidWake`, which call the SAME
///   `handleWillSleep()` / `handleDidWake()` the production
///   IORegisterForSystemPower callback calls. The only paths NOT
///   covered are:
///     - the kernel→userspace pmRootDomain notification hop, and
///     - the `IOAllowPowerChange(rootPort, msgArg)` reply the
///       production callback posts back to acknowledge willSleep
///       (the test seam skips this — calling IOAllowPowerChange
///       against a 0 rootPort is undefined).
///
/// Manual validation procedure for the transport layer:
///   1. Build & run the app (`make install`).
///   2. Trigger sleep: `pmset sleepnow`, OR close the lid on a laptop,
///      OR System menu → Sleep. Observe one `.willSleep` published
///      to the bus immediately before the host actually sleeps.
///   3. Wake the host. Observe one `.didWake` published within
///      ~200 ms of wake.
///   4. Repeated wake without sleep: rapid lid open/close where the
///      system never fully sleeps. Observe each
///      `kIOMessageSystemHasPoweredOn` re-broadcast publishes a
///      `.didWake` (the source must tolerate this — Ring 1 covers
///      the no-crash semantic).
@MainActor
final class MatrixL2_System_SleepWake_Tests: XCTestCase {

    func test_l3_gap_ioregisterforsystempower_unpostable_from_userspace() throws {
        throw XCTSkip("""
            SleepWakeSource subscribes via IORegisterForSystemPower, NOT \
            NSWorkspace.shared.notificationCenter. The pmRootDomain \
            kernel power-management broadcast cannot be synthesized from \
            userspace without root + actual `pmset sleep` (which would \
            actually sleep the host). Ring 1 _injectWillSleep/_injectDidWake \
            covers the handleWillSleep/handleDidWake handler logic. \
            Transport-layer-only gap.
            """)
    }

    func test_l3_gap_nsworkspace_willsleep_not_observed_by_source() throws {
        throw XCTSkip("""
            NSWorkspace.shared.notificationCenter.post(name: \
            .willSleepNotification, ...) IS userspace-postable, but \
            SleepWakeSource is NOT subscribed to it — verified by reading \
            EventSources.swift: the source uses IORegisterForSystemPower's \
            C callback exclusively. Therefore an NSWorkspace post would be \
            a no-op for our source. If a future refactor adds an \
            NSWorkspace observer, this cell becomes Ring 2-testable. Ring 1 \
            covers the willSleep handler. Manual validation: pmset sleepnow.
            """)
    }

    func test_l3_gap_ioallowpowerchange_reply_unmockable() throws {
        throw XCTSkip("""
            The production willSleep callback posts \
            IOAllowPowerChange(rootPort, msgArg) to acknowledge the sleep \
            request to the kernel. From userspace we cannot drive a real \
            kIOMessageSystemWillSleep, and Ring 1 _injectWillSleep \
            deliberately SKIPS the IOAllowPowerChange call (rootPort is 0 \
            in tests; calling against a 0 port is undefined). The reply \
            path is the only un-tested production-only behaviour. Manual \
            validation: pmset sleepnow and verify the host actually sleeps \
            (a missing IOAllowPowerChange would veto the sleep).
            """)
    }

    func test_l3_gap_kIOMessageCanSystemSleep_intentionally_unhandled() throws {
        throw XCTSkip("""
            The IORegisterForSystemPower callback also receives \
            kIOMessageCanSystemSleep (~3 kIOMessageSystemWillSleep prequel) \
            which the source DELIBERATELY does not handle (the default \
            `break` branch in the switch). From userspace we cannot drive \
            this message to verify the silent-drop. Ring 1 cannot test \
            this either (the test seam targets handleWillSleep/handleDidWake \
            directly, not the message switch). Manual validation: log the \
            messageType in a debug build and verify only WillSleep + \
            HasPoweredOn drive bus publishes during a real sleep cycle.
            """)
    }

    func test_l3_gap_repeated_didwake_system_semantic_unobservable() throws {
        throw XCTSkip("""
            The system may re-broadcast kIOMessageSystemHasPoweredOn (e.g. \
            after a quick lid open/close that never reached full sleep). \
            From userspace we cannot drive this re-broadcast. Ring 1 \
            testRepeatedDidWake_doesNotCrashAndBothPublish covers the \
            no-crash + both-publish semantic. Manual validation: rapid \
            lid open/close on a MacBook and verify both wakes publish.
            """)
    }
}
