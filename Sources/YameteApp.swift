import SwiftUI
import AppKit

@main
struct YameteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.settings)
                .environment(appDelegate.controller)
                .environment(appDelegate.updater)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.settings)
                .environment(appDelegate.controller)
                .environment(appDelegate.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    lazy var controller = ImpactController(settings: settings)
    let updater = Updater()

    private static let firstLaunchKey = "hasCompletedFirstLaunch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        playFirstLaunchMoan()
        updater.autoCheckIfNeeded(settings: settings)
    }

    /// On first launch, play the longest bundled clip on all output devices.
    private func playFirstLaunchMoan() {
        guard !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)

        guard let url = controller.audioPlayer.longestSoundURL else { return }
        controller.audioPlayer.playOnAllDevices(url: url, volume: 1.0)
    }
}
