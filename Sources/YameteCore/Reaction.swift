import Foundation

// MARK: - FusedImpact

/// A consensus-fused impact ready for response. Owned by `YameteCore` so any
/// consumer can pattern-match it without importing `SensorKit`.
public struct FusedImpact: Sendable {
    public let timestamp: Date
    /// Average peak intensity across participating sources (0–1).
    public let intensity: Float
    /// Fraction of currently-active sensor sources that participated.
    public let confidence: Float
    /// Sensor IDs that contributed.
    public let sources: [SensorID]

    public init(timestamp: Date, intensity: Float, confidence: Float, sources: [SensorID]) {
        self.timestamp = timestamp
        self.intensity = intensity
        self.confidence = confidence
        self.sources = sources
    }
}

// MARK: - Cable / device payloads

public struct USBDeviceInfo: Sendable, Equatable {
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public init(name: String, vendorID: Int, productID: Int) {
        self.name = name; self.vendorID = vendorID; self.productID = productID
    }
}

public struct AudioPeripheralInfo: Sendable, Equatable {
    public let uid: String
    public let name: String
    public init(uid: String, name: String) {
        self.uid = uid; self.name = name
    }
}

public struct BluetoothDeviceInfo: Sendable, Equatable {
    public let address: String
    public let name: String
    public init(address: String, name: String) {
        self.address = address; self.name = name
    }
}

public struct ThunderboltDeviceInfo: Sendable, Equatable {
    public let name: String
    public init(name: String) { self.name = name }
}

// MARK: - Reaction (unified envelope)

/// Every observable event the app responds to. Impacts are events; cable plug
/// events are events. Outputs pattern-match exhaustively.
public enum Reaction: Sendable {
    case impact(FusedImpact)
    case usbAttached(USBDeviceInfo)
    case usbDetached(USBDeviceInfo)
    case acConnected
    case acDisconnected
    case audioPeripheralAttached(AudioPeripheralInfo)
    case audioPeripheralDetached(AudioPeripheralInfo)
    case bluetoothConnected(BluetoothDeviceInfo)
    case bluetoothDisconnected(BluetoothDeviceInfo)
    case thunderboltAttached(ThunderboltDeviceInfo)
    case thunderboltDetached(ThunderboltDeviceInfo)
    case displayConfigured
    case willSleep
    case didWake
    case trackpadTouching    // sliding window threshold crossed — sustained touch activity
    case trackpadSliding     // high-velocity sustained scroll/drag detected
    case trackpadContact     // fingers resting on trackpad — sustained contact detected via scroll phase
    case trackpadTapping     // rapid tap frequency threshold crossed
    case trackpadCircling    // finger traces ≥1 full revolution on trackpad
    case mouseClicked   // primary button click from a non-trackpad mouse
    case mouseScrolled  // sustained scroll-wheel activity from a mouse
    case keyboardTyped  // keyboard typing rate threshold crossed
    case gyroSpike      // angular velocity spike from the BMI286 gyroscope
    case lidOpened      // hinge angle crossed the open threshold from below
    case lidClosed      // hinge angle dropped below the closed threshold gently
    case lidSlammed     // hinge angle dropped below the closed threshold at slam rate
    case alsCovered     // ambient light sensor occluded — fast drop with floor near zero
    case lightsOff      // ambient lux dropped sharply over the configured window
    case lightsOn       // ambient lux rose sharply over the configured window
    case thermalNominal   // ProcessInfo.thermalState transitioned to .nominal
    case thermalFair      // ProcessInfo.thermalState transitioned to .fair
    case thermalSerious   // ProcessInfo.thermalState transitioned to .serious
    case thermalCritical  // ProcessInfo.thermalState transitioned to .critical

