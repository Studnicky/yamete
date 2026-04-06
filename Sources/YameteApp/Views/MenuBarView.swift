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

struct MenuBarView: View {
    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var audioDevices: [AudioOutputDevice] = []

    private let deviceRefreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HeaderSection()
            Divider()
            BasicSection()
            Divider()
            SensitivitySection()
            Divider()
            DeviceSection(audioDevices: audioDevices)

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
        .onAppear { refreshAudioDevices() }
        .onReceive(deviceRefreshTimer) { _ in refreshAudioDevices() }
    }

    private func refreshAudioDevices() {
        let latest = AudioDeviceManager.outputDevices()
        if latest.map(\.uid) != audioDevices.map(\.uid)
            || latest.map(\.displayName) != audioDevices.map(\.displayName) {
            audioDevices = latest
        }
    }
}

// MARK: - Header (impact counter)

private struct HeaderSection: View {
    @Environment(ImpactController.self) var controller

    var body: some View {
        HStack {
            Text("\(controller.impactCount) impacts today")
            Spacer()
            if let tier = controller.lastImpactTier {
                Text(verbatim: "last: \(tier)")
                    .foregroundStyle(.tertiary)
            }
            if !controller.isEnabled {
                Text("Paused").foregroundStyle(Theme.mauve)
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
                SettingHeader(icon: "gauge.with.needle", title: "Reactivity",
                              help: "Impact force response window. Low thumb = weakest force that triggers. High thumb = force for maximum response. Higher values respond to lighter impacts.")
                SensitivityRuler()
                RangeSlider(low: $s.sensitivityMin, high: $s.sensitivityMax,
                            bounds: 0...1, labelWidth: 50, format: { String(format: "%.0f%%", $0 * 100) })
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "speaker.wave.2", title: "Volume",
                                  help: "Audio playback level window. Intensity maps linearly between low and high. Clip selection also follows intensity — lighter impacts play shorter clips.")
                    Spacer()
                    Toggle("", isOn: $s.soundEnabled)
                        .toggleStyle(.switch).tint(Theme.pink)
                        .labelsHidden().controlSize(.mini)
                }
                if s.soundEnabled {
                    RangeSlider(low: $s.volumeMin, high: $s.volumeMax,
                                bounds: 0...1, labelWidth: 50, format: { "\(Int($0 * 100))%" })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SettingHeader(icon: "sun.max", title: "Flash Opacity",
                                  help: "Screen flash brightness window. Envelope timing shaped by intensity. Gated inside the sound clip duration.")
                    Spacer()
                    Toggle("", isOn: $s.screenFlash)
                        .toggleStyle(.switch).tint(Theme.pink)
                        .labelsHidden().controlSize(.mini)
                }
                if s.screenFlash {
                    RangeSlider(low: $s.flashOpacityMin, high: $s.flashOpacityMax,
                                bounds: 0...1, labelWidth: 50, format: { "\(Int($0 * 100))%" })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: - Sensitivity ruler

private struct SensitivityRuler: View {
    private static let ticks: [(position: Double, label: String)] = [
        (0.0, "Hard"), (0.25, "Firm"), (0.50, "Med"), (0.75, "Light"), (1.0, "Tap"),
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

// MARK: - Sensitivity & Sensors (collapsible)

private struct SensitivitySection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(ImpactController.self) var controller
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings

        AccordionCard(title: "Sensitivity & Sensors", isExpanded: $isExpanded) {
            let _ = clampConsensus()
            let lw: CGFloat = 50

            sensorList()

            let enabledCount = controller.allAdapters
                .filter { $0.isAvailable && s.enabledSensorIDs.contains($0.id.rawValue) }.count

            VStack(spacing: 10) {
                if enabledCount >= 2 {
                    Divider()
                    advRow(icon: "person.3", title: "Sensor Consensus",
                           help: "Number of sensors that must independently detect an impact before triggering. Clamped to the number of sensors delivering data.") {
                        SingleSliderInt(value: $s.consensusRequired, bounds: 1...enabledCount,
                                        labelWidth: lw, format: { "\($0) sensor\($0 == 1 ? "" : "s")" })
                    }
                }

                Divider()

                advRow(icon: "timer", title: "Cooldown",
                       help: "Minimum time between reactions. 0 = gated only by the playing clip's duration.") {
                    SingleSlider(value: $s.debounce, bounds: 0...2,
                                 labelWidth: lw, format: { String(format: "%.1fs", $0) })
                }

                Divider()
                Theme.sectionHeader("Accelerometer Tuning")

                advRow(icon: "waveform.path", title: "Frequency Band",
                       help: "Bandpass filter on raw accelerometer data. Low = high-pass cutoff (rejects floor vibrations). High = low-pass cutoff (rejects electronic noise).") {
                    RangeSlider(low: $s.bandpassLowHz, high: $s.bandpassHighHz,
                                bounds: 10...25, labelWidth: lw, format: { "\(Int($0)) Hz" })
                }

                Divider()

                advRow(icon: "arrow.up.to.line", title: "Spike Threshold",
                       help: "Minimum filtered magnitude (g-force) to consider as a potential impact. Applied after bandpass filtering. Higher values require stronger force.") {
                    SingleSlider(value: $s.spikeThreshold, bounds: 0.010...0.040,
                                 labelWidth: lw, format: { String(format: "%.3fg", $0) })
                }

                Divider()

                advRow(icon: "chart.line.uptrend.xyaxis", title: "Crest Factor",
                       help: "Peak signal must exceed background RMS by this multiple. Sharp desk hits spike well above background. Footsteps raise background along with peak. Higher values reject more ambient vibration.") {
                    SingleSlider(value: $s.crestFactor, bounds: 1.0...5.0,
                                 labelWidth: lw, format: { String(format: "%.1f\u{00D7}", $0) })
                }

                Divider()

                advRow(icon: "bolt", title: "Rise Rate",
                       help: "Minimum magnitude increase between consecutive samples. Direct impacts rise in 1-2 samples. Transmitted vibrations rise gradually. Higher values reject indirect vibration.") {
                    SingleSlider(value: $s.riseRate, bounds: 0.005...0.020,
                                 labelWidth: lw, format: { String(format: "%.3fg", $0) })
                }

                Divider()

                advRow(icon: "checkmark.circle", title: "Confirmations",
                       help: "Above-threshold samples required in the 120ms detection window. Direct hits produce 3-5 high samples. Single jolts produce 1-2.") {
                    SingleSliderInt(value: $s.confirmations, bounds: 1...5,
                                    labelWidth: lw, format: { "\($0) hit\($0 == 1 ? "" : "s")" })
                }

                Divider()

                advRow(icon: "flame", title: "Warmup",
                       help: "Samples before detection activates. Filters need time to settle. At 50 Hz, 50 samples = 1 second.") {
                    SingleSliderInt(value: $s.warmupSamples, bounds: 10...100,
                                    labelWidth: lw, format: { String(format: "%.1fs", Double($0) / 50.0) })
                }

                Divider()

                advRow(icon: "clock.arrow.2.circlepath", title: "Report Interval",
                       help: "Accelerometer polling interval. 10ms = 100 Hz (default), 5ms = 200 Hz, 20ms = 50 Hz.") {
                    SingleSlider(value: $s.reportInterval, bounds: 5000...50000, step: 1000,
                                 labelWidth: lw, format: { String(format: "%.0fms", $0 / 1000) })
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func sensorList() -> some View {
        let adapters = controller.allAdapters
            .filter { $0.isAvailable }
            .sorted { a, b in
                if a.apiClassification != b.apiClassification {
                    return a.apiClassification == .publicAPI
                }
                return a.name < b.name
            }
        VStack(spacing: 0) {
            ForEach(Array(adapters.enumerated()), id: \.offset) { i, adapter in
                Toggle(isOn: sensorBinding(id: adapter.id.rawValue)) {
                    HStack(spacing: 4) {
                        Text(adapter.name).font(.caption)
                        Text(adapter.apiClassification.rawValue)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(adapter.apiClassification == .publicAPI ? Theme.pink : Theme.mauve)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background((adapter.apiClassification == .publicAPI ? Theme.pink : Theme.mauve).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
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
        let enabledCount = controller.allAdapters
            .filter { $0.isAvailable && settings.enabledSensorIDs.contains($0.id.rawValue) }.count
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
    private func advRow<Content: View>(icon: String, title: String, help: String,
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
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings

        AccordionCard(title: "Devices",
                      subtitle: "\(NSScreen.screens.count) displays, \(audioDevices.count) audio",
                      isExpanded: $isExpanded) {
            displayList()
            Divider()
            audioList()
        }
    }

    @ViewBuilder
    private func displayList() -> some View {
        let screens = NSScreen.screens.sorted { a, b in
            if a == NSScreen.main && b != NSScreen.main { return true }
            if b == NSScreen.main && a != NSScreen.main { return false }
            return a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "display", title: "Flash Displays",
                         help: "Select which monitors show the flash overlay on impact.")
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
            SettingHeader(icon: "hifispeaker", title: "Audio Output",
                         help: "Select which audio devices play impact sounds. None selected = no audio.")
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
                    Text("No output devices found")
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

    var body: some View {
        @Bindable var s = settings

        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "power")
                    .font(.system(size: 10)).foregroundStyle(Theme.pink)
                Text("Launch at Login")
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
                Text("Debug Logging")
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
                Text("v\(updater.currentVersion)")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
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
    }
}
