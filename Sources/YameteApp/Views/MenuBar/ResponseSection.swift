#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import SwiftUI

// MARK: - Response (reactivity, sound, visual)

internal struct ResponseSection: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings

        Group {
            // Reactivity — impact force response window
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "gauge.with.needle", title: NSLocalizedString("setting_reactivity", comment: "Reactivity setting title"),
                              help: NSLocalizedString("help_reactivity", comment: "Reactivity setting help text"))
                SensitivityRuler()
                RangeSlider(low: $s.sensitivityMin, high: $s.sensitivityMax,
                            bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
            }
            .padding(Theme.sectionPadding)
            Divider()

            // Sound — audio playback toggle + volume range
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "speaker.wave.2", title: NSLocalizedString("setting_volume", comment: "Volume setting title"),
                                  help: NSLocalizedString("help_volume", comment: "Volume setting help text"))
                    Spacer()
                    Toggle("", isOn: $s.soundEnabled)
                        .themeMiniSwitch()
                }
                if s.soundEnabled {
                    RangeSlider(low: $s.volumeMin, high: $s.volumeMax,
                                bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
                }
            }
            .padding(Theme.sectionPadding)
            Divider()

            // Visual — three-way: off / overlay / notification
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(
                    icon: s.visualResponseMode == .notification ? "bell.badge" : "sun.max",
                    title: NSLocalizedString("setting_visual_response", comment: "Visual response setting title"),
                    help: NSLocalizedString("help_visual_response", comment: "Visual response setting help text"))

                SelectionList(
                    items: [
                        .init(title: NSLocalizedString("response_mode_off", comment: "Visual response off"),
                              subtitle: nil, icon: "moon.zzz", id: VisualResponseMode.off),
                        .init(title: NSLocalizedString("response_mode_overlay", comment: "Screen flash overlay"),
                              subtitle: nil, icon: "sun.max", id: VisualResponseMode.overlay),
                        .init(title: NSLocalizedString("response_mode_notification", comment: "System notification"),
                              subtitle: nil, icon: "bell.badge", id: VisualResponseMode.notification),
                    ],
                    selection: $s.visualResponseMode)
                .onChange(of: s.visualResponseMode) { _, mode in
                    if mode == .notification { NotificationResponder.requestAuthorizationIfNeeded() }
                }

                if s.visualResponseMode == .overlay {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingHeader(
                            icon: "circle.lefthalf.filled",
                            title: NSLocalizedString("setting_flash_opacity", comment: "Flash opacity slider label"),
                            help: NSLocalizedString("help_flash_opacity", comment: "Flash opacity slider help"))
                        RangeSlider(low: $s.flashOpacityMin, high: $s.flashOpacityMax,
                                    bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
                    }
                    .padding(.top, 4)
                }

                if s.visualResponseMode == .notification {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingHeader(
                            icon: "globe",
                            title: NSLocalizedString("setting_notification_locale", comment: "Notification language picker label"),
                            help: NSLocalizedString("help_notification_locale", comment: "Notification language picker help"))
                        NotificationLocalePicker(selection: $s.notificationLocale)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(Theme.sectionPadding)
        }
    }
}
