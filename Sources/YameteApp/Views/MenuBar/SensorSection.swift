#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Sensors & Detection

/// Displays the Impact Detection group: a master accordion containing one
/// SensorAccordionCard per available impact sensor (accelerometer, microphone,
/// AirPods motion). Per-sensor cards sort active-above-inactive (alpha-sort
/// within each group, locale-aware collation). The master accordion exposes
/// a single toggle that flips the whole group on/off, and is visually
/// framed by the same accordion-card chrome as the discrete-event stimuli
/// in `StimuliSection` so the impact group reads as a peer of those cards.
/// Cooldown + consensus controls appear BELOW the per-sensor cards so the
/// auto-sort doesn't reshuffle them away from the data they govern.
internal struct SensorSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(Yamete.self) var yamete
    let availableSensors: [String]

    @State private var impactGroupExpanded = true
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
        let ordered = Self.orderedSensorIDs(availableSensors,
                                            enabledIDs: Set(s.enabledSensorIDs),
                                            collationLocale: Locale(identifier: s.resolvedNotificationLocale))

        SensorAccordionCard(
            title: NSLocalizedString("section_impact_detection", comment: "Impact detection master group title"),
            icon: "waveform.badge.exclamationmark",
            isEnabled: masterImpactBinding(),
            isExpanded: $impactGroupExpanded,
            help: NSLocalizedString("help_impact_detection", comment: "Impact detection master toggle help")
        ) {
            VStack(spacing: 0) {
                // Per-sensor cards: active above inactive, alpha-sorted within
                ForEach(ordered, id: \.self) { sensorID in
                    sensorCard(for: sensorID)
                }

                // Cooldown + consensus appear AFTER the sensor cards so
                // auto-sort never reshuffles them away from the impact group.
                // Consensus only renders when 2+ impact sensors are enabled
                // (a 1-sensor consensus is always 1).
                VStack(spacing: 10) {
                    Divider()
                    SettingRow(icon: "timer",
                               title: NSLocalizedString("setting_cooldown", comment: "Cooldown setting title"),
                               help: NSLocalizedString("help_cooldown", comment: "Cooldown setting help text")) {
                        SingleSlider(value: $s.debounce, bounds: Detection.debounceRange,
                                     labelWidth: lw, format: Fmt.seconds)
                    }
                    if enabledCount >= 2 {
                        Divider()
                        SettingRow(icon: "person.3",
                                   title: NSLocalizedString("setting_consensus", comment: "Impact consensus setting title"),
                                   help: NSLocalizedString("help_consensus", comment: "Impact consensus setting help text")) {
                            SingleSliderInt(value: $s.consensusRequired, bounds: 1...enabledCount,
                                            labelWidth: lw, format: Fmt.consensus)
                        }
                    }
                }
                .padding(Theme.accordionInner)
            }
        }
        .onAppear { clampConsensus() }
        .onChange(of: settings.enabledSensorIDs) { _, _ in clampConsensus() }
    }

    /// Pure-functional sort exposed for unit tests. Mirrors the
    /// `StimuliSection.orderedRows(...)` shape: active group above inactive
    /// group, each alphabetised by localised title using the user-selected
    /// locale's collation rules.
    @MainActor
    internal static func orderedSensorIDs(_ availableSensors: [String],
                                          enabledIDs: Set<String>,
                                          collationLocale: Locale) -> [String] {
        let candidates = [
            SensorID.accelerometer.rawValue,
            SensorID.microphone.rawValue,
            SensorID.headphoneMotion.rawValue,
        ]
        let available = candidates.filter { availableSensors.contains($0) }
        let compare: (String, String) -> Bool = { lhs, rhs in
            sensorTitle(lhs).compare(sensorTitle(rhs),
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: nil,
                                     locale: collationLocale) == .orderedAscending
        }
        let active   = available.filter {  enabledIDs.contains($0) }.sorted(by: compare)
        let inactive = available.filter { !enabledIDs.contains($0) }.sorted(by: compare)
        return active + inactive
    }

    @MainActor
    internal static func sensorTitle(_ id: String) -> String {
        switch id {
        case SensorID.accelerometer.rawValue:
            return NSLocalizedString("sensor_accelerometer", comment: "Accelerometer sensor name")
        case SensorID.microphone.rawValue:
            return NSLocalizedString("sensor_microphone", comment: "Microphone sensor name")
        case SensorID.headphoneMotion.rawValue:
            return NSLocalizedString("sensor_headphone_motion", comment: "Headphone motion sensor name")
        default:
            return id
        }
    }

    @ViewBuilder
    private func sensorCard(for id: String) -> some View {
        if id == SensorID.accelerometer.rawValue {
            SensorAccordionCard(
                title: Self.sensorTitle(id),
                icon: "gyroscope",
                isEnabled: sensorBinding(id: id),
                isExpanded: $accelExpanded
            ) { AccelTuningContent() }
        } else if id == SensorID.microphone.rawValue {
            SensorAccordionCard(
                title: Self.sensorTitle(id),
                icon: "mic",
                isEnabled: sensorBinding(id: id),
                isExpanded: $micExpanded
            ) { MicTuningContent() }
        } else if id == SensorID.headphoneMotion.rawValue {
            SensorAccordionCard(
                title: Self.sensorTitle(id),
                icon: "headphones",
                isEnabled: sensorBinding(id: id),
                isExpanded: $hpExpanded
            ) { HeadphoneTuningContent() }
        }
    }

    private func sensorBinding(id: String) -> Binding<Bool> {
        @Bindable var s = settings
        return arrayToggleBinding($s.enabledSensorIDs, element: id)
    }

    /// Master toggle for the entire impact group. Reads "any impact sensor
    /// enabled?". Writing `true` enables every available impact sensor;
    /// writing `false` disables every impact sensor while leaving non-impact
    /// stimuli (lid, thermal, USB, ...) in `enabledStimulusSourceIDs`
    /// untouched (those live in a different settings array).
    private func masterImpactBinding() -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { availableSensors.contains { s.enabledSensorIDs.contains($0) } },
            set: { newValue in
                if newValue {
                    var ids = s.enabledSensorIDs
                    for sensor in availableSensors where !ids.contains(sensor) {
                        ids.append(sensor)
                    }
                    s.enabledSensorIDs = ids
                } else {
                    s.enabledSensorIDs.removeAll { availableSensors.contains($0) }
                }
            }
        )
    }

    private func clampConsensus() {
        let enabledCount = availableSensors.filter { settings.enabledSensorIDs.contains($0) }.count
        if enabledCount >= 1 && settings.consensusRequired > enabledCount {
            settings.consensusRequired = enabledCount
        }
    }
}
