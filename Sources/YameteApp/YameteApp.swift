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
// Note: no `import YameteApp` — in the Makefile build, all YameteApp/*.swift
// files (plus this one) compile into a single module named YameteApp, so a
// self-import is a no-op warning that becomes an error under -warnings-as-errors.

@main
struct YameteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar UI is managed by StatusBarController (NSStatusItem +
        // custom NSPanel) rather than MenuBarExtra, giving us direct control
        // over the panel's backing material and initial sizing.
        // An empty Settings scene satisfies the Scene requirement.
        Settings { EmptyView() }
    }
}

// MARK: - App delegate (NSApplicationDelegate protocol requirement)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    lazy var controller = ImpactController(settings: settings)
    let updater = Updater()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindow.configureAsMenuBarApp()
        Migration.applyDeviceDefaults(settings: settings, adapters: controller.allAdapters)
        Migration.reconcileSensors(settings: settings, adapters: controller.allAdapters)
        Onboarding.promptMicrophoneIfNeeded(settings: settings)
        controller.bootstrap()
        Onboarding.playWelcomeSoundIfFirstLaunch(controller: controller)
        updater.checkIfNeeded()

        statusBar = StatusBarController(
            settings: settings,
            controller: controller,
            updater: updater
        )
    }
}

// MARK: - Window configuration

@MainActor private enum AppWindow {
    static func configureAsMenuBarApp() {
        // LSUIElement app: no dock icon, no menu bar app menu, no app windows.
        // Setting the activation policy to .accessory pins it to the menu bar
        // extra only. There is intentionally no NSApp.applicationIconImage
        // setup here — Yamete has no dock tile to render an icon into.
        NSApp.setActivationPolicy(.accessory)
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

    /// Runs on every launch (not just first install). Removes any sensor IDs
    /// from `enabledSensorIDs` whose adapter currently reports unavailable.
    /// If pruning leaves the user with no enabled sensors at all, falls back
    /// to enabling every currently-available adapter so the pipeline still
    /// works. This handles two real cases:
    ///   1. App Store build where the accelerometer is permanently
    ///      unavailable (sandbox blocks IORegistry writes) but the user's
    ///      persisted settings list it as enabled.
    ///   2. Headphone motion adapter that becomes unavailable when AirPods
    ///      disconnect (re-runs whenever the menu refreshes).
    static func reconcileSensors(settings: SettingsStore, adapters: [any SensorAdapter]) {
        let availableIDs = Set(adapters.filter { $0.isAvailable }.map { $0.id.rawValue })
        let currentEnabled = Set(settings.enabledSensorIDs)
        let stillEnabled = currentEnabled.intersection(availableIDs)

        if stillEnabled.isEmpty && !availableIDs.isEmpty {
            // No previously enabled sensors are available — fall back to all
            // currently-available adapters so the pipeline still detects
            // impacts. Without this the user sees a working app with no
            // active inputs.
            settings.enabledSensorIDs = Array(availableIDs).sorted()
        } else if stillEnabled.count != currentEnabled.count {
            // Prune unavailable IDs but keep the rest.
            settings.enabledSensorIDs = Array(stillEnabled).sorted()
        }
    }
}
