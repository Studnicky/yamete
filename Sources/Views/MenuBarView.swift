import SwiftUI
import AppKit
import ServiceManagement

struct MenuBarView: View {
    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @EnvironmentObject var updater: Updater
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var audioDevices: [AudioOutputDevice] = []

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {

            // ═══════════════════════════════════════════════════════
            // HEADER: Enable + Launch at Login
            // ═══════════════════════════════════════════════════════
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: controller.isEnabled
                          ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle")
                        .foregroundStyle(controller.isEnabled ? Theme.pink : .secondary)
                    Text(controller.isEnabled ? "Enabled" : "Disabled")
                        .fontWeight(.semibold)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { controller.isEnabled },
                        set: { _ in controller.toggle() }
                    ))
                    .toggleStyle(.switch).tint(Theme.pink)
                    .labelsHidden()
                    .controlSize(.small)
                }
                HStack {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox).tint(Theme.pink)
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() }
                                else  { try SMAppService.mainApp.unregister() }
                            } catch { launchAtLogin = !on }
                        }
                    Spacer()
                }
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider()

            // ═══════════════════════════════════════════════════════
            // DETECTION
            // ═══════════════════════════════════════════════════════
            section("Sensitivity", help: "Impact force band. Below low: ignored. Above high: full response.") {
                RangeSlider(low: $settings.sensitivityMin, high: $settings.sensitivityMax,
                            bounds: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
            }
            Divider()

            section("Debounce", help: "Minimum seconds between reactions.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.debounce, in: 0...1.5)
                        .tint(Theme.pink)
                    Text(String(format: "%.1fs", settings.debounce))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Divider()

            // ═══════════════════════════════════════════════════════
            // OUTPUT
            // ═══════════════════════════════════════════════════════
            section("Volume", help: "Audio level range. Light impact → low, hard impact → high.") {
                RangeSlider(low: $settings.volumeMin, high: $settings.volumeMax,
                            bounds: 0...1, format: { "\(Int($0 * 100))%" })
            }
            Divider()

            section("Flash Opacity", help: "Screen flash brightness range. Light → dim, hard → bright.") {
                RangeSlider(low: $settings.flashOpacityMin, high: $settings.flashOpacityMax,
                            bounds: 0...1, format: { "\(Int($0 * 100))%" })
            }
            Divider()

            // ═══════════════════════════════════════════════════════
            // DEVICES
            // ═══════════════════════════════════════════════════════
            section("Flash Displays", help: "Which monitors show the flash overlay.") {
                let screens = NSScreen.screens
                VStack(spacing: 0) {
                    ForEach(0..<screens.count, id: \.self) { i in
                        let screen = screens[i]
                        let dispID = displayID(for: screen)
                        Toggle(isOn: displayBinding(dispID: dispID, screens: screens)) {
                            Text(screen.localizedName)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.checkbox)
                        .tint(Theme.pink)
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        if i < screens.count - 1 {
                            Divider().padding(.leading, 20)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Divider()

            section("Audio Output", help: "Which audio devices play impact sounds. None selected = system default.") {
                VStack(spacing: 0) {
                    ForEach(Array(audioDevices.enumerated()), id: \.offset) { i, device in
                        Toggle(isOn: audioBinding(uid: device.uid)) {
                            Text(device.name)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.checkbox)
                        .tint(Theme.pink)
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        if i < audioDevices.count - 1 {
                            Divider().padding(.leading, 20)
                        }
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
            Divider()

            // ═══════════════════════════════════════════════════════
            // ERROR (conditional)
            // ═══════════════════════════════════════════════════════
            if let error = controller.sensorError {
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                Divider()
            }

            // ═══════════════════════════════════════════════════════
            // FOOTER: Auto-Update | Impacts | Version | Quit
            // ═══════════════════════════════════════════════════════
            HStack(spacing: 6) {
                Toggle("Auto-Update", isOn: $settings.autoCheckForUpdates)
                    .toggleStyle(.checkbox)
                    .tint(Theme.pink)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)

            HStack {
                versionButton
                Spacer()
                Text("\(controller.impactCount)")
                    .font(.caption.monospacedDigit().bold()).foregroundStyle(Theme.deepRose)
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.deepRose)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 14).padding(.vertical, 6).padding(.bottom, 4)
        }
        .frame(width: 290)
        .onAppear { audioDevices = AudioDeviceManager.outputDevices() }
    }

    // MARK: - Version / Update button

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

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, help: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Theme.sectionHeader(title, help: help)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func displayID(for screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map(Int.init) ?? 0
    }

    private func audioBinding(uid: String) -> Binding<Bool> {
        @Bindable var s = settings
        return Binding<Bool>(
            get: { s.enabledAudioDevices.contains(uid) },
            set: { enabled in
                var uids = s.enabledAudioDevices
                if enabled {
                    if !uids.contains(uid) { uids.append(uid) }
                } else {
                    uids.removeAll { $0 == uid }
                }
                s.enabledAudioDevices = uids
            }
        )
    }

    private func displayBinding(dispID: Int, screens: [NSScreen]) -> Binding<Bool> {
        @Bindable var s = settings
        return Binding<Bool>(
            get: { s.enabledDisplays.isEmpty || s.enabledDisplays.contains(dispID) },
            set: { enabled in
                var ids = s.enabledDisplays.isEmpty
                    ? screens.map { displayID(for: $0) }
                    : s.enabledDisplays
                if enabled {
                    if !ids.contains(dispID) { ids.append(dispID) }
                } else {
                    ids.removeAll { $0 == dispID }
                }
                s.enabledDisplays = ids.count == screens.count ? [] : ids
            }
        )
    }
}
