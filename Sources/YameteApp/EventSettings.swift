#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation

private let log = AppLog(category: "EventSettings")

/// Persisted matrix: `[output × event-class → Bool]`. Stored as a single
/// JSON-encoded `Data` blob per output in `UserDefaults`. The matrix
/// expresses "user wants this output to react to this event class" — orthogonal
/// across outputs, so a user can have sound-only on USB but flash-only on AC
/// unplug. Impacts are always enabled (the master toggles still apply).
public struct ReactionToggleMatrix: Codable, Equatable, Sendable {
    public var values: [String: Bool]

    public init(values: [String: Bool] = [:]) { self.values = values }

    public func enabled(_ kind: ReactionKind) -> Bool {
        // Default to true so a user who's never touched the matrix still gets
        // every reaction. The master per-output toggle (e.g. `soundEnabled`)
        // is the off-switch.
        values[kind.rawValue] ?? true
    }

    public mutating func set(_ kind: ReactionKind, _ enabled: Bool) {
        values[kind.rawValue] = enabled
    }

    public func asDictionary() -> [ReactionKind: Bool] {
        var result: [ReactionKind: Bool] = [:]
        for (key, value) in values {
            if let kind = ReactionKind(rawValue: key) { result[kind] = value }
        }
        return result
    }

    public static func encoded(_ matrix: ReactionToggleMatrix) -> Data {
        do {
            return try JSONEncoder().encode(matrix)
        } catch {
            log.error("activity:ReactionToggleMatrix wasInvalidatedBy activity:Encode — \(error.localizedDescription)")
            return Data()
        }
    }

    public static func decoded(from data: Data) -> ReactionToggleMatrix {
        do {
            return try JSONDecoder().decode(ReactionToggleMatrix.self, from: data)
        } catch {
            log.error("activity:ReactionToggleMatrix wasInvalidatedBy activity:Decode — \(error.localizedDescription)")
            return ReactionToggleMatrix()
        }
    }
}

/// Default-enabled set for fresh installs. All event classes default on; the
/// user toggles individual ones off in the Events section of the menu bar UI.
public enum StimulusSourceDefaults {
    public static let allStimulusSourceIDs: [String] = [
        SensorID.usb.rawValue,
        SensorID.power.rawValue,
        SensorID.audioPeripheral.rawValue,
        SensorID.bluetooth.rawValue,
        SensorID.thunderbolt.rawValue,
        SensorID.displayHotplug.rawValue,
        SensorID.sleepWake.rawValue,
        SensorID.trackpadActivity.rawValue,
        SensorID.mouseActivity.rawValue,
        SensorID.keyboardActivity.rawValue,
        SensorID.gyroscope.rawValue,
    ]
}
