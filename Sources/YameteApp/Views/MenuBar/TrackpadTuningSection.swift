#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Trackpad Tuning (collapsible)

internal struct TrackpadTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_trackpad_tuning", comment: "Trackpad tuning section header"), isExpanded: $isExpanded) {
            TrackpadTuningContent()
        }
    }
}

// MARK: - Content (used by StimuliSection trackpad card)

internal struct TrackpadTuningContent: View {
    @Environment(SettingsStore.self) var settings

    // "2.5/s" format for tap-rate sliders
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

            // Scroll / swipe sensitivity range
            EnableToggleRow(icon: "hand.draw",
                            title: NSLocalizedString("setting_trackpad_scroll", comment: "Scroll sensitivity range title"),
                            isOn: $s.trackpadSlidingEnabled)
            SettingRow(icon: "hand.draw",
                       title: NSLocalizedString("setting_trackpad_scroll", comment: "Scroll sensitivity range title"),
                       help: NSLocalizedString("help_trackpad_scroll", comment: "Scroll sensitivity range help")) {
                RangeSlider(low: $s.trackpadScrollMin, high: $s.trackpadScrollMax,
                            bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
            }
            Divider()

            // Finger contact duration range
            EnableToggleRow(icon: "hand.point.up.left",
                            title: NSLocalizedString("setting_trackpad_contact", comment: "Contact duration range title"),
                            isOn: $s.trackpadContactEnabled)
            SettingRow(icon: "hand.point.up.left",
                       title: NSLocalizedString("setting_trackpad_contact", comment: "Contact duration range title"),
                       help: NSLocalizedString("help_trackpad_contact", comment: "Contact duration range help")) {
                RangeSlider(low: $s.trackpadContactMin, high: $s.trackpadContactMax,
                            bounds: 0.1...5.0, labelWidth: lw, format: Fmt.seconds)
            }
            Divider()

            // Tap rate range
            EnableToggleRow(icon: "hand.tap",
                            title: NSLocalizedString("setting_trackpad_tap", comment: "Tap rate range title"),
                            isOn: $s.trackpadTappingEnabled)
            SettingRow(icon: "hand.tap",
                       title: NSLocalizedString("setting_trackpad_tap", comment: "Tap rate range title"),
                       help: NSLocalizedString("help_trackpad_tap", comment: "Tap rate range help")) {
                RangeSlider(low: $s.trackpadTapMin, high: $s.trackpadTapMax,
                            bounds: 0.5...10.0, labelWidth: lw, format: tapsPerSec)
            }
            Divider()

            // Circle detection (toggle only, no slider)
            EnableToggleRow(icon: "arrow.clockwise.circle",
                            title: NSLocalizedString("setting_trackpad_circle", comment: "Circle gesture detection toggle"),
                            isOn: $s.trackpadCirclingEnabled,
                            iconColor: s.trackpadCirclingEnabled ? Theme.pink : Color.secondary.opacity(0.5))
            Text(NSLocalizedString("help_trackpad_circle", comment: "Circle gesture fires long moan at max volume"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(Theme.accordionInner)
    }
}
