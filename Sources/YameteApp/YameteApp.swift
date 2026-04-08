import SwiftUI
import AppKit
#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(SensorKit)
import SensorKit
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
#if canImport(YameteApp)
import YameteApp
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

// MARK: - App delegate (NSApplicationDelegate protocol requirement)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    lazy var controller = ImpactController(settings: settings)
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindow.configureAsMenuBarApp()
        Migration.applyDeviceDefaults(settings: settings, adapters: controller.allAdapters)
        Onboarding.promptMicrophoneIfNeeded(settings: settings)
        controller.bootstrap()
        Onboarding.playWelcomeSoundIfFirstLaunch(controller: controller)
    }
}

// MARK: - Window configuration

@MainActor private enum AppWindow {
    static func configureAsMenuBarApp() {
        NSApp.setActivationPolicy(.accessory)
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = icon
        }
    }
}

// MARK: - First-run onboarding

@MainActor private enum Onboarding {
    private static let micPromptKey = "hasShownMicrophonePrompt"
    private static let firstLaunchKey = "hasCompletedFirstLaunch"

    static func promptMicrophoneIfNeeded(settings: SettingsStore) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: micPromptKey) else { return }
        d.set(true, forKey: micPromptKey)

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("mic_onboarding_title", comment: "Microphone onboarding dialog title")
        alert.informativeText = NSLocalizedString("mic_onboarding_body", comment: "Microphone onboarding dialog body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("mic_onboarding_allow", comment: "Microphone onboarding allow button"))
        alert.addButton(withTitle: NSLocalizedString("mic_onboarding_skip", comment: "Microphone onboarding skip button"))

        if alert.runModal() == .alertSecondButtonReturn {
            settings.enabledSensorIDs = settings.enabledSensorIDs.filter { $0 != SensorID.microphone.rawValue }
        }
    }

    static func playWelcomeSoundIfFirstLaunch(controller: ImpactController) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: firstLaunchKey) else { return }
        d.set(true, forKey: firstLaunchKey)
        controller.playWelcomeSound()
    }
}

// MARK: - Settings migration

@MainActor private enum Migration {
    private static let versionKey = "deviceSettingsVersion"

    static func applyDeviceDefaults(settings: SettingsStore, adapters: [any SensorAdapter]) {
        let d = UserDefaults.standard
        guard d.integer(forKey: versionKey) < 1 else { return }

        if settings.enabledSensorIDs.isEmpty {
            settings.enabledSensorIDs = adapters
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
        d.set(1, forKey: versionKey)
    }
}
