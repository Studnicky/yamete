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
            SlidersSection()
            Divider()
            DeviceSection(audioDevices: audioDevices)
            Divider()
            AdvancedSection()

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

// MARK: - Sliders (debounce first, then sensitivity, volume, opacity)

private struct SlidersSection: View {
    @Environment(SettingsStore.self) var settings

    var body: some View {
        @Bindable var settings = settings

        Group {
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "gauge.with.needle",
                              title: "Reactivity",
                              help: "Impact force response window. The low thumb sets the weakest force that triggers any response — forces below this are ignored. The high thumb sets the force that produces maximum response. The detected force maps linearly between the two to produce a 0–1 intensity value that drives volume, opacity, and clip selection. Higher values = responds to lighter impacts.")
                SensitivityRuler()
                RangeSlider(low: $settings.sensitivityMin, high: $settings.sensitivityMax,
                            bounds: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "speaker.wave.2",
                              title: "Volume",
                              help: "Audio playback level window. The normalized intensity (0–1) from Reactivity maps linearly between these two values. Low thumb = volume for the lightest detected impact. High thumb = volume for the hardest impact. The sound clip is also selected by intensity — lighter impacts play shorter clips, harder impacts play longer ones.")
                RangeSlider(low: $settings.volumeMin, high: $settings.volumeMax,
                            bounds: 0...1, format: { "\(Int($0 * 100))%" })
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "sun.max",
                              title: "Flash Opacity",
                              help: "Screen flash brightness window. The normalized intensity maps between these values to set the peak opacity of the radial vignette overlay. The flash envelope (attack/hold/decay timing) is also shaped by intensity — hard impacts have fast attack and long sustain, light impacts have slow attack and quick decay. The entire flash is gated inside the sound clip duration.")
                RangeSlider(low: $settings.flashOpacityMin, high: $settings.flashOpacityMax,
                            bounds: 0...1, format: { "\(Int($0 * 100))%" })
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: - Sensitivity ruler

private struct SensitivityRuler: View {
    // Tick marks: sensitivity % → force label
    // Sensitivity inverts: high sensitivity = low force threshold
    // Force = intensityFloor + threshold × (intensityCeiling - intensityFloor)
    // where threshold = 1.0 - sensitivity
    private static let ticks: [(position: Double, label: String)] = [
        (0.0,  "Hard"),
        (0.25, "Firm"),
        (0.50, "Med"),
        (0.75, "Light"),
        (1.0,  "Tap"),
    ]

    var body: some View {
        // Offset to align with the RangeSlider track (matching its 30pt label + 8pt spacing)
        HStack(spacing: 8) {
            Spacer().frame(width: 30)
            GeometryReader { geo in
                let w = geo.size.width
                ForEach(Array(Self.ticks.enumerated()), id: \.offset) { _, tick in
                    VStack(spacing: 1) {
                        Text(tick.label)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 1, height: 4)
                    }
                    .position(x: tick.position * w, y: 8)
                }
            }
            .frame(height: 16)
            Spacer().frame(width: 30)
        }
    }
}

// MARK: - Devices (displays + audio output)

private struct DeviceSection: View {
    @Environment(SettingsStore.self) var settings
    let audioDevices: [AudioOutputDevice]
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings

