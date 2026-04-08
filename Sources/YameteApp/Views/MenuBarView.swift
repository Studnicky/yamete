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
            if settings.enabledSensorIDs.contains("accelerometer") {
                Divider()
                AccelTuningSection()
            }
            if settings.enabledSensorIDs.contains("microphone") {
                Divider()
                MicTuningSection()
            }
            if settings.enabledSensorIDs.contains("headphone-motion") {
                Divider()
                HeadphoneTuningSection()
            }
            Divider()
            DeviceSection(audioDevices: audioDevices, displays: displays)

            if let error = controller.sensorError {
                Divider()
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }

            Divider()
            FooterSection()
        }
        .frame(width: 290)
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

// MARK: - Header (impact counter)

private struct HeaderSection: View {
    @Environment(ImpactController.self) var controller

    var body: some View {
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

    var body: some View {
        @Bindable var s = settings

        Group {
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "gauge.with.needle", title: NSLocalizedString("setting_reactivity", comment: "Reactivity setting title"),
                              help: NSLocalizedString("help_reactivity", comment: "Reactivity setting help text"))
                SensitivityRuler()
                RangeSlider(low: $s.sensitivityMin, high: $s.sensitivityMax,
                            bounds: 0...1, labelWidth: 50, format: { String(format: NSLocalizedString("unit_percent", comment: "Percentage format"), Int($0 * 100)) })
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "speaker.wave.2", title: NSLocalizedString("setting_volume", comment: "Volume setting title"),
                                  help: NSLocalizedString("help_volume", comment: "Volume setting help text"))
                    Spacer()
                    Toggle("", isOn: $s.soundEnabled)
                        .toggleStyle(.switch).tint(Theme.pink)
                        .labelsHidden().controlSize(.mini)
                }
                if s.soundEnabled {
                    RangeSlider(low: $s.volumeMin, high: $s.volumeMax,
                                bounds: 0...1, labelWidth: 50, format: { String(format: NSLocalizedString("unit_percent", comment: "Percentage format"), Int($0 * 100)) })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "sun.max", title: NSLocalizedString("setting_flash_opacity", comment: "Flash opacity setting title"),
                                  help: NSLocalizedString("help_flash_opacity", comment: "Flash opacity setting help text"))
                    Spacer()
                    Toggle("", isOn: $s.screenFlash)
                        .toggleStyle(.switch).tint(Theme.pink)
                        .labelsHidden().controlSize(.mini)
                }
                if s.screenFlash {
                    RangeSlider(low: $s.flashOpacityMin, high: $s.flashOpacityMax,
                                bounds: 0...1, labelWidth: 50, format: { String(format: NSLocalizedString("unit_percent", comment: "Percentage format"), Int($0 * 100)) })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
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

    var body: some View {
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

    var body: some View {
        @Bindable var s = settings

        AccordionCard(title: NSLocalizedString("section_sensitivity_sensors", comment: "Sensitivity & Sensors accordion title"), isExpanded: $isExpanded) {
            let _ = clampConsensus()
            let lw: CGFloat = 50

            sensorList()

            let enabledCount = availableSensors.filter { s.enabledSensorIDs.contains($0) }.count

            VStack(spacing: 10) {
                if enabledCount >= 2 {
                    Divider()
                    settingRow(icon: "person.3", title: NSLocalizedString("setting_consensus", comment: "Sensor consensus setting title"),
                               help: NSLocalizedString("help_consensus", comment: "Sensor consensus setting help text")) {
                        SingleSliderInt(value: $s.consensusRequired, bounds: 1...enabledCount,
                                        labelWidth: lw, format: { String(format: NSLocalizedString("consensus_format", comment: "Sensor consensus count"), $0) })
                    }
                }

                Divider()

                settingRow(icon: "timer", title: NSLocalizedString("setting_cooldown", comment: "Cooldown setting title"),
                           help: NSLocalizedString("help_cooldown", comment: "Cooldown setting help text")) {
                    SingleSlider(value: $s.debounce, bounds: 0...2,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), $0) })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
        }
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
                .padding(.vertical, 3).padding(.horizontal, 6)
                if i < adapters.count - 1 { Divider().padding(.leading, 22) }
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
        return Binding(
            get: { s.enabledSensorIDs.contains(id) },
            set: { enabled in
                var ids = s.enabledSensorIDs
                if enabled { if !ids.contains(id) { ids.append(id) } }
                else { ids.removeAll { $0 == id } }
                s.enabledSensorIDs = ids
            }
        )
    }

    @ViewBuilder
    private func settingRow<Content: View>(icon: String, title: String, help: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingHeader(icon: icon, title: title, help: help)
            content()
        }
    }
}

