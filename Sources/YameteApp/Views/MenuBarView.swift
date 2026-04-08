#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import SwiftUI
import AppKit
import ServiceManagement

// MARK: - MenuBarView (composition root)

public struct MenuBarView: View {
    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var audioDevices: [AudioOutputDevice] = []
    @State private var displays: [NSScreen] = NSScreen.screens
    @State private var availableSensors: [String] = []

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HeaderSection()
            Divider()
            BasicSection()
            Divider()
            SensorSection(availableSensors: availableSensors)
            if settings.enabledSensorIDs.contains(SensorID.accelerometer.rawValue) {
                Divider()
                AccelTuningSection()
            }
            if settings.enabledSensorIDs.contains(SensorID.microphone.rawValue) {
                Divider()
                MicTuningSection()
            }
            if settings.enabledSensorIDs.contains(SensorID.headphoneMotion.rawValue) {
                Divider()
                HeadphoneTuningSection()
            }
            Divider()
            DeviceSection(audioDevices: audioDevices, displays: displays)

            if let error = controller.sensorError {
                Divider()
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .padding(Theme.footerPadding)
            }

            Divider()
            FooterSection()
        }
        .frame(width: Theme.menuWidth)
        .onAppear {
            AudioDeviceManager.startObserving()
            refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioDeviceManager.devicesDidChangeNotification)) { _ in
            refreshAudioDevices()
            refreshSensors()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshDisplays()
        }
    }

    private func refreshAll() {
        refreshAudioDevices()
        refreshDisplays()
        refreshSensors()
    }

    private func refreshAudioDevices() {
        let latest = AudioDeviceManager.outputDevices()
        if latest.map(\.uid) != audioDevices.map(\.uid)
            || latest.map(\.displayName) != audioDevices.map(\.displayName) {
            audioDevices = latest
        }
    }

    private func refreshDisplays() {
        let latest = NSScreen.screens
        if latest.map(\.displayID) != displays.map(\.displayID) {
            displays = latest
        }
    }

    private func refreshSensors() {
        let latest = controller.allAdapters
            .filter { $0.isAvailable }
            .map(\.id.rawValue)
        if latest != availableSensors {
            availableSensors = latest
        }
    }
}

// MARK: - Shared formatters

private enum Fmt {
    static let percent: (Double) -> String = { String(format: NSLocalizedString("unit_percent", comment: "Percentage format"), Int($0 * 100)) }
    static let gforce: (Double) -> String = { String(format: NSLocalizedString("unit_gforce", comment: "G-force format"), $0) }
    static let multiplier: (Double) -> String = { String(format: NSLocalizedString("unit_multiplier", comment: "Multiplier format"), $0) }
    static let seconds: (Double) -> String = { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), $0) }
    static let hz: (Double) -> String = { String(format: NSLocalizedString("unit_hz", comment: "Hertz format"), Int($0)) }
    static let ms: (Double) -> String = { String(format: NSLocalizedString("unit_milliseconds", comment: "Milliseconds format"), $0 / 1000) }
    static let amplitude: (Double) -> String = { String(format: "%.3f", $0) }
    static let warmup: (Double) -> String = { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), $0 / 50.0) }
    static let warmupInt: (Int) -> String = { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), Double($0) / 50.0) }
    static let confirmations: (Int) -> String = { String(format: NSLocalizedString("confirmations_format", comment: "Confirmation hit count"), $0) }
    static let consensus: (Int) -> String = { String(format: NSLocalizedString("consensus_format", comment: "Sensor consensus count"), $0) }
}

// MARK: - Generic toggle binding for array-backed selections

private func arrayToggleBinding<T: Equatable>(
    _ array: Binding<[T]>, element: T
) -> Binding<Bool> {
    Binding(
        get: { array.wrappedValue.contains(element) },
        set: { enabled in
            var items = array.wrappedValue
            if enabled { if !items.contains(element) { items.append(element) } }
            else { items.removeAll { $0 == element } }
            array.wrappedValue = items
        }
    )
}

