#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Footer

internal struct FooterSection: View {
    private static let privacyPolicyURL = URL(string: "https://studnicky.github.io/yamete/privacy.html")!
    private static let supportURL = URL(string: "https://studnicky.github.io/yamete/support.html")!

    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    public var body: some View {
        @Bindable var s = settings

        HStack(alignment: .top, spacing: 0) {

            // Left footer — System preferences
            VStack(spacing: 0) {
                FooterRow(icon: "power",
                          label: NSLocalizedString("label_launch_at_login", comment: "Launch at login toggle label")) {
                    Toggle("", isOn: $launchAtLogin)
                        .themeMiniSwitch()
                        .accessibilityLabel(Text(NSLocalizedString("label_launch_at_login", comment: "Launch at login toggle label")))
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() }
                                else  { try SMAppService.mainApp.unregister() }
                            } catch { launchAtLogin = !on }
                        }
                }

                if AppLog.supportsDebugLogging {
                    FooterRow(icon: "ladybug",
                              label: NSLocalizedString("label_debug_logging", comment: "Debug logging toggle label")) {
                        Toggle("", isOn: $s.debugLogging)
                            .themeMiniSwitch()
                            .accessibilityLabel(Text(NSLocalizedString("label_debug_logging", comment: "Debug logging toggle label")))
                    }
                }

                FooterRow(icon: "arrow.counterclockwise",
                          label: NSLocalizedString("label_reset_settings", comment: "Reset settings label")) {
                    PillButton(title: NSLocalizedString("button_reset", comment: "Reset to defaults button"),
                               action: { confirmAndReset() })
                }
                .padding(.bottom, 4)
            }
            .frame(width: Theme.columnWidth)

            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1)

            // Right footer — Info + actions
            VStack(spacing: 0) {
                // Version / update status
                FooterRow(
                    leading: { updateStatusLeading },
                    label: { updateStatusLabel },
                    trailing: { updateStatusTrailing }
                )

                // Links
                FooterRow(icon: "link",
                          label: NSLocalizedString("label_links", comment: "Footer links section label")) {
                    HStack(spacing: 6) {
                        LinkPillButton(title: NSLocalizedString("button_privacy", comment: "Privacy policy button"),
                                       url: Self.privacyPolicyURL)
                        LinkPillButton(title: NSLocalizedString("button_support", comment: "Support button"),
                                       url: Self.supportURL)
                    }
                }

                // Quit
                FooterRow(icon: "power.circle",
                          label: NSLocalizedString("label_quit", comment: "Quit label")) {
                    Button(action: { NSApp.terminate(nil) }) {
                        Text(NSLocalizedString("button_quit", comment: "Quit application button"))
                            .themePillButton(bold: true)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q")
                }
                .padding(.bottom, 4)
            }
            .frame(width: Theme.columnWidth)
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

    // MARK: - Update / version row composition
    //
    // The version-line is uniform in shape (icon, caption, optional trailing
    // button) but each piece varies by build flavor and update state.
    // Splitting them into computed views keeps the FooterRow composition
    // declarative and free of #if branching at the row level.

    @ViewBuilder
    private var updateStatusLeading: some View {
        #if DIRECT_BUILD
        switch updater.state {
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.pink)
        case .upToDate:
            ThemedFooterIcon(symbol: "checkmark.circle")
        case .failed:
            ThemedFooterIcon(symbol: "exclamationmark.triangle")
        case .idle:
            ThemedFooterIcon(symbol: "info.circle")
        }
        #else
        ThemedFooterIcon(symbol: "info.circle")
        #endif
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        #if DIRECT_BUILD
        switch updater.state {
        case .checking:
            FooterCaption(text: NSLocalizedString("update_checking", comment: "Checking for updates status"),
                          style: .tertiary)
        case .available(let version, _):
            FooterCaption(text: String(format: NSLocalizedString("update_available_format", comment: "Update available label"), version),
                          style: .pink)
        case .downloading:
            FooterCaption(text: NSLocalizedString("update_downloading", comment: "Downloading update status"),
                          style: .tertiary)
        case .installing:
            FooterCaption(text: NSLocalizedString("update_installing", comment: "Installing update status"),
                          style: .tertiary)
        case .failed(let message):
            FooterCaption(text: String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion),
                          style: .tertiary)
                .help(message)
        case .idle, .upToDate:
            FooterCaption(text: String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion),
                          style: .tertiary)
        }
        #else
        FooterCaption(text: String(format: NSLocalizedString("version_format", comment: "App version label"), updater.currentVersion),
                      style: .tertiary)
        #endif
    }

    @ViewBuilder
    private var updateStatusTrailing: some View {
        #if DIRECT_BUILD
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
        #else
        EmptyView()
        #endif
    }
}
