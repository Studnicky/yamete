import Foundation
@testable import YameteCore
@testable import SensorKit
@testable import YameteApp

/// Test-only protocol: any stimulus source that exposes the `_testEmit` seam.
/// `swift test` always builds with DEBUG, so the `#if DEBUG` blocks on each
/// source are active.
#if DEBUG
public protocol TestEmitter: AnyObject {
    @MainActor
    func _testEmit(_ kind: ReactionKind) async
}

extension USBSource: TestEmitter {}
extension PowerSource: TestEmitter {}
extension AudioPeripheralSource: TestEmitter {}
extension BluetoothSource: TestEmitter {}
extension ThunderboltSource: TestEmitter {}
extension DisplayHotplugSource: TestEmitter {}
extension SleepWakeSource: TestEmitter {}
extension TrackpadActivitySource: TestEmitter {}
extension MouseActivitySource: TestEmitter {}
extension KeyboardActivitySource: TestEmitter {}
#endif

/// Description of one stimulus source for matrix-style scenario tests.
struct SourceContract: Sendable {
    let id: SensorID
    let emittedKinds: [ReactionKind]
    let isStateful: Bool

    /// All 10 stimulus sources, exhaustively listing every reaction kind each
    /// one can publish. Used by the looping integration tests.
    static let all: [SourceContract] = [
        SourceContract(id: .usb, emittedKinds: [.usbAttached, .usbDetached], isStateful: true),
        SourceContract(id: .power, emittedKinds: [.acConnected, .acDisconnected], isStateful: true),
        SourceContract(id: .audioPeripheral, emittedKinds: [.audioPeripheralAttached, .audioPeripheralDetached], isStateful: true),
        SourceContract(id: .bluetooth, emittedKinds: [.bluetoothConnected, .bluetoothDisconnected], isStateful: true),
        SourceContract(id: .thunderbolt, emittedKinds: [.thunderboltAttached, .thunderboltDetached], isStateful: true),
        SourceContract(id: .displayHotplug, emittedKinds: [.displayConfigured], isStateful: false),
        SourceContract(id: .sleepWake, emittedKinds: [.willSleep, .didWake], isStateful: true),
        SourceContract(id: .trackpadActivity,
                       emittedKinds: [.trackpadTouching, .trackpadSliding, .trackpadContact, .trackpadTapping, .trackpadCircling],
                       isStateful: true),
        SourceContract(id: .mouseActivity, emittedKinds: [.mouseClicked, .mouseScrolled], isStateful: true),
        SourceContract(id: .keyboardActivity, emittedKinds: [.keyboardTyped], isStateful: true),
        // GyroscopeSource is intentionally NOT a StimulusSource conformer:
        // its handler runs on the broker's HID worker thread (non-MainActor),
        // and the protocol is `@MainActor`. The bus-routing contract tests
        // therefore exclude it; its kind (.gyroSpike) is enumerated via the
        // `nonContractKinds` accessor below and accounted for by the
        // dedicated `MatrixGyroscopeSource_Tests` matrix cells instead.
    ]

    /// `ReactionKind`s that are emitted by sources NOT covered by
    /// `SourceContract.all`. Includes `.gyroSpike` (direct-publish from
    /// `GyroscopeSource`) and `.lidOpened` / `.lidClosed` /
    /// `.lidSlammed` (direct-publish from `LidAngleSource`). Both
    /// sources subscribe to the `AppleSPUDevice` broker, whose
    /// HID-callback handler runs off the main actor — they cannot
    /// conform to the `@MainActor`-isolated `StimulusSource` protocol.
    /// The exhaustiveness test in `SourceRegistryTests` unions this
    /// with the contract emissions when checking that every non-impact
    /// kind has a producer.
    static let nonContractKinds: Set<ReactionKind> = [.gyroSpike, .lidOpened, .lidClosed, .lidSlammed]

    /// Builds a fresh, unstarted source instance for the given SensorID.
    /// Returns nil if the ID is not a stimulus source.
    @MainActor
    /// Construct a stimulus source for matrix tests. Sources backed by real
    /// NSEvent global monitors / IOHIDManager callbacks (Trackpad/Mouse/
    /// Keyboard) get a `MockEventMonitor` injection so ambient OS input
    /// during the test window doesn't double-count emissions. The test
    /// drives every emission via `_testEmit`, which goes straight to the
    /// bus regardless of the monitor — the mock just prevents extra
    /// hardware callbacks from firing concurrently.
    static func makeSource(for id: SensorID) -> (any StimulusSource)? {
        switch id {
        case .usb:              return USBSource()
        case .power:            return PowerSource()
        case .audioPeripheral:  return AudioPeripheralSource()
        case .bluetooth:        return BluetoothSource()
        case .thunderbolt:      return ThunderboltSource()
        case .displayHotplug:   return DisplayHotplugSource()
        case .sleepWake:        return SleepWakeSource()
        case .trackpadActivity: return TrackpadActivitySource(eventMonitor: MockEventMonitor())
        case .mouseActivity:    return MouseActivitySource(eventMonitor: MockEventMonitor(), enableHIDClickDetection: false)
        case .keyboardActivity: return KeyboardActivitySource(enableHIDDetection: false)
        default:                return nil
        }
    }
}
