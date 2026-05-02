#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import SwiftUI
import AppKit

// MARK: - Devices (collapsible)

internal struct DeviceSection: View {
    @Environment(SettingsStore.self) var settings
    let audioDevices: [AudioOutputDevice]
    let displays: [NSScreen]

    /// Identifier for each device collection bound by this section. Tests
    /// use these to assert toggling a single display does not mutate the
    /// audio-device list (and vice versa).
    internal enum CollectionID: String, CaseIterable, Sendable {
        case displays, audioDevices
    }

    /// Pure helper exposed for tests. Returns the array keyPath for the
    /// selected device collection.
    @MainActor
    internal static func collectionKeyPath(
        _ id: CollectionID
    ) -> PartialKeyPath<SettingsStore> {
        switch id {
        case .displays:     return \SettingsStore.enabledDisplays
        case .audioDevices: return \SettingsStore.enabledAudioDevices
        }
    }
    public var body: some View {
        @Bindable var s = settings

        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "display", title: NSLocalizedString("setting_flash_displays", comment: "Flash displays setting title"),
                         help: NSLocalizedString("help_flash_displays", comment: "Flash displays setting help text"))
            EnableToggleRow(icon: "cursorarrow.rays",
                            title: NSLocalizedString("setting_flash_active_display", comment: "Flash active display only toggle label"),
                            isOn: $s.flashActiveDisplayOnly,
                            dimmed: true)
            DeviceToggleList(
                items: sortedDisplays.map { (name: $0.localizedName, id: $0.displayID) },
                noneSelectedMessage: NSLocalizedString("no_displays_selected", comment: "No displays selected hint"),
                selectedIDs: s.enabledDisplays,
                binding: { id in arrayToggleBinding($s.enabledDisplays, element: id) })
            .opacity(s.flashActiveDisplayOnly ? 0.35 : 1.0)
            .allowsHitTesting(!s.flashActiveDisplayOnly)
        }
        .padding(Theme.sectionPadding)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "hifispeaker", title: NSLocalizedString("setting_audio_output", comment: "Audio output setting title"),
                         help: NSLocalizedString("help_audio_output", comment: "Audio output setting help text"))
            DeviceToggleList(
                items: sortedAudioDevices.map { (name: $0.displayName, id: $0.uid) },
                emptyMessage: NSLocalizedString("no_output_devices", comment: "No audio output hardware detected"),
                noneSelectedMessage: NSLocalizedString("no_audio_selected", comment: "No audio devices selected hint"),
                selectedIDs: s.enabledAudioDevices,
                binding: { uid in arrayToggleBinding($s.enabledAudioDevices, element: uid) })
        }
        .padding(Theme.sectionPadding)
    }

    private var sortedDisplays: [NSScreen] {
        // CGMainDisplayID() is the hardware primary display (menu bar screen) —
        // stable regardless of which window has focus. NSScreen.main changes with
        // the key window and cannot be used here.
        let mainID = Int(CGMainDisplayID())
        let others = displays
            .filter { $0.displayID != mainID }
            .sorted {
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                return $0.frame.minY < $1.frame.minY
            }
        guard let main = displays.first(where: { $0.displayID == mainID }) else {
            return others
        }
        return [main] + others
    }

    private var sortedAudioDevices: [AudioOutputDevice] {
        let defaultUID = AudioDeviceManager.defaultDeviceUID
        return audioDevices.sorted { a, b in
            if a.uid == defaultUID && b.uid != defaultUID { return true }
            if b.uid == defaultUID && a.uid != defaultUID { return false }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }
}
