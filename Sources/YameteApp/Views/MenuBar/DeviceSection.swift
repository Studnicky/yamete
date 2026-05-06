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

    @State private var devicesGroupExpanded: Bool = false

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

        SensorAccordionCard(
            title: NSLocalizedString("section_devices", comment: "Devices master group title"),
            icon: "tv.and.hifispeaker.fill",
            isEnabled: masterDevicesBinding(),
            isExpanded: $devicesGroupExpanded,
            help: NSLocalizedString("help_devices", comment: "Devices master toggle help")
        ) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingHeader(icon: "display", title: NSLocalizedString("setting_flash_displays", comment: "Flash displays setting title"),
                                 help: NSLocalizedString("help_flash_displays", comment: "Flash displays setting help text"))
                    // The "active display only" toggle is meaningful only
                    // when the user has at least two displays selected —
                    // with 0 or 1 selected, "active display" and "the
                    // selected display(s)" resolve to the same target
                    // (or to nothing), so the toggle would be confusing
                    // UI noise.
                    if s.enabledDisplays.count >= 2 {
                        EnableToggleRow(icon: "cursorarrow.rays",
                                        title: NSLocalizedString("setting_flash_active_display", comment: "Flash active display only toggle label"),
                                        isOn: $s.flashActiveDisplayOnly,
                                        dimmed: true)
                    }
                    DeviceToggleList(
                        items: sortedDisplays.map { (name: $0.localizedName, id: $0.displayID) },
                        noneSelectedMessage: NSLocalizedString("no_displays_selected", comment: "No displays selected hint"),
                        selectedIDs: s.enabledDisplays,
                        binding: { id in arrayToggleBinding($s.enabledDisplays, element: id) })
                    .opacity(s.enabledDisplays.count >= 2 && s.flashActiveDisplayOnly ? 0.35 : 1.0)
                    .allowsHitTesting(!(s.enabledDisplays.count >= 2 && s.flashActiveDisplayOnly))
                }
                .padding(Theme.sectionPadding)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingHeader(icon: "hifispeaker", title: NSLocalizedString("setting_audio_output", comment: "Audio output setting title"),
                                 help: NSLocalizedString("help_audio_output", comment: "Audio output setting help text"))
                    // Active-output-only mirrors the active-display-only
                    // toggle: when on, the audio dispatch ignores the
                    // per-device selection and routes to the system
                    // default output. Hidden when ≤1 audio device is
                    // selected — same rationale as the display side.
                    if s.enabledAudioDevices.count >= 2 {
                        EnableToggleRow(icon: "speaker.wave.2.bubble",
                                        title: NSLocalizedString("setting_audio_active_output",
                                                                 comment: "Audio active output only toggle label"),
                                        isOn: $s.audioActiveOutputOnly,
                                        dimmed: true)
                    }
                    DeviceToggleList(
                        items: sortedAudioDevices.map { (name: $0.displayName, id: $0.uid) },
                        emptyMessage: NSLocalizedString("no_output_devices", comment: "No audio output hardware detected"),
                        noneSelectedMessage: NSLocalizedString("no_audio_selected", comment: "No audio devices selected hint"),
                        selectedIDs: s.enabledAudioDevices,
                        leadingIcon: { uid in audioRowIcon(forUID: uid) },
                        trailingFootnote: { uid in audioRowFootnote(forUID: uid) },
                        binding: { uid in arrayToggleBinding($s.enabledAudioDevices, element: uid) })
                    .opacity(s.enabledAudioDevices.count >= 2 && s.audioActiveOutputOnly ? 0.35 : 1.0)
                    .allowsHitTesting(!(s.enabledAudioDevices.count >= 2 && s.audioActiveOutputOnly))
                }
                .padding(Theme.sectionPadding)
            }
            .dimmedWhenMasterOff(s.devicesMasterEnabled)
        }
    }

    /// Override-disable kill switch for the Devices group. Reads/writes
    /// `settings.devicesMasterEnabled` only. When false, every output's
    /// device routing falls back to the empty set so flashes/sounds
    /// don't route to the user's display/audio selections; per-device
    /// toggles are preserved verbatim. The dispatch gate is read by
    /// each output's config helper in `SettingsStore`.
    private func masterDevicesBinding() -> Binding<Bool> {
        @Bindable var s = settings
        return Binding(
            get: { s.devicesMasterEnabled },
            set: { newValue in s.devicesMasterEnabled = newValue }
        )
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

    /// Live (audioUID → CGDirectDisplayID) map. Recomputed every body
    /// pass — `pair()` is cheap (≤10 audio devices, ≤5 displays in any
    /// realistic setup) and the cache invalidation across hot-plug is
    /// handled implicitly because both `audioDevices` and `displays`
    /// are state inputs that change on hardware events.
    private var audioToDisplayPairing: [String: CGDirectDisplayID] {
        DisplayAudioPairing.pair(audioDevices: audioDevices, displays: displays)
    }

    /// SF Symbol name for the audio row's leading icon, derived from
    /// transport class. Display-class transports get the `tv` family;
    /// built-in gets `laptopcomputer` so the user instantly knows
    /// "this is the speakers in the laptop chassis."
    private func audioRowIcon(forUID uid: String) -> String? {
        guard let device = audioDevices.first(where: { $0.uid == uid }) else { return nil }
        switch device.transport {
        case .builtIn:     return "laptopcomputer"
        case .displayPort: return "tv"
        case .hdmi:        return "tv"
        case .usb:         return "cable.connector"
        case .bluetooth:   return "headphones.bluetooth"
        case .headphone:   return "headphones"
        case .thunderbolt: return "bolt.horizontal"
        case .unknown:     return "hifispeaker"
        }
    }

    /// "attached to <display name>" footnote for paired audio rows.
    /// Returns nil for unpaired devices so the row collapses to a
    /// single-line layout.
    private func audioRowFootnote(forUID uid: String) -> String? {
        guard let displayID = audioToDisplayPairing[uid],
              let screen = displays.first(where: { $0.displayID == Int(displayID) }) else { return nil }
        return String(format: NSLocalizedString("audio_paired_with_display",
                                                 comment: "Audio device paired with display footnote"),
                      screen.localizedName)
    }
}
