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

        if !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
            controller.playWelcomeSound()
        }
    }
}
