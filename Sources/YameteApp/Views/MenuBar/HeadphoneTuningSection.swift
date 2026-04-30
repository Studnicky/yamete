#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Headphone Tuning (collapsible)

internal struct HeadphoneTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"), isExpanded: $isExpanded) {
            HeadphoneTuningContent()
        }
    }
}

// MARK: - Content (used by SensorSection sensor card)

internal struct HeadphoneTuningContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        VStack(spacing: 10) {
            GateRows.confirmations($s.hpConfirmations, bounds: Detection.Headphone.confirmationsRange, lw: lw)
            Divider()
            GateRows.crestFactor($s.hpCrestFactor, bounds: Detection.Headphone.crestFactorRange, lw: lw)
            Divider()
            SettingRow(icon: "bolt",
                       title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                       help: NSLocalizedString("help_hp_rise_rate", comment: "Headphone rise rate help text")) {
                SingleSlider(value: $s.hpRiseRate, bounds: Detection.Headphone.riseRateRange,
                             labelWidth: lw, format: Fmt.gforce)
            }
            Divider()
            SettingRow(icon: "arrow.up.to.line",
                       title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                       help: NSLocalizedString("help_hp_spike_threshold", comment: "Headphone spike threshold help text")) {
                SingleSlider(value: $s.hpSpikeThreshold, bounds: Detection.Headphone.spikeThresholdRange,
                             labelWidth: lw, format: Fmt.gforce)
            }
            Divider()
            GateRows.warmup($s.hpWarmupSamples, bounds: Detection.Headphone.warmupRange, lw: lw)
        }
        .padding(Theme.accordionInner)
    }
}