        AccordionCard(title: "Device Settings",
                      subtitle: "\(NSScreen.screens.count) displays, \(audioDevices.count) audio",
                      isExpanded: $isExpanded) {
            displayList(settings: s)
            Divider()
            audioList(settings: s)
        }
    }

    @ViewBuilder
    private func displayList(settings s: SettingsStore) -> some View {
        let screens = NSScreen.screens
        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "display", title: "Flash Displays",
                         help: "Select which monitors show the full-screen flash overlay on impact. Unchecked monitors are skipped. If all are checked (or none), all monitors flash.")
            VStack(spacing: 0) {
                ForEach(0..<screens.count, id: \.self) { i in
                    let screen = screens[i]
                    let dispID = displayID(for: screen)
                    Toggle(isOn: displayBinding(dispID: dispID, screens: screens)) {
                        Text(screen.localizedName).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox).tint(Theme.pink)
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    if i < screens.count - 1 { Divider().padding(.leading, 20) }
                }
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .help("Select which monitors show the full-screen flash overlay on impact. Unchecked monitors are skipped. If all are checked (or none), all monitors flash.")
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    private func audioList(settings s: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "hifispeaker", title: "Audio Output",
                         help: "Select which audio output devices play impact sounds. Checked devices play simultaneously. If none are checked, the system default output is used.")
            VStack(spacing: 0) {
                ForEach(Array(audioDevices.enumerated()), id: \.offset) { i, device in
                    Toggle(isOn: audioBinding(uid: device.uid)) {
                        Text(device.displayName).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox).tint(Theme.pink)
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    if i < audioDevices.count - 1 { Divider().padding(.leading, 20) }
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
        .help("Select which audio output devices play impact sounds. Checked devices play simultaneously. If none are checked, the system default output is used.")
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func displayID(for screen: NSScreen) -> Int { screen.displayID }

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

    private func displayBinding(dispID: Int, screens: [NSScreen]) -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { s.enabledDisplays.isEmpty || s.enabledDisplays.contains(dispID) },
            set: { enabled in
                var ids = s.enabledDisplays.isEmpty
                    ? screens.map { displayID(for: $0) } : s.enabledDisplays
                if enabled { if !ids.contains(dispID) { ids.append(dispID) } }
                else { ids.removeAll { $0 == dispID } }
                s.enabledDisplays = ids.count == screens.count ? [] : ids
            }
        )
    }
}

// MARK: - Sensitivity settings (collapsible)

private struct AdvancedSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    var body: some View {
        @Bindable var s = settings

