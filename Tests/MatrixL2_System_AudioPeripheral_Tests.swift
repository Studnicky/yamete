import XCTest
@testable import YameteCore
@testable import SensorKit

/// Ring 2 onion-skin for `AudioPeripheralSource` — DOCUMENTED RING 3 GAP.
///
/// `AudioPeripheralSource` subscribes to CoreAudio's device-set property via
/// `AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
/// &kAudioHardwarePropertyDevices, queue, block)`. The transport layer is
/// the CoreAudio HAL property-listener bus — an in-process mach-port-backed
/// notification driven by `coreaudiod` whenever the system-wide audio device
/// set changes. There is NO `NSNotificationCenter` mirror: CoreAudio
/// deliberately does not bridge to NSNotificationCenter (verified via
/// `man AudioHardwareBase` and a grep across `/System/Library/Frameworks/
/// CoreAudio.framework/Headers` — no `NSNotification.Name` declarations).
///
/// Userspace cannot synthesize an `AudioObjectPropertyListenerBlock`
/// invocation without either (a) using a private CoreAudio API to inject a
/// fake device, or (b) actually attaching/detaching audio hardware. Both
/// are out of scope for unit tests.
///
/// Why this is a TRANSPORT-LAYER gap, not a logic-layer gap:
///   Ring 1 (`Tests/MatrixAudioPeripheralSource_Tests.swift`) drives
///   `_injectAttach` / `_injectDetach`, which call the SAME
///   `handleChange(newDevices:names:)` diff-and-emit core the CoreAudio
///   listener block calls after `Self.snapshot()`. The only path not
///   covered is the CoreAudio→userspace property-listener hop and the
///   `AudioObjectGetPropertyData` reads that resolve the new device set
///   from `AudioObjectID`s.
///
/// Manual validation procedure for the transport layer:
///   1. Build & run the app.
///   2. Plug in a USB / Bluetooth audio peripheral (e.g. AirPods).
///      Observe one `.audioPeripheralAttached` with the device's UID
///      and friendly name from `system_profiler SPAudioDataType`.
///   3. Unplug / disconnect. Observe one `.audioPeripheralDetached`.
///   4. Toggle output device in System Settings → Sound. Confirm no
///      spurious attach/detach (only the device SET changing, not the
///      default-output selection, should fire).
@MainActor
final class MatrixL2_System_AudioPeripheral_Tests: XCTestCase {

    func test_l3_gap_coreaudio_property_listener_unpostable() throws {
        throw XCTSkip("""
            AudioPeripheralSource subscribes via \
            AudioObjectAddPropertyListenerBlock on \
            kAudioHardwarePropertyDevices. CoreAudio's HAL property-listener \
            bus is not bridged to NSNotificationCenter — userspace cannot \
            post into it without private API or real hardware. Ring 1 \
            _injectAttach/_injectDetach covers the handleChange(newDevices:) \
            diff-and-emit logic. Transport-layer-only gap. See file header \
            for manual validation procedure.
            """)
    }

    func test_l3_gap_audioobject_snapshot_unmockable() throws {
        throw XCTSkip("""
            The production listener calls Self.snapshot() — \
            AudioObjectGetPropertyData against kAudioHardwarePropertyDevices \
            — to resolve the current AudioDeviceID set, then \
            AudioObjectGetPropertyData per ID for kAudioDevicePropertyDeviceUID. \
            All four calls are HAL reads; userspace cannot fake their \
            results without injecting a virtual driver. Ring 1 _injectAttach \
            takes the post-resolution uid+name directly. Manual validation: \
            verify published .audioPeripheralAttached.uid matches the \
            device's CoreAudio UID.
            """)
    }

    func test_l3_gap_no_nsnotification_mirror_for_avaudiosession() throws {
        throw XCTSkip("""
            On macOS there is no AVAudioSessionRouteChange equivalent — that \
            notification is iOS-only. The macOS audio device set change is \
            CoreAudio-only. Verified: `import AVFoundation` on macOS does \
            not expose AVAudioSession.routeChangeNotification. Therefore \
            posting to NSNotificationCenter for any audio notification name \
            would not trigger AudioPeripheralSource. Ring 1 covers the \
            handler logic. Manual validation: connect AirPods and verify \
            attach fires.
            """)
    }

    func test_l3_gap_initial_snapshot_replay_unobservable() throws {
        throw XCTSkip("""
            On start(), the source seeds knownDevices with Self.snapshot() — \
            so already-connected devices DO NOT generate attach reactions. \
            From userspace we cannot drive a "boot with N devices already \
            attached" scenario without actually rebooting with N devices. \
            Ring 1 _testSeedKnownDevices seeds the baseline directly. Manual \
            validation: launch the app with AirPods already connected; \
            verify no .audioPeripheralAttached fires at startup.
            """)
    }
}
