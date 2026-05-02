import Foundation
@testable import YameteCore
@testable import ResponseKit

/// Test `OutputConfigProvider`. Each conforming method returns a public
/// mutable struct so individual tests can mutate fields directly to drive
/// shouldFire decisions.
///
/// Defaults mirror `SettingsStore.xConfig()` factory output for an enabled,
/// sane-defaults install: every output enabled, every reaction kind allowed.
@MainActor
final class MockConfigProvider: OutputConfigProvider {

    var audio = AudioOutputConfig(
        enabled: true,
        volumeMin: 0.5,
        volumeMax: 1.0,
        deviceUIDs: [],
        perReaction: MockConfigProvider.allKindsEnabled()
    )

    var flash = FlashOutputConfig(
        enabled: true,
        opacityMin: 0.3,
        opacityMax: 1.0,
        enabledDisplayIDs: [],
        perReaction: MockConfigProvider.allKindsEnabled(),
        dismissAfter: 3.0,
        activeDisplayOnly: false
    )

    var notification = NotificationOutputConfig(
        enabled: true,
        perReaction: MockConfigProvider.allKindsEnabled(),
        dismissAfter: 3.0,
        localeID: "en"
    )

    var led = LEDOutputConfig(
        enabled: true,
        brightnessMin: 0.3,
        brightnessMax: 1.0,
        keyboardBrightnessEnabled: true,
        perReaction: MockConfigProvider.allKindsEnabled()
    )

    var haptic = HapticOutputConfig(
        enabled: true,
        intensity: 1.0,
        perReaction: MockConfigProvider.allKindsEnabled()
    )

    var displayBrightness = DisplayBrightnessOutputConfig(
        enabled: true,
        boost: 0.5,
        threshold: 0.0,
        perReaction: MockConfigProvider.allKindsEnabled()
    )

    var displayTint = DisplayTintOutputConfig(
        enabled: true,
        intensity: 0.5,
        perReaction: MockConfigProvider.allKindsEnabled()
    )

    var volumeSpike = VolumeSpikeOutputConfig(
        enabled: true,
        targetVolume: 0.9,
        threshold: 0.0,
        perReaction: MockConfigProvider.allKindsEnabled()
    )

    var trackpadSource = TrackpadSourceConfig(
        windowDuration: 1.5,
        scrollMin: 0.1, scrollMax: 0.8,
        contactMin: 0.5, contactMax: 2.5,
        tapMin: 2.0, tapMax: 6.0
    )

    func audioConfig() -> AudioOutputConfig { audio }
    func flashConfig() -> FlashOutputConfig { flash }
    func notificationConfig() -> NotificationOutputConfig { notification }
    func ledConfig() -> LEDOutputConfig { led }
    func hapticConfig() -> HapticOutputConfig { haptic }
    func displayBrightnessConfig() -> DisplayBrightnessOutputConfig { displayBrightness }
    func displayTintConfig() -> DisplayTintOutputConfig { displayTint }
    func volumeSpikeConfig() -> VolumeSpikeOutputConfig { volumeSpike }
    func trackpadSourceConfig() -> TrackpadSourceConfig { trackpadSource }

    /// Sets `perReaction[kind] = false` on every config so every output blocks
    /// the given kind regardless of which output type is consulted.
    func block(kind: ReactionKind) {
        audio.perReaction[kind] = false
        flash.perReaction[kind] = false
        notification.perReaction[kind] = false
        led.perReaction[kind] = false
        haptic.perReaction[kind] = false
        displayBrightness.perReaction[kind] = false
        displayTint.perReaction[kind] = false
        volumeSpike.perReaction[kind] = false
    }

    static func allKindsEnabled() -> [ReactionKind: Bool] {
        var dict: [ReactionKind: Bool] = [:]
        for k in ReactionKind.allCases { dict[k] = true }
        return dict
    }
}
