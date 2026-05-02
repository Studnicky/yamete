import XCTest
@testable import YameteCore
@testable import SensorKit

/// Ring 2 onion-skin for `DisplayHotplugSource` — DOCUMENTED RING 3 GAP.
///
/// `DisplayHotplugSource` subscribes via
/// `CGDisplayRegisterReconfigurationCallback(callback, context)`. The
/// transport layer is the WindowServer's display-reconfiguration broadcast,
/// implemented as a private mach-port subscription inside CoreGraphics. It
/// is NOT mirrored on `NSNotificationCenter` (verified: no
/// `CGDisplayDidReconfigureNotification` exists in
/// `<CoreGraphics/CGDisplayConfiguration.h>` or the `NSScreen` headers).
/// `NSApplication.didChangeScreenParametersNotification` IS posted by AppKit
/// for screen changes, but the source DOES NOT subscribe to it (it uses the
/// CG callback for finer-grained reconfigure events with begin/end flags).
///
/// Userspace cannot synthesize a CG reconfigure callback without
/// `CGBeginDisplayConfiguration` + `CGCompleteDisplayConfiguration` (which
/// requires the calling process to OWN the display reconfigure transaction
/// — it does not work as a "post a fake event" path; it triggers a real
/// reconfigure that affects every running app).
///
/// Why this is a TRANSPORT-LAYER gap, not a logic-layer gap:
///   Ring 1 (`Tests/MatrixDisplayHotplugSource_Tests.swift`) drives
///   `_injectReconfigure`, which calls the SAME `dispatchDebounced` the
///   production callback calls after the `.beginConfigurationFlag` filter.
///
/// Manual validation procedure for the transport layer:
///   1. Build & run the app.
///   2. Plug in an external display (or unplug the current one).
///      Observe one `.displayConfigured` within ~200 ms (one debounce
///      window — the CG callback fires 3-4 times per real change and
///      the production debounce collapses them).
///   3. Toggle resolution / refresh rate in System Settings → Displays.
///      Observe one `.displayConfigured`.
///   4. Sleep + wake (lid close/open). Observe a `.displayConfigured`
///      (the WindowServer reconfigures on wake) — verify it's
///      DEBOUNCED against any other reconfigures within 200 ms.
@MainActor
final class MatrixL2_System_DisplayHotplug_Tests: XCTestCase {

    func test_l3_gap_cgdisplay_reconfiguration_callback_unpostable() throws {
        throw XCTSkip("""
            DisplayHotplugSource subscribes via \
            CGDisplayRegisterReconfigurationCallback. The WindowServer's \
            display-reconfiguration broadcast is delivered via a private \
            mach-port subscription inside CoreGraphics, not exposed on \
            NSNotificationCenter. Ring 1 _injectReconfigure covers the \
            dispatchDebounced logic. Transport-layer-only gap.
            """)
    }

    func test_l3_gap_nsscreen_didchange_not_subscribed() throws {
        throw XCTSkip("""
            NSApplication.didChangeScreenParametersNotification IS posted by \
            AppKit on screen changes via NSNotificationCenter, but \
            DisplayHotplugSource does NOT observe it — the CG callback \
            provides finer-grained begin/end flags the AppKit notification \
            lacks. Therefore posting that NSNotification name does not \
            trigger our source. Verified: no addObserver(forName:) for \
            didChangeScreenParametersNotification in EventSources.swift. \
            Manual validation: trigger a screen-resolution change and \
            verify .displayConfigured fires once after the 200 ms debounce.
            """)
    }

    func test_l3_gap_begin_configuration_flag_filter_unobservable() throws {
        throw XCTSkip("""
            The production callback ignores .beginConfigurationFlag callbacks \
            (which fire BEFORE the reconfigure completes). From userspace we \
            cannot drive a real begin-without-end pair to verify the filter \
            silently drops it. Ring 1 _injectReconfigure bypasses the flag \
            check (it always represents a "completed" reconfigure). Manual \
            validation: plug a display, verify exactly one .displayConfigured \
            fires (not 2 — one for begin and one for end).
            """)
    }

    func test_l3_gap_three_to_four_callback_storm_collapse_unobservable() throws {
        throw XCTSkip("""
            Real CG reconfigures fire 3-4 callbacks per single display change \
            (set-mode, set-origin, set-active, etc.). The 200 ms debounce \
            (ReactionsConfig.displayDebounce) collapses them. From userspace \
            we cannot generate the multi-callback storm without driving a \
            real reconfigure. Ring 1 covers the debounce window directly via \
            rapid _injectReconfigure calls. Manual validation: plug a \
            display, count exactly one .displayConfigured publishes.
            """)
    }
}
