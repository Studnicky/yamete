#if canImport(YameteCore)
import YameteCore
#endif
import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Footer

internal struct FooterSection: View {
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
                    .themeMiniSwitch()
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
                        .themeMiniSwitch()
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
                #if DIRECT_BUILD
                updateStatusIcon
                updateStatusLabel
                Spacer()
                updateActionButton
                #else
                Image(systemName: "info.circle")
                    .themeFooterIcon()
                Text(String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                #endif
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

    // MARK: - Auto-update views (Direct build only)

    #if DIRECT_BUILD
    @ViewBuilder
    private var updateStatusIcon: some View {
        switch updater.state {
        case .checking, .downloading, .installing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .upToDate:
            Image(systemName: "checkmark.circle")
                .themeFooterIcon()
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.pink)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .themeFooterIcon()
        case .idle:
            Image(systemName: "info.circle")
                .themeFooterIcon()
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updater.state {
        case .checking:
            Text(NSLocalizedString("update_checking", comment: "Checking for updates status"))
                .font(.caption).foregroundStyle(.tertiary)
        case .available(let version, _):
            Text(String(format: NSLocalizedString("update_available_format", comment: "Update available label"), version))
                .font(.caption).foregroundStyle(Theme.pink)
        case .downloading:
            Text(NSLocalizedString("update_downloading", comment: "Downloading update status"))
                .font(.caption).foregroundStyle(.tertiary)
        case .installing:
            Text(NSLocalizedString("update_installing", comment: "Installing update status"))
                .font(.caption).foregroundStyle(.tertiary)
        case .failed(let message):
            Text(String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion))
                .font(.caption).foregroundStyle(.tertiary)
                .help(message)
        case .idle, .upToDate:
            Text(String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        switch updater.state {
        case .idle, .upToDate, .failed:
            Button(action: { updater.checkForUpdates() }) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.pink.opacity(0.6))
            .help(NSLocalizedString("update_check_tooltip", comment: "Check for updates tooltip"))
        case .available:
            Button(action: { updater.installUpdate() }) {
                Text(NSLocalizedString("button_update", comment: "Install update button"))
                    .themePillButton(background: Theme.pink, foreground: .white)
            }
            .buttonStyle(.plain)
        case .checking, .downloading, .installing:
            EmptyView()
        }
    }
    #endif
}
