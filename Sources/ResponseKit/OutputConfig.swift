#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation

/// Snapshot of every audio-output-relevant setting at the moment of a
/// reaction. Built freshly each tick by the consumer loop in `AudioPlayer`
/// so settings observation lives at the read site.
public struct AudioOutputConfig: Sendable {
    public var enabled: Bool
    public var volumeMin: Float
    public var volumeMax: Float
    public var deviceUIDs: [String]
    public var perReaction: [ReactionKind: Bool]

    public init(enabled: Bool, volumeMin: Float, volumeMax: Float,
                deviceUIDs: [String], perReaction: [ReactionKind: Bool]) {
        self.enabled = enabled
        self.volumeMin = volumeMin
        self.volumeMax = volumeMax
        self.deviceUIDs = deviceUIDs
        self.perReaction = perReaction
    }
}

public struct FlashOutputConfig: Sendable {
    public var enabled: Bool
    public var opacityMin: Float
    public var opacityMax: Float
    public var enabledDisplayIDs: [Int]
    public var perReaction: [ReactionKind: Bool]
    public var dismissAfter: Double
    public var activeDisplayOnly: Bool

    public init(enabled: Bool, opacityMin: Float, opacityMax: Float,
                enabledDisplayIDs: [Int], perReaction: [ReactionKind: Bool],
                dismissAfter: Double, activeDisplayOnly: Bool = false) {
        self.enabled = enabled
        self.opacityMin = opacityMin
        self.opacityMax = opacityMax
        self.enabledDisplayIDs = enabledDisplayIDs
        self.perReaction = perReaction
        self.dismissAfter = dismissAfter
        self.activeDisplayOnly = activeDisplayOnly
    }
}

public struct NotificationOutputConfig: Sendable {
    public var enabled: Bool
    public var perReaction: [ReactionKind: Bool]
    public var dismissAfter: Double
    public var localeID: String

    public init(enabled: Bool, perReaction: [ReactionKind: Bool],
                dismissAfter: Double, localeID: String) {
        self.enabled = enabled
        self.perReaction = perReaction
        self.dismissAfter = dismissAfter
        self.localeID = localeID
    }
}

public struct LEDOutputConfig: Sendable {
    public var enabled: Bool
    public var brightnessMin: Float
    public var brightnessMax: Float
    public var keyboardBrightnessEnabled: Bool
    public var perReaction: [ReactionKind: Bool]

    public init(enabled: Bool, brightnessMin: Float, brightnessMax: Float,
                keyboardBrightnessEnabled: Bool, perReaction: [ReactionKind: Bool]) {
        self.enabled = enabled
        self.brightnessMin = brightnessMin
        self.brightnessMax = brightnessMax
        self.keyboardBrightnessEnabled = keyboardBrightnessEnabled
        self.perReaction = perReaction
    }
}

public struct HapticOutputConfig: Sendable {
    public var enabled: Bool
    /// Pulse density multiplier 0.5–3.0.
    public var intensity: Double
    public var perReaction: [ReactionKind: Bool]

    public init(enabled: Bool, intensity: Double, perReaction: [ReactionKind: Bool]) {
        self.enabled = enabled
        self.intensity = intensity
        self.perReaction = perReaction
    }
}

public struct DisplayBrightnessOutputConfig: Sendable {
    public var enabled: Bool
    /// How much above current to spike, 0.1–1.0.
    public var boost: Double
    /// Minimum intensity to trigger, 0.0–1.0.
    public var threshold: Double
    public var perReaction: [ReactionKind: Bool]

    public init(enabled: Bool, boost: Double, threshold: Double, perReaction: [ReactionKind: Bool]) {
        self.enabled = enabled
        self.boost = boost
        self.threshold = threshold
        self.perReaction = perReaction
    }
}

public struct DisplayTintOutputConfig: Sendable {
    public var enabled: Bool
    /// Tint depth 0.0–1.0.
    public var intensity: Double
    public var perReaction: [ReactionKind: Bool]

