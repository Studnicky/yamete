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
    ]

    /// Builds a fresh, unstarted source instance for the given SensorID.
    /// Returns nil if the ID is not a stimulus source.
    @MainActor
    static func makeSource(for id: SensorID) -> (any StimulusSource)? {
        switch id {
        case .usb:              return USBSource()
        case .power:            return PowerSource()
        case .audioPeripheral:  return AudioPeripheralSource()
        case .bluetooth:        return BluetoothSource()
        case .thunderbolt:      return ThunderboltSource()
        case .displayHotplug:   return DisplayHotplugSource()
        case .sleepWake:        return SleepWakeSource()
        case .trackpadActivity: return TrackpadActivitySource()
        case .mouseActivity:    return MouseActivitySource()
        case .keyboardActivity: return KeyboardActivitySource()
        default:                return nil
        }
    }
}