    /// Payload-less mirror used as a settings dictionary key.
    public var kind: ReactionKind {
        switch self {
        case .impact:                   .impact
        case .usbAttached:              .usbAttached
        case .usbDetached:              .usbDetached
        case .acConnected:              .acConnected
        case .acDisconnected:           .acDisconnected
        case .audioPeripheralAttached:  .audioPeripheralAttached
        case .audioPeripheralDetached:  .audioPeripheralDetached
        case .bluetoothConnected:       .bluetoothConnected
        case .bluetoothDisconnected:    .bluetoothDisconnected
        case .thunderboltAttached:      .thunderboltAttached
        case .thunderboltDetached:      .thunderboltDetached
        case .displayConfigured:        .displayConfigured
        case .willSleep:                .willSleep
        case .didWake:                  .didWake
        case .trackpadTouching:         .trackpadTouching
        case .trackpadSliding:          .trackpadSliding
        case .trackpadContact:          .trackpadContact
        case .trackpadTapping:          .trackpadTapping
        case .trackpadCircling:         .trackpadCircling
        case .mouseClicked:             .mouseClicked
        case .mouseScrolled:            .mouseScrolled
        case .keyboardTyped:            .keyboardTyped
        case .gyroSpike:                .gyroSpike
        case .lidOpened:                .lidOpened
        case .lidClosed:                .lidClosed
        case .lidSlammed:               .lidSlammed
        case .alsCovered:               .alsCovered
        case .lightsOff:                .lightsOff
        case .lightsOn:                 .lightsOn
        case .thermalNominal:           .thermalNominal
        case .thermalFair:              .thermalFair
        case .thermalSerious:           .thermalSerious
        case .thermalCritical:          .thermalCritical
        }
    }

    /// Timestamp the reaction was observed.
    /// - For `.impact`: returns the fused-impact timestamp (accurate, stored at detection time).
    /// - For all other cases: **do not use this accessor** — it returns a fresh `Date()` on every
    ///   call and is therefore unreliable. Use `FiredReaction.publishedAt` instead, which is
    ///   stamped once by `ReactionBus.publish(_:)` before fan-out.
    public var timestamp: Date {
        if case .impact(let f) = self { return f.timestamp }
        return Date()
    }

    /// 0–1 intensity. Impacts use measured intensity; events use the
    /// configured per-class synthesized intensity from `ReactionsConfig`.
    public var intensity: Float {
        if case .impact(let f) = self { return f.intensity }
        return ReactionsConfig.eventIntensity[kind] ?? 0.5
    }
}

// MARK: - Sensitivity gating

extension FusedImpact {
    /// Maps raw 0–1 intensity through the user's sensitivity band. Returns
    /// `nil` when the impact is below the lower threshold (rejected). When
    /// it passes, returns the linearly-remapped intensity inside `0...1`.
    ///
    /// Sensitivity is inverted to thresholds: high sensitivity → low
    /// threshold → more reactive.
    public static func applySensitivity(rawIntensity: Float, sensitivityMin: Float, sensitivityMax: Float) -> Float? {
        let thresholdLow = 1.0 - sensitivityMax
        let thresholdHigh = 1.0 - sensitivityMin
        guard rawIntensity >= thresholdLow else { return nil }
        let bandWidth = max(Float(0.001), thresholdHigh - thresholdLow)
        return ((rawIntensity - thresholdLow) / bandWidth).clamped(to: 0...1)
    }
}

/// Payload-stripped enum used as `[ReactionKind: …]` keys for per-output
/// × per-event toggle matrices.
public enum ReactionKind: String, CaseIterable, Sendable, Codable {
    case impact
    case usbAttached, usbDetached
    case acConnected, acDisconnected
    case audioPeripheralAttached, audioPeripheralDetached
    case bluetoothConnected, bluetoothDisconnected
    case thunderboltAttached, thunderboltDetached
    case displayConfigured
    case willSleep, didWake
    case trackpadTouching
    case trackpadSliding
    case trackpadContact
    case trackpadTapping
    case trackpadCircling
    case mouseClicked
    case mouseScrolled
    case keyboardTyped
    case gyroSpike
    case lidOpened
    case lidClosed
    case lidSlammed
    case alsCovered
    case lightsOff
    case lightsOn
    case thermalNominal
    case thermalFair
    case thermalSerious
    case thermalCritical
}
