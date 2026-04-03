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

    /// On first launch after install, play the longest sound on ALL audio devices at full volume.
    private func playFirstLaunchMoan() {
        guard !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)

        let urls = BundleResources.urls(prefix: "sound_", extensions: ["mp3"])

        // Find the longest clip
        var longest: (url: URL, duration: Double) = (URL(fileURLWithPath: "/"), 0)
        for url in urls {
            if let s = NSSound(contentsOf: url, byReference: true), s.duration > longest.duration {
                longest = (url, s.duration)
            }
        }
        guard longest.duration > 0 else { return }

        // Play on every output device simultaneously at full volume
        controller.audioPlayer.playOnAllDevices(url: longest.url, volume: 1.0)
    }
}
