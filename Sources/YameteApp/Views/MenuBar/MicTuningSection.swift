#if canImport(YameteCore)
import YameteCore
#endif
import SwiftUI

// MARK: - Microphone Tuning (collapsible)

internal struct MicTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"), isExpanded: $isExpanded) {
            MicTuningContent()
        }
    }
}

// MARK: - Content (used by SensorSection sensor card)

internal struct MicTuningContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            GateRows.confirmations($s.micConfirmations, bounds: Detection.Mic.confirmationsRange, lw: lw)
            Divider()
            GateRows.crestFactor($s.micCrestFactor, bounds: Detection.Mic.crestFactorRange, lw: lw)
            Divider()
            SettingRow(icon: "bolt",
                       title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                       help: NSLocalizedString("help_mic_rise_rate", comment: "Mic rise rate help text")) {
                SingleSlider(value: $s.micRiseRate, bounds: Detection.Mic.riseRateRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            SettingRow(icon: "arrow.up.to.line",
                       title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                       help: NSLocalizedString("help_mic_spike_threshold", comment: "Mic spike threshold help text")) {
                SingleSlider(value: $s.micSpikeThreshold, bounds: Detection.Mic.spikeThresholdRange,
                             labelWidth: lw, format: Fmt.amplitude)
            }
            Divider()
            GateRows.warmup($s.micWarmupSamples, bounds: Detection.Mic.warmupRange, lw: lw)
        }
        .padding(Theme.accordionInner)
    }
}