        AccordionCard(title: "Sensitivity Settings", isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    advRow(icon: "waveform.path", title: "Frequency Band",
                           help: "Bandpass filter on raw accelerometer data. Low thumb = high-pass cutoff (rejects floor vibrations, footsteps at 5–10 Hz, HVAC rumble). High thumb = low-pass cutoff (rejects electronic noise, high-frequency rattle). Only energy between the two frequencies reaches the spike detector.") {
                        RangeSlider(low: $s.bandpassLowHz, high: $s.bandpassHighHz,
                                    bounds: 10...25, format: { "\(Int($0)) Hz" })
                    }
                    Divider()

                    advRow(icon: "timer", title: "Cooldown",
                           help: "Minimum time between reactions. Controls both the fusion engine rearm (won't detect a new impact until this time passes) and the response gating (won't play audio/flash). 0 = reactions gated only by the playing clip's duration.") {
                        HStack(spacing: 8) {
                            Slider(value: $s.debounce, in: 0...2).tint(Theme.pink)
                            Text(String(format: "%.1fs", s.debounce))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Divider()

                    advRow(icon: "arrow.up.to.line", title: "Spike Threshold",
                           help: "Minimum filtered acceleration magnitude (in g-force) to consider as a potential impact. The bandpass filter removes gravity and noise first — this threshold applies to what remains. Vibrations below this are ignored entirely. Higher values require more force to trigger.") {
                        HStack(spacing: 8) {
                            Slider(value: $s.spikeThreshold, in: 0.010...0.040).tint(Theme.pink)
                            Text(String(format: "%.3fg", s.spikeThreshold))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    Divider()

                    advRow(icon: "chart.line.uptrend.xyaxis", title: "Crest Factor",
                           help: "The peak signal must exceed the background noise level (RMS) by this multiple. A sharp desk hit spikes well above a quiet background (high crest factor ~10–20×). Footsteps and floor vibrations raise the background noise along with the peak (low crest factor ~2–3×). Higher values reject more ambient vibration but require the desk to be quieter before a hit registers.") {
                        HStack(spacing: 8) {
                            Slider(value: $s.crestFactor, in: 2.0...10.0).tint(Theme.pink)
                            Text(String(format: "%.1f×", s.crestFactor))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Divider()

                    advRow(icon: "bolt", title: "Rise Rate",
                           help: "Minimum magnitude increase between two consecutive samples (at 50 Hz, each sample is 20ms apart). Direct impacts on the desk surface rise in 1–2 samples (~20–40ms). Vibrations transmitted through the floor via desk legs rise more gradually over 3–5 samples. Higher values require faster onset, rejecting indirect transmitted vibration.") {
                        HStack(spacing: 8) {
                            Slider(value: $s.riseRate, in: 0.005...0.020).tint(Theme.pink)
                            Text(String(format: "%.3f", s.riseRate))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Divider()

                    advRow(icon: "checkmark.circle", title: "Confirmations",
                           help: "Number of above-threshold samples required within the 120ms detection window. A direct hit produces a cluster of 3–5 high-magnitude samples as the desk surface vibrates. A single transmitted jolt (footstep through desk legs) typically produces only 1–2. Higher values require more sustained energy, rejecting brief single-sample spikes.") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { Double(s.confirmations) },
                                set: { s.confirmations = Int($0.rounded()) }
                            ), in: 1...5).tint(Theme.pink)
                            Text("\(s.confirmations)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Divider()

                    advRow(icon: "flame", title: "Warmup",
                           help: "Number of samples to collect before detection activates after app start. The bandpass filters and background RMS estimator need time to settle — without warmup, the first few seconds produce false detections from filter transients. At 50 Hz sample rate, 30 samples = 0.6 seconds of settling time.") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { Double(s.warmupSamples) },
                                set: { s.warmupSamples = Int($0.rounded()) }
                            ), in: 10...100).tint(Theme.pink)
                            Text("\(s.warmupSamples)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
        }
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

// MARK: - Footer

private struct FooterSection: View {
    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            // Info row: counter + last impact tier
            HStack {
                Text("\(controller.impactCount) impacts today")
                Spacer()
                if let tier = controller.lastImpactTier {
                    Text(verbatim: "last: \(tier) (\(String(format: "%.3fg", controller.lastImpactMagnitude)))")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 4)

            Divider()

            // Launch at Login toggle
            HStack(spacing: 5) {
                Image(systemName: "power")
                    .font(.system(size: 10)).foregroundStyle(Theme.pink)
                Text("Launch at Login")
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).tint(Theme.pink)
                    .labelsHidden().controlSize(.small)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else  { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = !on }
                    }
            }
            .help("Register Yamete to start automatically when you log in to macOS.")
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 4)

            // Auto-Update + version
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10)).foregroundStyle(Theme.pink)
                versionButton
                Spacer()
                Toggle("Auto-Update", isOn: $settings.autoCheckForUpdates)
                    .toggleStyle(.switch).tint(Theme.pink)
                    .labelsHidden().controlSize(.small)
            }
            .help("Automatically check GitHub for new releases once per day. When an update is found, you'll be prompted to install it.")
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 4)

            Divider()

            // Pause + Quit
            HStack {
                Button(action: { controller.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: controller.isEnabled
                              ? "pause.circle.fill" : "play.circle.fill")
                        Text(controller.isEnabled ? "Pause" : "Resume")
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(controller.isEnabled ? Theme.pink : .secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Theme.deepRose)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 14).padding(.vertical, 6).padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var versionButton: some View {
        switch updater.state {
        case .idle:
            Button("v\(version)") { updater.checkForUpdate() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary)
                .help("Check for updates")
        case .checking:
            Text("Checking…").font(.caption).foregroundStyle(Theme.mauve)
        case .upToDate:
            Text("v\(version) ✓").font(.caption).foregroundStyle(Theme.pink)
        case .available(let v):
            Button("v\(v) available") { updater.downloadAndInstall() }
                .buttonStyle(.plain).font(.caption.bold()).foregroundStyle(Theme.pink)
        case .downloading:
            Text("Installing…").font(.caption).foregroundStyle(Theme.mauve)
        case .readyToRestart:
            Button("Restart to update") { updater.relaunch() }
                .buttonStyle(.plain).font(.caption.bold()).foregroundStyle(Theme.deepRose)
        case .failed(let msg):
            Button("v\(version) ✗") { updater.checkForUpdate() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.red)
                .help(msg)
        }
    }
}
