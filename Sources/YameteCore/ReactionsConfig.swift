import Foundation

/// Centralized constants for the Reaction Bus pipeline. Single tuning surface
/// for per-event default intensities, source debounce windows, bus sizing, and
/// LED pulse timing. Anything you'd want to "tweak" lives here.
public enum ReactionsConfig {

    // MARK: - Per-event synthesized intensity (0–1)

    /// Synthesized intensity each event class fires at. Routes through the
    /// same response math as a real impact (volume band, opacity band,
    /// envelope). Impacts ignore this — they carry their own measured value.
    public static let eventIntensity: [ReactionKind: Float] = [
        .impact:                    1.0,    // unused; impacts carry measured intensity
        .usbAttached:               0.5,
        .usbDetached:               0.3,
        .acConnected:               0.4,
        .acDisconnected:            0.7,
        .audioPeripheralAttached:   0.4,
        .audioPeripheralDetached:   0.3,
        .bluetoothConnected:        0.4,
        .bluetoothDisconnected:     0.3,
        .thunderboltAttached:       0.5,
        .thunderboltDetached:       0.3,
        .displayConfigured:         0.3,
        .willSleep:                 0.2,
        .didWake:                   0.5,
        .trackpadTouching:          0.45,
        .trackpadSliding:           0.65,
        .trackpadContact:           0.40,
        .trackpadTapping:           0.55,
        .trackpadCircling:          1.0,
        .mouseClicked:              0.50,
        .mouseScrolled:             0.40,
        .keyboardTyped:             0.35,
    ]

    // MARK: - Per-source debounce windows

    /// USB attach/detach: macOS often emits 2-3 callbacks during spin-up.
    /// Consumed by `USBSource.shouldPublish`.
    public static let usbDebounce: TimeInterval = 0.05
    /// Display reconfiguration: macOS emits 3-4 callbacks per real change.
    /// Consumed by `DisplayHotplugSource.dispatchDebounced`.
    public static let displayDebounce: TimeInterval = 0.20
    // Note: AudioPeripheralSource (Set-diff dedup), PowerSource (edge-state
    // dedup via `lastWasOnAC`), BluetoothSource and ThunderboltSource (IOKit
    // emits one event per device match/terminate — no rapid-fire pattern in
    // practice) do not use a time-based debounce. If real-world flapping
    // emerges, mirror the USBSource `shouldPublish` pattern and add a
    // dedicated constant here at that time.

    // MARK: - Reaction bus

    /// Per-subscriber buffer depth. Slow consumers drop oldest reactions
    /// rather than blocking publishers (`bufferingNewest(8)`).
    public static let busBufferDepth: Int = 8

    // MARK: - LED pulse

    /// PWM frequency for binary LEDs (Caps Lock). 60Hz approximates an
    /// opacity ramp visually.
    public static let ledPwmHz: Double = 60.0
    /// Duration floor — pulses shorter than this are skipped.
    public static let ledMinPulseDuration: TimeInterval = 0.10
    /// Duration ceiling — clamp to keep Caps Lock state restoration sane.
    public static let ledMaxPulseDuration: TimeInterval = 1.50

    // MARK: - Default response durations for events

    /// Events have no measured clip duration like impacts do. Use this for
    /// the visual / LED envelope when an event has no associated audio clip.
    public static let eventResponseDuration: TimeInterval = 0.6

    // MARK: - Theme color (for LED + visual reuse)

    /// LED pulse color components matching `Theme.pink` (#DD5B85).
    public static let themePinkRGB: (red: Double, green: Double, blue: Double) =
        (red: 0.867, green: 0.357, blue: 0.522)
}
