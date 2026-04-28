#if canImport(YameteCore)
import YameteCore
#endif
import SwiftUI

// MARK: - Accelerometer Tuning (collapsible)

internal struct AccelTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"), isExpanded: $isExpanded) {
            AccelTuningContent()
        }
    }
}

// MARK: - Content (used by SensorSection sensor card)

internal struct AccelTuningContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            SettingRow(icon: "waveform.path",
                       title: NSLocalizedString("setting_frequency_band", comment: "Frequency band setting title"),
                       help: NSLocalizedString("help_frequency_band", comment: "Frequency band setting help text")) {
                RangeSlider(low: $s.accelBandpassLowHz, high: $s.accelBandpassHighHz,
                            bounds: Detection.Accel.bandpassRange, labelWidth: lw, format: Fmt.hz)
            }
            Divider()
            GateRows.confirmations($s.accelConfirmations, bounds: Detection.Accel.confirmationsRange, lw: lw)
            Divider()
            GateRows.crestFactor($s.accelCrestFactor, bounds: Detection.Accel.crestFactorRange, lw: lw)
            Divider()
            SettingRow(icon: "clock.arrow.2.circlepath",
                       title: NSLocalizedString("setting_report_interval", comment: "Report interval setting title"),
                       help: NSLocalizedString("help_report_interval", comment: "Report interval setting help text")) {
                SingleSlider(value: $s.accelReportInterval, bounds: Detection.Accel.reportIntervalRange, step: Detection.Accel.reportIntervalStep,
                             labelWidth: lw, format: Fmt.ms)
            }
            Divider()
            SettingRow(icon: "bolt",
                       title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                       help: NSLocalizedString("help_rise_rate", comment: "Rise rate setting help text")) {
                SingleSlider(value: $s.accelRiseRate, bounds: Detection.Accel.riseRateRange,
                             labelWidth: lw, format: Fmt.gforce)
            }
            Divider()
            SettingRow(icon: "arrow.up.to.line",
                       title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                       help: NSLocalizedString("help_spike_threshold", comment: "Spike threshold setting help text")) {
                SingleSlider(value: $s.accelSpikeThreshold, bounds: Detection.Accel.spikeThresholdRange,
                             labelWidth: lw, format: Fmt.gforce)
            }
            Divider()
            GateRows.warmup($s.accelWarmupSamples, bounds: Detection.Accel.warmupRange, lw: lw)
        }
        .padding(Theme.accordionInner)
    }
}