// MARK: - Shared label width for tuning sliders

private let tuningLabelWidth: CGFloat = 50

// MARK: - Header (impact counter)

private struct HeaderSection: View {
    @Environment(ImpactController.self) var controller

    public var body: some View {
        HStack {
            Text(String(format: NSLocalizedString("impacts_today", comment: "Daily impact counter"), controller.impactCount))
            Spacer()
            if let tier = controller.lastImpactTier {
                Text(verbatim: String(format: NSLocalizedString("last_impact", comment: "Last impact tier label"), String(describing: tier)))
                    .foregroundStyle(.tertiary)
            }
            if !controller.isEnabled {
                Text(NSLocalizedString("status_paused", comment: "Detection paused indicator")).foregroundStyle(Theme.mauve)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

// MARK: - Basic (reactivity, volume, flash)

private struct BasicSection: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        @Bindable var s = settings

        Group {
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "gauge.with.needle", title: NSLocalizedString("setting_reactivity", comment: "Reactivity setting title"),
                              help: NSLocalizedString("help_reactivity", comment: "Reactivity setting help text"))
                SensitivityRuler()
                RangeSlider(low: $s.sensitivityMin, high: $s.sensitivityMax,
                            bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
            }
            .padding(Theme.sectionPadding)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "speaker.wave.2", title: NSLocalizedString("setting_volume", comment: "Volume setting title"),
                                  help: NSLocalizedString("help_volume", comment: "Volume setting help text"))
                    Spacer()
                    Toggle("", isOn: $s.soundEnabled)
                        .themeMiniSwitch()
                }
                if s.soundEnabled {
                    RangeSlider(low: $s.volumeMin, high: $s.volumeMax,
                                bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
                }
            }
            .padding(Theme.sectionPadding)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "sun.max", title: NSLocalizedString("setting_flash_opacity", comment: "Flash opacity setting title"),
                                  help: NSLocalizedString("help_flash_opacity", comment: "Flash opacity setting help text"))
                    Spacer()
                    Toggle("", isOn: $s.screenFlash)
                        .themeMiniSwitch()
                }
                if s.screenFlash {
                    RangeSlider(low: $s.flashOpacityMin, high: $s.flashOpacityMax,
                                bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
                }
            }
            .padding(Theme.sectionPadding)
        }
    }
}

// MARK: - Sensitivity ruler

private struct SensitivityRuler: View {
    private static let ticks: [(position: Double, label: String)] = [
        (0.0, NSLocalizedString("tier_hard", comment: "Ruler label: hardest impact")),
        (0.25, NSLocalizedString("tier_firm", comment: "Ruler label: firm impact")),
        (0.50, NSLocalizedString("tier_medium", comment: "Ruler label: medium impact (abbreviated)")),
        (0.75, NSLocalizedString("tier_light", comment: "Ruler label: light impact")),
        (1.0, NSLocalizedString("tier_tap", comment: "Ruler label: lightest impact")),
    ]

    public var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 50)
            GeometryReader { geo in
                let w = geo.size.width
                ForEach(Array(Self.ticks.enumerated()), id: \.offset) { _, tick in
                    VStack(spacing: 1) {
                        Text(tick.label).font(.system(size: 8)).foregroundStyle(.tertiary)
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 4)
                    }
                    .position(x: tick.position * w, y: 8)
                }
            }
            .frame(height: 16)
            Spacer().frame(width: 50)
        }
    }
}

// MARK: - Sensors & Detection (collapsible)

