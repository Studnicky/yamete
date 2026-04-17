#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import SwiftUI
import AppKit

// MARK: - Devices (collapsible)

internal struct DeviceSection: View {
    @Environment(SettingsStore.self) var settings
    let audioDevices: [AudioOutputDevice]
    let displays: [NSScreen]
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings

        AccordionCard(title: NSLocalizedString("section_devices", comment: "Devices accordion title"),
                      subtitle: String(format: NSLocalizedString("devices_subtitle", comment: "Devices section subtitle: display and audio count"), displays.count, audioDevices.count),
                      isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                SettingHeader(icon: "display", title: NSLocalizedString("setting_flash_displays", comment: "Flash displays setting title"),
                             help: NSLocalizedString("help_flash_displays", comment: "Flash displays setting help text"))
                DeviceToggleList(
                    items: sortedDisplays.map { (name: $0.localizedName, id: $0.displayID) },
                    noneSelectedMessage: NSLocalizedString("no_displays_selected", comment: "No displays selected hint"),
                    selectedIDs: s.enabledDisplays,
                    binding: { id in arrayToggleBinding($s.enabledDisplays, element: id) })
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
    }

    private var sortedDisplays: [NSScreen] {
        displays.sorted { a, b in
            if a == NSScreen.main && b != NSScreen.main { return true }
            if b == NSScreen.main && a != NSScreen.main { return false }
            return a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
        }
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