    public init(enabled: Bool, intensity: Double, perReaction: [ReactionKind: Bool]) {
        self.enabled = enabled
        self.intensity = intensity
        self.perReaction = perReaction
    }
}

public struct VolumeSpikeOutputConfig: Sendable {
    public var enabled: Bool
    /// Target volume 0.5–1.0.
    public var targetVolume: Double
    /// Minimum intensity to trigger, 0.0–1.0.
    public var threshold: Double
    public var perReaction: [ReactionKind: Bool]

    public init(enabled: Bool, targetVolume: Double, threshold: Double, perReaction: [ReactionKind: Bool]) {
        self.enabled = enabled
        self.targetVolume = targetVolume
        self.threshold = threshold
        self.perReaction = perReaction
    }
}

public struct TrackpadSourceConfig: Sendable {
    /// Scroll/swipe detection window in seconds 0.5–5.0.
    public var windowDuration: Double
    /// Scroll activity fire threshold 0.0–1.0 (lower = more sensitive).
    public var scrollMin: Double
    /// Scroll activity saturation point 0.0–1.0.
    public var scrollMax: Double
    /// Minimum finger-contact duration in seconds before firing 0.1–5.0.
    public var contactMin: Double
    /// Contact duration in seconds at which intensity saturates 0.5–10.0.
    public var contactMax: Double
    /// Tap rate (taps/sec) required to fire 0.5–10.0.
    public var tapMin: Double
    /// Tap rate (taps/sec) at which intensity saturates 1.0–15.0.
    public var tapMax: Double

    public init(windowDuration: Double,
                scrollMin: Double, scrollMax: Double,
                contactMin: Double, contactMax: Double,
                tapMin: Double, tapMax: Double) {
        self.windowDuration = windowDuration
        self.scrollMin = scrollMin
        self.scrollMax = scrollMax
        self.contactMin = contactMin
        self.contactMax = contactMax
        self.tapMin = tapMin
        self.tapMax = tapMax
    }
}

/// Provides live config snapshots to output consumer loops.
///
/// ## Contract
///
/// - All methods are called on MainActor. Conformers must be MainActor-isolated
///   or otherwise safe to call from the main actor.
/// - All methods are **synchronous** and must return immediately without
///   blocking. Implementations must not call `await`, dispatch to other
///   queues, or perform I/O inside these methods.
/// - Returned config structs are **value snapshots**: they capture the state at
///   the moment of the call and are safe to read across suspension points after
///   capture. Callers must re-call to pick up settings changes.
/// - Float range fields (`volumeMin`/`volumeMax`, `opacityMin`/`opacityMax`,
///   `brightnessMin`/`brightnessMax`) follow `Constants.Detection` unit ranges
///   (0.0–1.0). Values outside that range are clamped by `SettingsStore` before
///   reaching this protocol.
/// - These methods are called **on every reaction** that reaches an output
///   consumer. Implementations must be lightweight — linear property reads only,
///   no allocation-heavy work.
///
/// The canonical implementor is `SettingsStore`, which reads directly from
/// `UserDefaults`-backed `@Observable` properties.
@MainActor
public protocol OutputConfigProvider: AnyObject {
    func audioConfig() -> AudioOutputConfig
    func flashConfig() -> FlashOutputConfig
    func notificationConfig() -> NotificationOutputConfig
    func ledConfig() -> LEDOutputConfig
    func hapticConfig() -> HapticOutputConfig
    func displayBrightnessConfig() -> DisplayBrightnessOutputConfig
    func displayTintConfig() -> DisplayTintOutputConfig
    func volumeSpikeConfig() -> VolumeSpikeOutputConfig
    func trackpadSourceConfig() -> TrackpadSourceConfig
}

/// Default clip duration used by outputs when reacting to events (which have
/// no clip — only impacts do).
func reactionDuration(for reaction: Reaction, audioClipDuration: Double) -> Double {
    if case .impact = reaction { return audioClipDuration > 0 ? audioClipDuration : ReactionsConfig.eventResponseDuration }
    return ReactionsConfig.eventResponseDuration
}
