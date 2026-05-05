#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Sensors & Detection

/// Impact Detection group. A master `SensorAccordionCard` wraps one
/// inner `SensorAccordionCard` per available impact sensor
/// (accelerometer, microphone, AirPods motion). Per-sensor cards sort
/// active-above-inactive with locale-aware alpha-sort within each group.
/// Reactivity, cooldown, and consensus controls render after the
/// per-sensor cards so the auto-sort cannot reshuffle them away from
/// the impact-fusion data they govern.
internal struct SensorSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(Yamete.self) var yamete
    let availableSensors: [String]

    @State private var impactGroupExpanded = false
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
                // Per-sensor cards: active above inactive, alpha-sorted within.
                ForEach(ordered, id: \.self) { sensorID in
                    sensorCard(for: sensorID)
                }

                // Reactivity, cooldown, and consensus all govern the
                // impact-fusion pipeline only — `sensitivityMin/Max`
                // feed `fusion.intensityGate`; `debounce` is the rearm
                // interval; `consensusRequired` clamps to the count of
                // enabled impact sensors. None of them affect the
                // discrete-event stimulus sources or the per-output
                // dispatch matrix.
                VStack(spacing: 10) {
                    Divider()
                    SettingHeader(icon: "gauge.with.needle",
                                  title: NSLocalizedString("setting_reactivity", comment: "Reactivity setting title"),
                                  help: NSLocalizedString("help_reactivity", comment: "Reactivity setting help text"))
                    SensitivityRuler()
                    RangeSlider(low: $s.sensitivityMin, high: $s.sensitivityMax,
                                bounds: Detection.unitRange, labelWidth: lw, format: Fmt.percent)
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
            .dimmedWhenMasterOff(s.impactMasterEnabled)
        }
        .onAppear { clampConsensus() }
        .onChange(of: settings.enabledSensorIDs) { _, _ in clampConsensus() }
    }

    /// Pure-functional sort exposed for unit tests. Active sensors above
    /// inactive, each alphabetised by localised title under the
    /// `collationLocale`'s case- and diacritic-insensitive rules.
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

    /// Override-disable kill switch for the impact group. Reads and
    /// writes `settings.impactMasterEnabled` only; never mutates
    /// `enabledSensorIDs`. When `false`, `Yamete.rebuildSensorPipeline`
    /// computes an empty enabled-sensor set so the fusion pipeline does
    /// not run. When `true`, the per-sensor selection in
    /// `enabledSensorIDs` flows through unchanged.
    private func masterImpactBinding() -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { s.impactMasterEnabled },
            set: { newValue in s.impactMasterEnabled = newValue }
        )
    }

    private func clampConsensus() {
        let enabledCount = availableSensors.filter { settings.enabledSensorIDs.contains($0) }.count
        if enabledCount >= 1 && settings.consensusRequired > enabledCount {
            settings.consensusRequired = enabledCount
        }
    }
}
