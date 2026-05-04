#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import SwiftUI

// MARK: - Outputs

internal struct ResponseSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(Yamete.self) var yamete

    @State private var audioExpanded  = false
    @State private var flashExpanded  = false
    @State private var notifsExpanded = false
    @State private var ledExpanded    = false
    @State private var hapticExpanded = false
    @State private var brightExpanded = false
    @State private var tintExpanded   = false

    /// Identifier for each output card rendered by this section. Used by tests
    /// to enumerate the per-output parameter keyPaths and assert independence.
    internal enum OutputID: String, CaseIterable, Sendable {
        case audio, flash, notification, keyboardLED, haptic, displayBrightness, displayTint
    }

    /// Pure helper exposed for tests. For an output card, returns every
    /// `SettingsStore` keyPath the card writes through its sliders / toggles.
    /// Single source of truth between rendering and binding-integrity tests.
    @MainActor
    internal static func outputTuningKeyPaths(
        _ id: OutputID
    ) -> [PartialKeyPath<SettingsStore>] {
        switch id {
        case .audio:
            return [\SettingsStore.volumeMin, \SettingsStore.volumeMax]
        case .flash:
            return [\SettingsStore.flashOpacityMin, \SettingsStore.flashOpacityMax]
        case .notification:
            return [\SettingsStore.notificationLocale]
        case .keyboardLED:
            return [\SettingsStore.ledBrightnessMin, \SettingsStore.ledBrightnessMax,
                    \SettingsStore.ledEnabled]
        case .haptic:
            return [\SettingsStore.hapticIntensity]
        case .displayBrightness:
            return [\SettingsStore.displayBrightnessBoost, \SettingsStore.displayBrightnessThreshold]
        case .displayTint:
            return [\SettingsStore.displayTintIntensity]
        }
    }

    @State private var reactionsGroupExpanded: Bool = true

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        SensorAccordionCard(
            title: NSLocalizedString("section_reactions", comment: "Reactions master group title"),
            icon: "waveform.path",
            isEnabled: masterReactionsBinding(),
            isExpanded: $reactionsGroupExpanded,
            help: NSLocalizedString("help_reactions", comment: "Reactions master toggle help")
        ) {
            VStack(spacing: 0) {

            // Audio (includes Volume Override in Direct builds)
            SensorAccordionCard(
                title: NSLocalizedString("setting_volume", comment: "Volume setting title"),
                icon: "speaker.wave.2",
                isEnabled: $s.soundEnabled,
                isExpanded: $audioExpanded,
                help: NSLocalizedString("help_volume", comment: "Volume setting help text")
            ) {
                VStack(spacing: 10) {
                    SettingRow(icon: "speaker",
                               title: NSLocalizedString("setting_volume", comment: "Playback volume range label"),
                               help: NSLocalizedString("help_volume", comment: "Playback volume range help")) {
                        RangeSlider(low: $s.volumeMin, high: $s.volumeMax,
                                    bounds: Detection.unitRange, labelWidth: lw, format: Fmt.percent)
                    }
                    #if DIRECT_BUILD
                    Divider()
                    EnableToggleRow(icon: "speaker.wave.3.fill",
                                    title: NSLocalizedString("setting_volume_spike", comment: "Volume override sub-toggle label"),
                                    isOn: $s.volumeSpikeEnabled,
                                    iconColor: s.volumeSpikeEnabled ? Theme.pink : Color.secondary.opacity(0.5))
                    #endif
                }.padding(Theme.accordionInner)
            }

            // Screen Flash
            SensorAccordionCard(
                title: NSLocalizedString("setting_visual_response_flash", comment: "Screen flash output title"),
                icon: "sun.max",
                isEnabled: $s.flashEnabled,
                isExpanded: $flashExpanded,
                help: NSLocalizedString("help_visual_response_flash", comment: "Screen flash output help text")
            ) {
                VStack(spacing: 10) {
                    SettingRow(icon: "circle.lefthalf.filled",
                               title: NSLocalizedString("setting_flash_opacity", comment: "Flash opacity slider label"),
                               help: NSLocalizedString("help_flash_opacity", comment: "Flash opacity slider help")) {
                        RangeSlider(low: $s.flashOpacityMin, high: $s.flashOpacityMax,
                                    bounds: Detection.unitRange, labelWidth: lw, format: Fmt.percent)
                    }
                }.padding(Theme.accordionInner)
            }

            // Notifications
            SensorAccordionCard(
                title: NSLocalizedString("setting_notifications", comment: "Notification output title"),
                icon: "bell.badge",
                isEnabled: $s.notificationsEnabled,
                isExpanded: $notifsExpanded,
                help: NSLocalizedString("help_notifications", comment: "Notification output help text")
            ) {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        IconLabel(icon: "globe",
                                  title: NSLocalizedString("setting_notification_locale", comment: "Notification language picker label"),
                                  dimmed: true,
                                  iconWidth: 16)
                        Spacer()
                        NotificationLocalePicker(selection: $s.notificationLocale)
                    }
                }.padding(Theme.accordionInner)
            }

            // Keyboard (brightness + Caps Lock LED)
            SensorAccordionCard(
                title: NSLocalizedString("setting_keyboard_leds", comment: "Keyboard LED flash output title"),
                icon: "keyboard.badge.eye",
                isEnabled: $s.keyboardBrightnessEnabled,
                isExpanded: $ledExpanded,
                help: NSLocalizedString("help_keyboard_leds", comment: "Keyboard LED flash output help text")
            ) {
                VStack(spacing: 10) {
                    if yamete.keyboardBacklightAvailable {
                        SettingRow(icon: "slider.horizontal.3",
                                   title: NSLocalizedString("setting_led_brightness", comment: "LED brightness slider label"),
                                   help: NSLocalizedString("help_led_brightness", comment: "LED brightness slider help")) {
                            RangeSlider(low: $s.ledBrightnessMin, high: $s.ledBrightnessMax,
                                        bounds: Detection.unitRange, labelWidth: lw, format: Fmt.percent)
                        }
                        Divider()
                    }
                    EnableToggleRow(icon: "lightbulb.led",
                                    title: NSLocalizedString("setting_led_enabled", comment: "LED flash output title"),
                                    isOn: $s.ledEnabled,
                                    dimmed: true)
                }.padding(Theme.accordionInner)
            }

            // Haptic
            if yamete.hapticAvailable {
                SensorAccordionCard(
                    title: NSLocalizedString("setting_haptic", comment: "Haptic output title"),
                    icon: "waveform",
                    isEnabled: $s.hapticEnabled,
                    isExpanded: $hapticExpanded,
                    help: NSLocalizedString("help_haptic", comment: "Haptic output help text")
                ) {
                    VStack(spacing: 10) {
                        SettingRow(icon: "slider.horizontal.3",
                                   title: NSLocalizedString("setting_haptic_intensity", comment: "Haptic intensity slider label"),
                                   help: NSLocalizedString("help_haptic_intensity", comment: "Haptic intensity slider help")) {
                            SingleSlider(value: $s.hapticIntensity, bounds: 0.5...3.0, labelWidth: lw, format: Fmt.multiplier)
                        }
                    }.padding(Theme.accordionInner)
                }
            }

            // Display Brightness
            if yamete.displayBrightnessAvailable {
                SensorAccordionCard(
                    title: NSLocalizedString("setting_display_brightness", comment: "Display brightness output title"),
                    icon: "sun.max.fill",
                    isEnabled: $s.displayBrightnessEnabled,
                    isExpanded: $brightExpanded,
                    help: NSLocalizedString("help_display_brightness", comment: "Display brightness output help text")
                ) {
                    VStack(spacing: 10) {
                        SettingRow(icon: "arrow.up.to.line",
                                   title: NSLocalizedString("setting_brightness_boost", comment: "Brightness boost slider label"),
                                   help: NSLocalizedString("help_brightness_boost", comment: "Brightness boost slider help")) {
                            SingleSlider(value: $s.displayBrightnessBoost, bounds: 0.1...1.0, labelWidth: lw, format: Fmt.percent)
                        }
                        Divider()
                        SettingRow(icon: "waveform.path.ecg",
                                   title: NSLocalizedString("setting_brightness_threshold", comment: "Brightness threshold slider label"),
                                   help: NSLocalizedString("help_brightness_threshold", comment: "Brightness threshold slider help")) {
                            SingleSlider(value: $s.displayBrightnessThreshold, bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
                        }
                    }.padding(Theme.accordionInner)
                }
            }

            // Screen Tint
            if yamete.displayTintAvailable {
                SensorAccordionCard(
                    title: NSLocalizedString("setting_display_tint", comment: "Display tint output title"),
                    icon: "paintbrush.pointed.fill",
                    isEnabled: $s.displayTintEnabled,
                    isExpanded: $tintExpanded,
                    help: NSLocalizedString("help_display_tint", comment: "Display tint output help text")
                ) {
                    VStack(spacing: 10) {
                        SettingRow(icon: "circle.lefthalf.filled",
                                   title: NSLocalizedString("setting_tint_intensity", comment: "Tint intensity slider label"),
                                   help: NSLocalizedString("help_tint_intensity", comment: "Tint intensity slider help")) {
                            SingleSlider(value: $s.displayTintIntensity, bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
                        }
                    }.padding(Theme.accordionInner)
                }
            }

            }
        }
    }

    /// Override-disable kill switch for the Reactions group. Reads/writes
    /// `settings.reactionsMasterEnabled` only — does NOT mutate any
    /// per-output toggle (`soundEnabled`, `flashEnabled`,
    /// `notificationsEnabled`, `ledEnabled`, `keyboardBrightnessEnabled`,
    /// `hapticEnabled`, `displayBrightnessEnabled`, `displayTintEnabled`).
    /// When `false`, every output's dispatch is gated to disabled
    /// regardless of its per-output toggle and per-reaction matrix entry;
    /// flipping the master back ON releases the override and the user's
    /// individual settings flow through unchanged. The dispatch gate
    /// lives in each output's `shouldFire` (or equivalent) — see the
    /// downstream wiring.
    private func masterReactionsBinding() -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { s.reactionsMasterEnabled },
            set: { newValue in s.reactionsMasterEnabled = newValue }
        )
    }
}