private struct SensorSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(ImpactController.self) var controller
    let availableSensors: [String]
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings

        AccordionCard(title: NSLocalizedString("section_sensitivity_sensors", comment: "Sensitivity & Sensors accordion title"), isExpanded: $isExpanded) {
            let lw = tuningLabelWidth

            sensorList()

            let enabledCount = availableSensors.filter { s.enabledSensorIDs.contains($0) }.count

            VStack(spacing: 10) {
                if enabledCount >= 2 {
                    Divider()
                    SettingRow(icon: "person.3",
                               title: NSLocalizedString("setting_consensus", comment: "Sensor consensus setting title"),
                               help: NSLocalizedString("help_consensus", comment: "Sensor consensus setting help text")) {
                        SingleSliderInt(value: $s.consensusRequired, bounds: 1...enabledCount,
                                        labelWidth: lw, format: Fmt.consensus)
                    }
                }

                Divider()

                SettingRow(icon: "timer",
                           title: NSLocalizedString("setting_cooldown", comment: "Cooldown setting title"),
                           help: NSLocalizedString("help_cooldown", comment: "Cooldown setting help text")) {
                    SingleSlider(value: $s.debounce, bounds: Detection.debounceRange,
                                 labelWidth: lw, format: Fmt.seconds)
                }
            }
            .padding(Theme.accordionInner)
        }
        .onAppear { clampConsensus() }
        .onChange(of: settings.enabledSensorIDs) { _, _ in clampConsensus() }
    }

    @ViewBuilder
    private func sensorList() -> some View {
        let adapters = controller.allAdapters
            .filter { availableSensors.contains($0.id.rawValue) }
            .sorted { $0.name < $1.name }
        VStack(spacing: 0) {
            ForEach(Array(adapters.enumerated()), id: \.offset) { i, adapter in
                Toggle(isOn: sensorBinding(id: adapter.id.rawValue)) {
                    Text(adapter.name).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).tint(Theme.pink).controlSize(.mini)
                .padding(Theme.toggleRowPadding)
                if i < adapters.count - 1 { Divider().padding(.leading, Theme.listDividerInset) }
            }
        }
        .padding(.vertical, 4)
    }

    private func clampConsensus() {
        let enabledCount = availableSensors.filter { settings.enabledSensorIDs.contains($0) }.count
        if enabledCount >= 1 && settings.consensusRequired > enabledCount {
            settings.consensusRequired = enabledCount
        }
    }

    private func sensorBinding(id: String) -> Binding<Bool> {
        @Bindable var s = settings
        return arrayToggleBinding($s.enabledSensorIDs, element: id)
    }

}

// MARK: - Reusable setting row

private struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let help: String
    @ViewBuilder let content: Content

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingHeader(icon: icon, title: title, help: help)
            content
        }
    }
}

// MARK: - Shared detection gate parameters (crest factor, confirmations, warmup)

private struct DetectionGatesView: View {
    @Binding var crestFactor: Double
    @Binding var confirmations: Int
    @Binding var warmupSamples: Int
    let crestBounds: ClosedRange<Double>
    let confirmationsBounds: ClosedRange<Int>
    let warmupBounds: ClosedRange<Int>
    let labelWidth: CGFloat

    public var body: some View {
        SettingRow(icon: "chart.line.uptrend.xyaxis",
                   title: NSLocalizedString("setting_crest_factor", comment: "Crest factor setting title"),
                   help: NSLocalizedString("help_crest_factor", comment: "Crest factor setting help text")) {
            SingleSlider(value: $crestFactor, bounds: crestBounds,
                         labelWidth: labelWidth, format: Fmt.multiplier)
        }

        Divider()

        SettingRow(icon: "checkmark.circle",
                   title: NSLocalizedString("setting_confirmations", comment: "Confirmations setting title"),
                   help: NSLocalizedString("help_confirmations", comment: "Confirmations setting help text")) {
            SingleSliderInt(value: $confirmations, bounds: confirmationsBounds,
                            labelWidth: labelWidth, format: Fmt.confirmations)
        }

        Divider()

        SettingRow(icon: "flame",
                   title: NSLocalizedString("setting_warmup", comment: "Warmup setting title"),
                   help: NSLocalizedString("help_warmup", comment: "Warmup setting help text")) {
            SingleSliderInt(value: $warmupSamples, bounds: warmupBounds,
                            labelWidth: labelWidth, format: Fmt.warmupInt)
        }
    }
}

