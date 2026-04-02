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
                .environmentObject(appDelegate.updater)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.settings)
                .environment(appDelegate.controller)
                .environmentObject(appDelegate.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
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

        guard let resourcePath = Bundle.main.resourcePath else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: resourcePath))?
            .filter { $0.hasPrefix("sound_") && $0.hasSuffix(".mp3") }
            .sorted() ?? []

        // Find the longest clip
        var longest: (url: URL, duration: Double) = (URL(fileURLWithPath: "/"), 0)
        for file in files {
            let url = URL(fileURLWithPath: resourcePath + "/" + file)
            if let s = NSSound(contentsOf: url, byReference: true), s.duration > longest.duration {
                longest = (url, s.duration)
            }
        }
        guard longest.duration > 0 else { return }

        // Play on every output device simultaneously at full volume
        controller.audioPlayer.playOnAllDevices(url: longest.url, volume: 1.0)
    }
}