// MARK: - Accelerometer Tuning (collapsible)

private struct AccelTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings
        let lw: CGFloat = 50

        AccordionCard(title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                settingRow(icon: "waveform.path", title: NSLocalizedString("setting_frequency_band", comment: "Frequency band setting title"),
                           help: NSLocalizedString("help_frequency_band", comment: "Frequency band setting help text")) {
                    RangeSlider(low: $s.accelBandpassLowHz, high: $s.accelBandpassHighHz,
                                bounds: 10...25, labelWidth: lw, format: { String(format: NSLocalizedString("unit_hz", comment: "Hertz format"), Int($0)) })
                }

                Divider()

                settingRow(icon: "arrow.up.to.line", title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                           help: NSLocalizedString("help_spike_threshold", comment: "Spike threshold setting help text")) {
                    SingleSlider(value: $s.accelSpikeThreshold, bounds: 0.010...0.040,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_gforce", comment: "G-force format"), $0) })
                }

                Divider()

                settingRow(icon: "chart.line.uptrend.xyaxis", title: NSLocalizedString("setting_crest_factor", comment: "Crest factor setting title"),
                           help: NSLocalizedString("help_crest_factor", comment: "Crest factor setting help text")) {
                    SingleSlider(value: $s.accelCrestFactor, bounds: 1.0...5.0,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_multiplier", comment: "Multiplier format"), $0) })
                }

                Divider()

                settingRow(icon: "bolt", title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                           help: NSLocalizedString("help_rise_rate", comment: "Rise rate setting help text")) {
                    SingleSlider(value: $s.accelRiseRate, bounds: 0.005...0.020,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_gforce", comment: "G-force format"), $0) })
                }

                Divider()

                settingRow(icon: "checkmark.circle", title: NSLocalizedString("setting_confirmations", comment: "Confirmations setting title"),
                           help: NSLocalizedString("help_confirmations", comment: "Confirmations setting help text")) {
                    SingleSliderInt(value: $s.accelConfirmations, bounds: 1...5,
                                    labelWidth: lw, format: { String(format: NSLocalizedString("confirmations_format", comment: "Confirmation hit count"), $0) })
                }

                Divider()

                settingRow(icon: "flame", title: NSLocalizedString("setting_warmup", comment: "Warmup setting title"),
                           help: NSLocalizedString("help_warmup", comment: "Warmup setting help text")) {
                    SingleSliderInt(value: $s.accelWarmupSamples, bounds: 10...100,
                                    labelWidth: lw, format: { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), Double($0) / 50.0) })
                }

                Divider()

                settingRow(icon: "clock.arrow.2.circlepath", title: NSLocalizedString("setting_report_interval", comment: "Report interval setting title"),
                           help: NSLocalizedString("help_report_interval", comment: "Report interval setting help text")) {
                    SingleSlider(value: $s.accelReportInterval, bounds: 5000...50000, step: 1000,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_milliseconds", comment: "Milliseconds format"), $0 / 1000) })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func settingRow<Content: View>(icon: String, title: String, help: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingHeader(icon: icon, title: title, help: help)
            content()
        }
    }
}

// MARK: - Microphone Tuning (collapsible)

private struct MicTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings
        let lw: CGFloat = 50

        AccordionCard(title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                settingRow(icon: "arrow.up.to.line", title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                           help: NSLocalizedString("help_mic_spike_threshold", comment: "Mic spike threshold help text")) {
                    SingleSlider(value: $s.micSpikeThreshold, bounds: 0.005...0.100,
                                 labelWidth: lw, format: { String(format: "%.3f", $0) })
                }

                Divider()

                settingRow(icon: "chart.line.uptrend.xyaxis", title: NSLocalizedString("setting_crest_factor", comment: "Crest factor setting title"),
                           help: NSLocalizedString("help_crest_factor", comment: "Crest factor setting help text")) {
                    SingleSlider(value: $s.micCrestFactor, bounds: 1.0...5.0,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_multiplier", comment: "Multiplier format"), $0) })
                }

                Divider()

                settingRow(icon: "bolt", title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                           help: NSLocalizedString("help_mic_rise_rate", comment: "Mic rise rate help text")) {
                    SingleSlider(value: $s.micRiseRate, bounds: 0.002...0.050,
                                 labelWidth: lw, format: { String(format: "%.3f", $0) })
                }

                Divider()

                settingRow(icon: "checkmark.circle", title: NSLocalizedString("setting_confirmations", comment: "Confirmations setting title"),
                           help: NSLocalizedString("help_confirmations", comment: "Confirmations setting help text")) {
                    SingleSliderInt(value: $s.micConfirmations, bounds: 1...5,
                                    labelWidth: lw, format: { String(format: NSLocalizedString("confirmations_format", comment: "Confirmation hit count"), $0) })
                }

                Divider()

                settingRow(icon: "flame", title: NSLocalizedString("setting_warmup", comment: "Warmup setting title"),
                           help: NSLocalizedString("help_warmup", comment: "Warmup setting help text")) {
                    SingleSliderInt(value: $s.micWarmupSamples, bounds: 10...100,
                                    labelWidth: lw, format: { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), Double($0) / 50.0) })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func settingRow<Content: View>(icon: String, title: String, help: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingHeader(icon: icon, title: title, help: help)
            content()
        }
    }
}