// MARK: - Accelerometer Tuning (collapsible)

private struct AccelTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        AccordionCard(title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                SettingRow(icon: "waveform.path",
                           title: NSLocalizedString("setting_frequency_band", comment: "Frequency band setting title"),
                           help: NSLocalizedString("help_frequency_band", comment: "Frequency band setting help text")) {
                    RangeSlider(low: $s.accelBandpassLowHz, high: $s.accelBandpassHighHz,
                                bounds: Detection.Accel.bandpassRange, labelWidth: lw, format: Fmt.hz)
                }

                Divider()

                SettingRow(icon: "arrow.up.to.line",
                           title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                           help: NSLocalizedString("help_spike_threshold", comment: "Spike threshold setting help text")) {
                    SingleSlider(value: $s.accelSpikeThreshold, bounds: Detection.Accel.spikeThresholdRange,
                                 labelWidth: lw, format: Fmt.gforce)
                }

                Divider()

                SettingRow(icon: "bolt",
                           title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                           help: NSLocalizedString("help_rise_rate", comment: "Rise rate setting help text")) {
                    SingleSlider(value: $s.accelRiseRate, bounds: Detection.Accel.riseRateRange,
                                 labelWidth: lw, format: Fmt.gforce)
                }

                Divider()

                DetectionGatesView(crestFactor: $s.accelCrestFactor, confirmations: $s.accelConfirmations,
                                   warmupSamples: $s.accelWarmupSamples, crestBounds: Detection.Accel.crestFactorRange,
                                   confirmationsBounds: Detection.Accel.confirmationsRange, warmupBounds: Detection.Accel.warmupRange, labelWidth: lw)

                Divider()

                SettingRow(icon: "clock.arrow.2.circlepath",
                           title: NSLocalizedString("setting_report_interval", comment: "Report interval setting title"),
                           help: NSLocalizedString("help_report_interval", comment: "Report interval setting help text")) {
                    SingleSlider(value: $s.accelReportInterval, bounds: Detection.Accel.reportIntervalRange, step: Detection.Accel.reportIntervalStep,
                                 labelWidth: lw, format: Fmt.ms)
                }
            }
            .padding(Theme.accordionInner)
        }
    }
}

// MARK: - Microphone Tuning (collapsible)

private struct MicTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        AccordionCard(title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                SettingRow(icon: "arrow.up.to.line",
                           title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                           help: NSLocalizedString("help_mic_spike_threshold", comment: "Mic spike threshold help text")) {
                    SingleSlider(value: $s.micSpikeThreshold, bounds: Detection.Mic.spikeThresholdRange,
                                 labelWidth: lw, format: Fmt.amplitude)
                }

                Divider()

                SettingRow(icon: "bolt",
                           title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                           help: NSLocalizedString("help_mic_rise_rate", comment: "Mic rise rate help text")) {
                    SingleSlider(value: $s.micRiseRate, bounds: Detection.Mic.riseRateRange,
                                 labelWidth: lw, format: Fmt.amplitude)
                }

                Divider()

                DetectionGatesView(crestFactor: $s.micCrestFactor, confirmations: $s.micConfirmations,
                                   warmupSamples: $s.micWarmupSamples, crestBounds: Detection.Mic.crestFactorRange,
                                   confirmationsBounds: Detection.Mic.confirmationsRange, warmupBounds: Detection.Mic.warmupRange, labelWidth: lw)
            }
            .padding(Theme.accordionInner)
        }
    }
}

// MARK: - Headphone Tuning (collapsible)

