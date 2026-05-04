#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Lid Tuning (collapsible)
//
// Mirror of `GyroTuningSection` for the BMI286 lid hinge-angle channel.
// Lid is a discrete-state detector (open / closed / slam) so the
// tuning sliders expose the four state-machine knobs:
//   • open threshold (deg)
//   • closed threshold (deg)
//   • slam rate (deg/s, negative)
//   • smoothing window (ms, EMA over Δangle/Δt)
// Visibility is gated by the caller — this section is rendered only
// when SPU HID hardware is present AND the user has the lid-angle
// source enabled.

internal struct LidTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_lid_tuning", comment: "Lid tuning section header"), isExpanded: $isExpanded) {
            LidTuningContent()
        }
    }
}

// MARK: - Content (used when nesting inside another card)

internal struct LidTuningContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            SettingRow(icon: "arrow.up.to.line",
                       title: NSLocalizedString("setting_lid_open_threshold", comment: "Lid open threshold setting title"),
                       help: NSLocalizedString("help_lid_open_threshold", comment: "Lid open threshold setting help text")) {
                SingleSlider(value: $s.lidOpenThresholdDeg, bounds: Detection.Lid.openThresholdDegRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "arrow.down.to.line",
                       title: NSLocalizedString("setting_lid_closed_threshold", comment: "Lid closed threshold setting title"),
                       help: NSLocalizedString("help_lid_closed_threshold", comment: "Lid closed threshold setting help text")) {
                SingleSlider(value: $s.lidClosedThresholdDeg, bounds: Detection.Lid.closedThresholdDegRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "bolt",
                       title: NSLocalizedString("setting_lid_slam_rate", comment: "Lid slam rate setting title"),
                       help: NSLocalizedString("help_lid_slam_rate", comment: "Lid slam rate setting help text")) {
                SingleSlider(value: $s.lidSlamRateDegPerSec, bounds: Detection.Lid.slamRateRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "wave.3.right",
                       title: NSLocalizedString("setting_lid_smoothing", comment: "Lid smoothing window setting title"),
                       help: NSLocalizedString("help_lid_smoothing", comment: "Lid smoothing window setting help text")) {
                SingleSliderInt(value: $s.lidSmoothingWindowMs, bounds: Detection.Lid.smoothingWindowMsRange,
                                labelWidth: lw, format: Fmt.warmupInt)
            }
        }
        .padding(Theme.accordionInner)
    }
}
