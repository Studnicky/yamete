#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Gyroscope Tuning (collapsible)
//
// Mirror of `AccelTuningSection` for the BMI286 gyroscope. The gyro
// channel measures angular velocity in deg/s rather than g-force, so the
// spike-threshold and rise-rate sliders are formatted as decimal
// magnitudes. Visibility is gated by the caller — this section is
// rendered only when SPU HID hardware is present AND the user has the
// gyroscope source enabled.

internal struct GyroTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_gyro_tuning", comment: "Gyroscope tuning section header"), isExpanded: $isExpanded) {
            GyroTuningContent()
        }
    }
}

// MARK: - Content (used when nesting inside another card)

internal struct GyroTuningContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            GateRows.confirmations($s.gyroConfirmations, bounds: Detection.Gyro.confirmationsRange, lw: lw)
            Divider()
            GateRows.crestFactor($s.gyroCrestFactor, bounds: Detection.Gyro.crestFactorRange, lw: lw)
            Divider()
            SettingRow(icon: "bolt",
                       title: NSLocalizedString("setting_gyro_rise_rate", comment: "Gyro rise rate setting title"),
                       help: NSLocalizedString("help_gyro_rise_rate", comment: "Gyro rise rate setting help text")) {
                SingleSlider(value: $s.gyroRiseRate, bounds: Detection.Gyro.riseRateRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "arrow.up.to.line",
                       title: NSLocalizedString("setting_gyro_spike_threshold", comment: "Gyro spike threshold setting title"),
                       help: NSLocalizedString("help_gyro_spike_threshold", comment: "Gyro spike threshold setting help text")) {
                SingleSlider(value: $s.gyroSpikeThreshold, bounds: Detection.Gyro.spikeThresholdRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            GateRows.warmup($s.gyroWarmupSamples, bounds: Detection.Gyro.warmupRange, lw: lw)
        }
        .padding(Theme.accordionInner)
    }
}