private struct HeadphoneTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings
        let lw = tuningLabelWidth

        AccordionCard(title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                SettingRow(icon: "arrow.up.to.line",
                           title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                           help: NSLocalizedString("help_hp_spike_threshold", comment: "Headphone spike threshold help text")) {
                    SingleSlider(value: $s.hpSpikeThreshold, bounds: Detection.Headphone.spikeThresholdRange,
                                 labelWidth: lw, format: Fmt.gforce)
                }

                Divider()

                SettingRow(icon: "bolt",
                           title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                           help: NSLocalizedString("help_hp_rise_rate", comment: "Headphone rise rate help text")) {
                    SingleSlider(value: $s.hpRiseRate, bounds: Detection.Headphone.riseRateRange,
                                 labelWidth: lw, format: Fmt.gforce)
                }

                Divider()

                DetectionGatesView(crestFactor: $s.hpCrestFactor, confirmations: $s.hpConfirmations,
                                   warmupSamples: $s.hpWarmupSamples, crestBounds: Detection.Headphone.crestFactorRange,
                                   confirmationsBounds: Detection.Headphone.confirmationsRange, warmupBounds: Detection.Headphone.warmupRange, labelWidth: lw)
            }
            .padding(Theme.accordionInner)
        }
    }
}

// MARK: - Reusable device toggle list

private struct DeviceToggleList<ID: Hashable>: View {
    let items: [(name: String, id: ID)]
    let emptyMessage: String?
    let noneSelectedMessage: String?
    let selectedIDs: [ID]
    let binding: (ID) -> Binding<Bool>

    init(items: [(name: String, id: ID)], emptyMessage: String? = nil,
         noneSelectedMessage: String? = nil, selectedIDs: [ID] = [],
         binding: @escaping (ID) -> Binding<Bool>) {
        self.items = items; self.emptyMessage = emptyMessage
        self.noneSelectedMessage = noneSelectedMessage
        self.selectedIDs = selectedIDs; self.binding = binding
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Toggle(isOn: binding(item.id)) {
                    Text(item.name).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).tint(Theme.pink).controlSize(.mini)
                .padding(Theme.toggleRowPadding)
                if i < items.count - 1 { Divider().padding(.leading, Theme.listDividerInset) }
            }
            if items.isEmpty, let msg = emptyMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .padding(Theme.toggleRowPadding)
            } else if !items.isEmpty && selectedIDs.isEmpty, let msg = noneSelectedMessage {
                Divider()
                Text(msg).font(.caption).foregroundStyle(Theme.mauve)
                    .padding(Theme.toggleRowPadding)
            }
        }
        .background(Theme.listBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.listCornerRadius))
    }
}

// MARK: - Devices (collapsible)

private struct DeviceSection: View {
    @Environment(SettingsStore.self) var settings
    let audioDevices: [AudioOutputDevice]
    let displays: [NSScreen]
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings

        AccordionCard(title: NSLocalizedString("section_devices", comment: "Devices accordion title"),
                      subtitle: String(format: NSLocalizedString("devices_subtitle", comment: "Devices section subtitle: display and audio count"), displays.count, audioDevices.count),
                      isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "display", title: NSLocalizedString("setting_flash_displays", comment: "Flash displays setting title"),
                             help: NSLocalizedString("help_flash_displays", comment: "Flash displays setting help text"))
                DeviceToggleList(
                    items: sortedDisplays.map { (name: $0.localizedName, id: $0.displayID) },
                    noneSelectedMessage: NSLocalizedString("no_displays_selected", comment: "No displays selected hint"),
                    selectedIDs: s.enabledDisplays,
                    binding: { id in arrayToggleBinding($s.enabledDisplays, element: id) })
            }
            .padding(Theme.sectionPadding)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "hifispeaker", title: NSLocalizedString("setting_audio_output", comment: "Audio output setting title"),
                             help: NSLocalizedString("help_audio_output", comment: "Audio output setting help text"))
                DeviceToggleList(
                    items: sortedAudioDevices.map { (name: $0.displayName, id: $0.uid) },
                    emptyMessage: NSLocalizedString("no_output_devices", comment: "No audio output hardware detected"),
                    noneSelectedMessage: NSLocalizedString("no_audio_selected", comment: "No audio devices selected hint"),
                    selectedIDs: s.enabledAudioDevices,
                    binding: { uid in arrayToggleBinding($s.enabledAudioDevices, element: uid) })
            }
            .padding(Theme.sectionPadding)
        }
    }

    private var sortedDisplays: [NSScreen] {
        displays.sorted { a, b in
            if a == NSScreen.main && b != NSScreen.main { return true }
            if b == NSScreen.main && a != NSScreen.main { return false }
            return a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
        }
    }

    private var sortedAudioDevices: [AudioOutputDevice] {
        let defaultUID = AudioDeviceManager.defaultDeviceUID
        return audioDevices.sorted { a, b in
            if a.uid == defaultUID && b.uid != defaultUID { return true }
            if b.uid == defaultUID && a.uid != defaultUID { return false }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }
}