// MARK: - Headphone Tuning (collapsible)

private struct HeadphoneTuningSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings
        let lw: CGFloat = 50

        AccordionCard(title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"), isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                settingRow(icon: "arrow.up.to.line", title: NSLocalizedString("setting_spike_threshold", comment: "Spike threshold setting title"),
                           help: NSLocalizedString("help_hp_spike_threshold", comment: "Headphone spike threshold help text")) {
                    SingleSlider(value: $s.hpSpikeThreshold, bounds: 0.02...0.50,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_gforce", comment: "G-force format"), $0) })
                }

                Divider()

                settingRow(icon: "chart.line.uptrend.xyaxis", title: NSLocalizedString("setting_crest_factor", comment: "Crest factor setting title"),
                           help: NSLocalizedString("help_crest_factor", comment: "Crest factor setting help text")) {
                    SingleSlider(value: $s.hpCrestFactor, bounds: 1.0...5.0,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_multiplier", comment: "Multiplier format"), $0) })
                }

                Divider()

                settingRow(icon: "bolt", title: NSLocalizedString("setting_rise_rate", comment: "Rise rate setting title"),
                           help: NSLocalizedString("help_hp_rise_rate", comment: "Headphone rise rate help text")) {
                    SingleSlider(value: $s.hpRiseRate, bounds: 0.010...0.200,
                                 labelWidth: lw, format: { String(format: NSLocalizedString("unit_gforce", comment: "G-force format"), $0) })
                }

                Divider()

                settingRow(icon: "checkmark.circle", title: NSLocalizedString("setting_confirmations", comment: "Confirmations setting title"),
                           help: NSLocalizedString("help_confirmations", comment: "Confirmations setting help text")) {
                    SingleSliderInt(value: $s.hpConfirmations, bounds: 1...5,
                                    labelWidth: lw, format: { String(format: NSLocalizedString("confirmations_format", comment: "Confirmation hit count"), $0) })
                }

                Divider()

                settingRow(icon: "flame", title: NSLocalizedString("setting_warmup", comment: "Warmup setting title"),
                           help: NSLocalizedString("help_warmup", comment: "Warmup setting help text")) {
                    SingleSliderInt(value: $s.hpWarmupSamples, bounds: 10...100,
                                    labelWidth: lw, format: { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), Double($0) / 50.0) })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func settingRow<Content: View>(icon: String, title: String, help: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingHeader(icon: icon, title: title, help: help)
            content()
        }
    }
}

// MARK: - Devices (collapsible)

private struct DeviceSection: View {
    @Environment(SettingsStore.self) var settings
    let audioDevices: [AudioOutputDevice]
    let displays: [NSScreen]
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings

        AccordionCard(title: NSLocalizedString("section_devices", comment: "Devices accordion title"),
                      subtitle: String(format: NSLocalizedString("devices_subtitle", comment: "Devices section subtitle: display and audio count"), displays.count, audioDevices.count),
                      isExpanded: $isExpanded) {
            displayList()
            Divider()
            audioList()
        }
    }

    @ViewBuilder
    private func displayList() -> some View {
        let screens = displays.sorted { a, b in
            if a == NSScreen.main && b != NSScreen.main { return true }
            if b == NSScreen.main && a != NSScreen.main { return false }
            return a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "display", title: NSLocalizedString("setting_flash_displays", comment: "Flash displays setting title"),
                         help: NSLocalizedString("help_flash_displays", comment: "Flash displays setting help text"))
            VStack(spacing: 0) {
                ForEach(0..<screens.count, id: \.self) { i in
                    let screen = screens[i]
                    Toggle(isOn: displayBinding(dispID: screen.displayID)) {
                        Text(screen.localizedName).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).tint(Theme.pink).controlSize(.mini)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    if i < screens.count - 1 { Divider().padding(.leading, 22) }
                }
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    private func audioList() -> some View {
        let defaultUID = AudioDeviceManager.defaultDeviceUID
        let sorted = audioDevices.sorted { a, b in
            if a.uid == defaultUID && b.uid != defaultUID { return true }
            if b.uid == defaultUID && a.uid != defaultUID { return false }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "hifispeaker", title: NSLocalizedString("setting_audio_output", comment: "Audio output setting title"),
                         help: NSLocalizedString("help_audio_output", comment: "Audio output setting help text"))
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.offset) { i, device in
                    Toggle(isOn: audioBinding(uid: device.uid)) {
                        Text(device.displayName).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).tint(Theme.pink).controlSize(.mini)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    if i < sorted.count - 1 { Divider().padding(.leading, 22) }
                }
                if audioDevices.isEmpty {
                    Text(NSLocalizedString("no_output_devices", comment: "No audio output devices found message"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 3).padding(.horizontal, 4)
                }
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Bindings

    private func audioBinding(uid: String) -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { s.enabledAudioDevices.contains(uid) },
            set: { enabled in
                var uids = s.enabledAudioDevices
                if enabled { if !uids.contains(uid) { uids.append(uid) } }
                else { uids.removeAll { $0 == uid } }
                s.enabledAudioDevices = uids
            }
        )
    }

    private func displayBinding(dispID: Int) -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { s.enabledDisplays.contains(dispID) },
            set: { enabled in
                var ids = s.enabledDisplays
                if enabled { if !ids.contains(dispID) { ids.append(dispID) } }
                else { ids.removeAll { $0 == dispID } }
                s.enabledDisplays = ids
            }
        )
    }
}

// MARK: - Footer

private struct FooterSection: View {
    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var showResetConfirmation = false

    var body: some View {
        @Bindable var s = settings

        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "power")
                    .font(.system(size: 10)).foregroundStyle(Theme.pink)
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
            .padding(.horizontal, 14).padding(.vertical, 4)

            HStack(spacing: 5) {
                Image(systemName: "ladybug")
                    .font(.system(size: 10)).foregroundStyle(Theme.pink)
                Text(NSLocalizedString("label_debug_logging", comment: "Debug logging toggle label"))
                Spacer()
                Toggle("", isOn: $s.debugLogging)
                    .toggleStyle(.switch).tint(Theme.pink)
                    .labelsHidden().controlSize(.mini)
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 4)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(Theme.pink)
                Text(String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(action: { showResetConfirmation = true }) {
                    Text(NSLocalizedString("button_reset", comment: "Reset to defaults button"))
                        .font(.caption)
                        .foregroundStyle(Theme.pink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.deepRose.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                Button(action: { NSApp.terminate(nil) }) {
                    Text(NSLocalizedString("button_quit", comment: "Quit application button"))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.deepRose)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 14).padding(.vertical, 4).padding(.bottom, 4)
        }
        .alert(
            NSLocalizedString("reset_confirm_title", comment: "Reset confirmation dialog title"),
            isPresented: $showResetConfirmation
        ) {
            Button(NSLocalizedString("reset_confirm_cancel", comment: "Reset confirmation cancel button"), role: .cancel) {}
            Button(NSLocalizedString("reset_confirm_reset", comment: "Reset confirmation reset button"), role: .destructive) {
                settings.resetToDefaults()
            }
        } message: {
            Text(NSLocalizedString("reset_confirm_message", comment: "Reset confirmation dialog message"))
        }
    }
}
