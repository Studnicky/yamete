#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Ambient Light Tuning (collapsible)
//
// Mirror of `LidTuningSection` for the BMI286 ambient-light channel.
// ALS is a continuous-stream step-change detector so the tuning
// sliders expose the six detector knobs:
//   • cover drop ratio (fraction below baseline counted as covered)
//   • off drop percent (window-rate fraction required for lights-off)
//   • off floor (lux ceiling below which lights-off fires)
//   • on rise percent (window-rate fraction required for lights-on)
//   • on ceiling (lux floor above which lights-on fires)
//   • window (s, time over which step-changes are measured)
// Visibility is gated by the caller — this section is rendered only
// when SPU HID hardware is present AND the user has the ambient-light
// source enabled.

internal struct AmbientLightTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_ambientLight_tuning", comment: "Ambient light tuning section header"), isExpanded: $isExpanded) {
            AmbientLightTuningContent()
        }
    }
}

// MARK: - Content (used when nesting inside another card)

internal struct AmbientLightTuningContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            SettingRow(icon: "hand.raised",
                       title: NSLocalizedString("setting_als_cover_drop", comment: "ALS cover drop setting title"),
                       help: NSLocalizedString("help_als_cover_drop", comment: "ALS cover drop setting help text")) {
                SingleSlider(value: $s.alsCoverDropThreshold, bounds: Detection.AmbientLight.coverDropThresholdRange,
                             labelWidth: lw, format: Fmt.percent)
            }
            Divider()
            SettingRow(icon: "arrow.down.right.circle",
                       title: NSLocalizedString("setting_als_off_percent", comment: "ALS off drop setting title"),
                       help: NSLocalizedString("help_als_off_percent", comment: "ALS off drop setting help text")) {
                SingleSlider(value: $s.alsOffDropPercent, bounds: Detection.AmbientLight.offDropPercentRange,
                             labelWidth: lw, format: Fmt.percent)
            }
            Divider()
            SettingRow(icon: "moon",
                       title: NSLocalizedString("setting_als_off_floor", comment: "ALS off floor setting title"),
                       help: NSLocalizedString("help_als_off_floor", comment: "ALS off floor setting help text")) {
                SingleSlider(value: $s.alsOffFloorLux, bounds: Detection.AmbientLight.offFloorLuxRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "arrow.up.right.circle",
                       title: NSLocalizedString("setting_als_on_percent", comment: "ALS on rise setting title"),
                       help: NSLocalizedString("help_als_on_percent", comment: "ALS on rise setting help text")) {
                SingleSlider(value: $s.alsOnRisePercent, bounds: Detection.AmbientLight.onRisePercentRange,
                             labelWidth: lw, format: Fmt.multiplier)
            }
            Divider()
            SettingRow(icon: "sun.max",
                       title: NSLocalizedString("setting_als_on_ceiling", comment: "ALS on ceiling setting title"),
                       help: NSLocalizedString("help_als_on_ceiling", comment: "ALS on ceiling setting help text")) {
                SingleSlider(value: $s.alsOnCeilingLux, bounds: Detection.AmbientLight.onCeilingLuxRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "clock",
                       title: NSLocalizedString("setting_als_window", comment: "ALS window setting title"),
                       help: NSLocalizedString("help_als_window", comment: "ALS window setting help text")) {
                SingleSlider(value: $s.alsWindowSec, bounds: Detection.AmbientLight.windowSecRange,
                             labelWidth: lw, format: Fmt.seconds)
            }
        }
        .padding(Theme.accordionInner)
    }
}