// MARK: - Footer

private struct FooterSection: View {
    private static let privacyPolicyURL = URL(string: "https://studnicky.github.io/yamete/privacy.html")!
    private static let supportURL = URL(string: "https://studnicky.github.io/yamete/support.html")!

    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    public var body: some View {
        @Bindable var s = settings

        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "power")
                    .themeFooterIcon()
                Text(NSLocalizedString("label_launch_at_login", comment: "Launch at login toggle label"))
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).tint(Theme.pink)
                    .labelsHidden().controlSize(.mini)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else  { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = !on }
                    }
            }
            .font(.caption)
            .padding(Theme.footerPadding)

            if AppLog.supportsDebugLogging {
                HStack(spacing: 5) {
                    Image(systemName: "ladybug")
                        .themeFooterIcon()
                    Text(NSLocalizedString("label_debug_logging", comment: "Debug logging toggle label"))
                    Spacer()
                    Toggle("", isOn: $s.debugLogging)
                        .toggleStyle(.switch).tint(Theme.pink)
                        .labelsHidden().controlSize(.mini)
                }
                .font(.caption)
                .padding(Theme.footerPadding)
            }

            HStack(spacing: 5) {
                Image(systemName: "link")
                    .themeFooterIcon()
                Text(NSLocalizedString("label_links", comment: "Footer links section label"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { open(Self.privacyPolicyURL) }) {
                    Text(NSLocalizedString("button_privacy", comment: "Privacy policy button"))
                        .themePillButton(background: Theme.deepRose.opacity(0.15), foreground: Theme.pink)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("action_open_privacy_policy", comment: "Open privacy policy accessibility label"))
                .accessibilityLabel(Text(NSLocalizedString("action_open_privacy_policy", comment: "Open privacy policy accessibility label")))

                Button(action: { open(Self.supportURL) }) {
                    Text(NSLocalizedString("button_support", comment: "Support button"))
                        .themePillButton(background: Theme.deepRose.opacity(0.15), foreground: Theme.pink)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("action_open_support", comment: "Open support accessibility label"))
                .accessibilityLabel(Text(NSLocalizedString("action_open_support", comment: "Open support accessibility label")))
            }
            .font(.caption)
            .padding(Theme.footerPadding)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .themeFooterIcon()
                Text(String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(action: { confirmAndReset() }) {
                    Text(NSLocalizedString("button_reset", comment: "Reset to defaults button"))
                        .themePillButton(background: Theme.deepRose.opacity(0.15), foreground: Theme.pink)
                }
                .buttonStyle(.plain)
                Button(action: { NSApp.terminate(nil) }) {
                    Text(NSLocalizedString("button_quit", comment: "Quit application button"))
                        .themePillButton(bold: true)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(Theme.footerPadding).padding(.bottom, 4)
        }
    }

    private func confirmAndReset() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("reset_confirm_title", comment: "Reset confirmation dialog title")
        alert.informativeText = NSLocalizedString("reset_confirm_message", comment: "Reset confirmation dialog message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("reset_confirm_reset", comment: "Reset confirmation reset button"))
        alert.addButton(withTitle: NSLocalizedString("reset_confirm_cancel", comment: "Reset confirmation cancel button"))
        if alert.runModal() == .alertFirstButtonReturn {
            settings.resetToDefaults()
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
