#if canImport(YameteCore)
import YameteCore
#endif
import SwiftUI

// MARK: - Trackpad Tuning (collapsible)

internal struct TrackpadTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    // "2.5/s" format for tap-rate sliders
    private let tapsPerSec: @Sendable (Double) -> String = {
        String(format: NSLocalizedString("unit_taps_per_sec", comment: "Tap rate format"), $0)
    }

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        AccordionCard(title: NSLocalizedString("section_trackpad_tuning", comment: "Trackpad tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {

                // Activity window — how long the scroll accumulation window is
                SettingRow(icon: "clock",
                           title: NSLocalizedString("setting_trackpad_window", comment: "Trackpad window duration setting title"),
                           help: NSLocalizedString("help_trackpad_window", comment: "Trackpad window duration setting help text")) {
                    SingleSlider(value: $s.trackpadWindowDuration, bounds: 0.5...5.0,
                                 labelWidth: lw, format: Fmt.seconds)
                }
                Divider()

                // Scroll / swipe sensitivity range
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(NSLocalizedString("setting_trackpad_scroll", comment: "Scroll sensitivity range title"))
                        .font(.caption).foregroundStyle(s.trackpadSlidingEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $s.trackpadSlidingEnabled).themeMiniSwitch()
                }
                SettingRow(icon: "hand.draw",
                           title: NSLocalizedString("setting_trackpad_scroll", comment: "Scroll sensitivity range title"),
                           help: NSLocalizedString("help_trackpad_scroll", comment: "Scroll sensitivity range help")) {
                    RangeSlider(low: $s.trackpadScrollMin, high: $s.trackpadScrollMax,
                                bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
                }
                Divider()

                // Finger contact duration range
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(NSLocalizedString("setting_trackpad_contact", comment: "Contact duration range title"))
                        .font(.caption).foregroundStyle(s.trackpadContactEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $s.trackpadContactEnabled).themeMiniSwitch()
                }
                SettingRow(icon: "hand.point.up.left",
                           title: NSLocalizedString("setting_trackpad_contact", comment: "Contact duration range title"),
                           help: NSLocalizedString("help_trackpad_contact", comment: "Contact duration range help")) {
                    RangeSlider(low: $s.trackpadContactMin, high: $s.trackpadContactMax,
                                bounds: 0.1...5.0, labelWidth: lw, format: Fmt.seconds)
                }
                Divider()

                // Tap rate range
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(NSLocalizedString("setting_trackpad_tap", comment: "Tap rate range title"))
                        .font(.caption).foregroundStyle(s.trackpadTappingEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $s.trackpadTappingEnabled).themeMiniSwitch()
                }
                SettingRow(icon: "hand.tap",
                           title: NSLocalizedString("setting_trackpad_tap", comment: "Tap rate range title"),
                           help: NSLocalizedString("help_trackpad_tap", comment: "Tap rate range help")) {
                    RangeSlider(low: $s.trackpadTapMin, high: $s.trackpadTapMax,
                                bounds: 0.5...10.0, labelWidth: lw, format: tapsPerSec)
                }
                Divider()

                // Circle detection toggle (no slider)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(s.trackpadCirclingEnabled ? Theme.pink : Color.secondary.opacity(0.5))
                    Text(NSLocalizedString("setting_trackpad_circle", comment: "Circle gesture detection toggle"))
                        .font(.caption)
                        .foregroundStyle(s.trackpadCirclingEnabled ? .primary : .secondary)
                    Spacer()
                    Toggle("", isOn: $s.trackpadCirclingEnabled).themeMiniSwitch()
                }
                Text(NSLocalizedString("help_trackpad_circle", comment: "Circle gesture fires long moan at max volume"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(Theme.accordionInner)
        }
    }
}

// MARK: - Content (used by StimuliSection trackpad card)

internal struct TrackpadTuningContent: View {
    @Environment(SettingsStore.self) var settings

    private let tapsPerSec: @Sendable (Double) -> String = {
        String(format: NSLocalizedString("unit_taps_per_sec", comment: "Tap rate format"), $0)
    }

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            SettingRow(icon: "clock",
                       title: NSLocalizedString("setting_trackpad_window", comment: "Trackpad window duration setting title"),
                       help: NSLocalizedString("help_trackpad_window", comment: "Trackpad window duration setting help text")) {
                SingleSlider(value: $s.trackpadWindowDuration, bounds: 0.5...5.0,
                             labelWidth: lw, format: Fmt.seconds)
            }
            Divider()

            // Scroll / swipe
            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
                Text(NSLocalizedString("setting_trackpad_scroll", comment: "Scroll sensitivity range title"))
                    .font(.caption).foregroundStyle(s.trackpadSlidingEnabled ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: $s.trackpadSlidingEnabled).themeMiniSwitch()
            }
            SettingRow(icon: "hand.draw",
                       title: NSLocalizedString("setting_trackpad_scroll", comment: "Scroll sensitivity range title"),
                       help: NSLocalizedString("help_trackpad_scroll", comment: "Scroll sensitivity range help")) {
                RangeSlider(low: $s.trackpadScrollMin, high: $s.trackpadScrollMax,
                            bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
            }
            Divider()

            // Contact
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.caption).foregroundStyle(.secondary)
                Text(NSLocalizedString("setting_trackpad_contact", comment: "Contact duration range title"))
                    .font(.caption).foregroundStyle(s.trackpadContactEnabled ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: $s.trackpadContactEnabled).themeMiniSwitch()
            }
            SettingRow(icon: "hand.point.up.left",
                       title: NSLocalizedString("setting_trackpad_contact", comment: "Contact duration range title"),
                       help: NSLocalizedString("help_trackpad_contact", comment: "Contact duration range help")) {
                RangeSlider(low: $s.trackpadContactMin, high: $s.trackpadContactMax,
                            bounds: 0.1...5.0, labelWidth: lw, format: Fmt.seconds)
            }
            Divider()

            // Tapping
            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .font(.caption).foregroundStyle(.secondary)
                Text(NSLocalizedString("setting_trackpad_tap", comment: "Tap rate range title"))
                    .font(.caption).foregroundStyle(s.trackpadTappingEnabled ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: $s.trackpadTappingEnabled).themeMiniSwitch()
            }
            SettingRow(icon: "hand.tap",
                       title: NSLocalizedString("setting_trackpad_tap", comment: "Tap rate range title"),
                       help: NSLocalizedString("help_trackpad_tap", comment: "Tap rate range help")) {
                RangeSlider(low: $s.trackpadTapMin, high: $s.trackpadTapMax,
                            bounds: 0.5...10.0, labelWidth: lw, format: tapsPerSec)
            }
            Divider()

            // Circle detection (toggle only, no slider)
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.caption)
                    .foregroundStyle(s.trackpadCirclingEnabled ? Theme.pink : Color.secondary.opacity(0.5))
                Text(NSLocalizedString("setting_trackpad_circle", comment: "Circle gesture detection toggle"))
                    .font(.caption)
                    .foregroundStyle(s.trackpadCirclingEnabled ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: $s.trackpadCirclingEnabled).themeMiniSwitch()
            }
            Text(NSLocalizedString("help_trackpad_circle", comment: "Circle gesture fires long moan at max volume"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(Theme.accordionInner)
    }
}
