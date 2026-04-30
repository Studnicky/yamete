#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Sensors & Detection

/// Displays one SensorAccordionCard per available sensor.
/// Each card has an enable/disable toggle in the header and the full
/// tuning configuration in the expanded body — no nested accordions.
/// Shared detection settings (consensus, cooldown) appear below.
internal struct SensorSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(Yamete.self) var yamete
    let availableSensors: [String]

    @State private var accelExpanded = false
    @State private var micExpanded   = false
    @State private var hpExpanded    = false

    /// Pure helper exposed for tests. For a sensor, returns the keyPaths of
    /// every detection-tuning parameter the section binds in its expanded
    /// content. Used by binding-integrity tests to assert no parameter from
    /// one sensor bleeds into another sensor's tuning.
    @MainActor
    internal static func sensorTuningKeyPaths(
        _ id: SensorID
    ) -> [PartialKeyPath<SettingsStore>] {
        if id == .accelerometer {
            return [
                \SettingsStore.accelBandpassLowHz, \SettingsStore.accelBandpassHighHz,
                \SettingsStore.accelConfirmations, \SettingsStore.accelCrestFactor,
                \SettingsStore.accelReportInterval, \SettingsStore.accelRiseRate,
                \SettingsStore.accelSpikeThreshold, \SettingsStore.accelWarmupSamples,
            ]
        }
        if id == .microphone {
            return [
                \SettingsStore.micConfirmations, \SettingsStore.micCrestFactor,
                \SettingsStore.micRiseRate, \SettingsStore.micSpikeThreshold,
                \SettingsStore.micWarmupSamples,
            ]
        }
        if id == .headphoneMotion {
            return [
                \SettingsStore.hpConfirmations, \SettingsStore.hpCrestFactor,
                \SettingsStore.hpRiseRate, \SettingsStore.hpSpikeThreshold,
                \SettingsStore.hpWarmupSamples,
            ]
        }
        return []
    }

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth
        let enabledCount = availableSensors.filter { s.enabledSensorIDs.contains($0) }.count

        VStack(spacing: 0) {
            // Reactivity controls: cooldown + consensus sit above individual sensor config
            VStack(spacing: 10) {
                SettingRow(icon: "timer",
                           title: NSLocalizedString("setting_cooldown", comment: "Cooldown setting title"),
                           help: NSLocalizedString("help_cooldown", comment: "Cooldown setting help text")) {
                    SingleSlider(value: $s.debounce, bounds: Detection.debounceRange,
                                 labelWidth: lw, format: Fmt.seconds)
                }
                if enabledCount >= 2 {
                    Divider()
                    SettingRow(icon: "person.3",
                               title: NSLocalizedString("setting_consensus", comment: "Sensor consensus setting title"),
                               help: NSLocalizedString("help_consensus", comment: "Sensor consensus setting help text")) {
                        SingleSliderInt(value: $s.consensusRequired, bounds: 1...enabledCount,
                                        labelWidth: lw, format: Fmt.consensus)
                    }
                }
            }
            .padding(Theme.accordionInner)

            // Per-sensor cards (only show if the sensor is detected)
            if availableSensors.contains(SensorID.accelerometer.rawValue) {
                SensorAccordionCard(
                    title: NSLocalizedString("sensor_accelerometer", comment: "Accelerometer sensor name"),
                    icon: "gyroscope",
                    isEnabled: sensorBinding(id: SensorID.accelerometer.rawValue),
                    isExpanded: $accelExpanded
                ) {
                    AccelTuningContent()
                }
            }

            if availableSensors.contains(SensorID.microphone.rawValue) {
                SensorAccordionCard(
                    title: NSLocalizedString("sensor_microphone", comment: "Microphone sensor name"),
                    icon: "mic",
                    isEnabled: sensorBinding(id: SensorID.microphone.rawValue),
                    isExpanded: $micExpanded
                ) {
                    MicTuningContent()
                }
            }

            if availableSensors.contains(SensorID.headphoneMotion.rawValue) {
                SensorAccordionCard(
                    title: NSLocalizedString("sensor_headphone_motion", comment: "Headphone motion sensor name"),
                    icon: "headphones",
                    isEnabled: sensorBinding(id: SensorID.headphoneMotion.rawValue),
                    isExpanded: $hpExpanded
                ) {
                    HeadphoneTuningContent()
                }
            }

        }
        .onAppear { clampConsensus() }
        .onChange(of: settings.enabledSensorIDs) { _, _ in clampConsensus() }
    }

    private func sensorBinding(id: String) -> Binding<Bool> {
        @Bindable var s = settings
        return arrayToggleBinding($s.enabledSensorIDs, element: id)
    }

    private func clampConsensus() {
        let enabledCount = availableSensors.filter { settings.enabledSensorIDs.contains($0) }.count
        if enabledCount >= 1 && settings.consensusRequired > enabledCount {
            settings.consensusRequired = enabledCount
        }
    }
}
