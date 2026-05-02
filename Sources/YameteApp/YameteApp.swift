import SwiftUI
import AppKit
#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import SensorKit
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
#if !RAW_SWIFTC_LUMP
// Under xcodebuild, this file compiles as part of the `Yamete` target
// (module name: Yamete), and pulls in the rest of the YameteApp surface
// (SettingsStore, Yamete, Updater, StatusBarController) via the YameteApp
// SPM library. Package.swift excludes this file from the YameteApp library
// itself, so an import here is NOT a self-import. Under the Makefile's
// raw-swiftc lump (RAW_SWIFTC_LUMP), every YameteApp/*.swift file (plus
// this one) compiles into a single module named YameteApp, so importing
// YameteApp from inside that module would be a self-import (warning →
// error under -warnings-as-errors), hence the guard.
import YameteApp
#endif

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
    lazy var yamete = Yamete(settings: settings)
    let updater = Updater()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindow.configureAsMenuBarApp()
        Migration.applyDeviceDefaults(settings: settings, sources: yamete.allSensorSources)
        Migration.reconcileSensors(settings: settings, sources: yamete.allSensorSources)
        Onboarding.promptMicrophoneIfNeeded(settings: settings)
        yamete.bootstrap()
        Onboarding.playWelcomeSoundIfFirstLaunch(yamete: yamete)
        updater.checkIfNeeded()

        statusBar = StatusBarController(
            settings: settings,
            yamete: yamete,
            updater: updater
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        yamete.shutdown()
    }
}

// MARK: - Window configuration

@MainActor private enum AppWindow {
    static func configureAsMenuBarApp() {
        // LSUIElement app: no dock icon, no menu bar app menu, no app windows.
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

    static func playWelcomeSoundIfFirstLaunch(yamete: Yamete) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: firstLaunchKey) else { return }
        d.set(true, forKey: firstLaunchKey)
        yamete.playWelcomeSound()
    }
}

// MARK: - Settings migration

@MainActor private enum Migration {
    private static let versionKey = "deviceSettingsVersion"

    static func applyDeviceDefaults(settings: SettingsStore, sources: [any SensorSource]) {
        let d = UserDefaults.standard
        guard d.integer(forKey: versionKey) < 1 else { return }

        if settings.enabledSensorIDs.isEmpty {
            settings.enabledSensorIDs = sources
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

    /// Removes sensor IDs whose source currently reports unavailable. If
    /// pruning leaves an empty set, falls back to enabling every available
    /// source so the pipeline still works.
    static func reconcileSensors(settings: SettingsStore, sources: [any SensorSource]) {
        let availableIDs = Set(sources.filter { $0.isAvailable }.map { $0.id.rawValue })
        let currentEnabled = Set(settings.enabledSensorIDs)
        let stillEnabled = currentEnabled.intersection(availableIDs)

        if stillEnabled.isEmpty && !availableIDs.isEmpty {
            settings.enabledSensorIDs = Array(availableIDs).sorted()
        } else if stillEnabled.count != currentEnabled.count {
            settings.enabledSensorIDs = Array(stillEnabled).sorted()
        }
    }
}
