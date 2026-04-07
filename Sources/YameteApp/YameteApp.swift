import SwiftUI
import AppKit
import YameteCore
import SensorKit
import ResponseKit
import YameteApp

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
    private static let microphonePromptKey = "hasShownMicrophonePrompt"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateDeviceDefaults()
        showMicrophoneOnboardingIfNeeded()
        controller.bootstrap()

        if !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
            controller.playWelcomeSound()
        }
    }

    /// On first launch, explain microphone usage before the pipeline starts.
    /// "Allow" proceeds normally (macOS shows its own permission dialog when
    /// AVAudioEngine starts). "Skip" removes the microphone adapter from the
    /// enabled sensor list so it never requests permission.
    private func showMicrophoneOnboardingIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.microphonePromptKey) else { return }
        d.set(true, forKey: Self.microphonePromptKey)

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("mic_onboarding_title", comment: "Microphone onboarding dialog title")
        alert.informativeText = NSLocalizedString("mic_onboarding_body", comment: "Microphone onboarding dialog body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("mic_onboarding_allow", comment: "Microphone onboarding allow button"))
        alert.addButton(withTitle: NSLocalizedString("mic_onboarding_skip", comment: "Microphone onboarding skip button"))

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // User chose Skip — disable microphone adapter
            settings.enabledSensorIDs = settings.enabledSensorIDs.filter { $0 != "microphone" }
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
