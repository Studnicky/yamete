import SwiftUI
import AppKit
#if canImport(ResponseKit)
import ResponseKit
#endif

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
        migrateDeviceDefaults()
        controller.bootstrap()

        if !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
            controller.playWelcomeSound()
        }
    }

    /// Migrate from "empty = all" to "empty = none" by populating device arrays.
    private func migrateDeviceDefaults() {
        let d = UserDefaults.standard
        let key = "deviceSettingsVersion"
        guard d.integer(forKey: key) < 1 else { return }

        if settings.enabledSensorIDs.isEmpty {
            settings.enabledSensorIDs = controller.allAdapters
                .filter { $0.isAvailable }
                .map(\.id.rawValue)
        }
        if settings.enabledDisplays.isEmpty {
            settings.enabledDisplays = NSScreen.screens.map { $0.displayID }
        }
        if settings.enabledAudioDevices.isEmpty {
            if let uid = AudioDeviceManager.defaultDeviceUID {
                settings.enabledAudioDevices = [uid]
            }
        }
        d.set(1, forKey: key)
    }
}
