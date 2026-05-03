#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
#if !RAW_SWIFTC_LUMP
import SensorKit
#endif
import SwiftUI

// MARK: - Stimuli section (cable / power / device / trackpad reactions)

internal struct StimuliSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(Yamete.self) var yamete

    // Per-source expanded state
    @State private var expandedSources: Set<String> = []

    private struct StimulusRow {
        let sourceID: String
        let title: String
        let icon: String
        let help: String
        let kinds: [ReactionKind]
    }

    private static let rows: [StimulusRow] = [
        .init(sourceID: SensorID.usb.rawValue,
              title: NSLocalizedString("event_usb", comment: "USB events"),
              icon: "cable.connector",
              help: NSLocalizedString("help_source_usb", comment: "USB source help"),
              kinds: [.usbAttached, .usbDetached]),
        .init(sourceID: SensorID.power.rawValue,
              title: NSLocalizedString("event_power", comment: "AC power events"),
              icon: "powerplug.fill",
              help: NSLocalizedString("help_source_power", comment: "Power source help"),
              kinds: [.acConnected, .acDisconnected]),
        .init(sourceID: SensorID.audioPeripheral.rawValue,
              title: NSLocalizedString("event_audio_peripheral", comment: "Audio peripheral events"),
              icon: "headphones",
              help: NSLocalizedString("help_source_audio_peripheral", comment: "Audio peripheral source help"),
              kinds: [.audioPeripheralAttached, .audioPeripheralDetached]),
        .init(sourceID: SensorID.bluetooth.rawValue,
              title: NSLocalizedString("event_bluetooth", comment: "Bluetooth events"),
              icon: "bolt.horizontal.circle",
              help: NSLocalizedString("help_source_bluetooth", comment: "Bluetooth source help"),
              kinds: [.bluetoothConnected, .bluetoothDisconnected]),
        .init(sourceID: SensorID.thunderbolt.rawValue,
              title: NSLocalizedString("event_thunderbolt", comment: "Thunderbolt events"),
              icon: "bolt.fill",
              help: NSLocalizedString("help_source_thunderbolt", comment: "Thunderbolt source help"),
              kinds: [.thunderboltAttached, .thunderboltDetached]),
        .init(sourceID: SensorID.displayHotplug.rawValue,
              title: NSLocalizedString("event_display", comment: "Display hot-plug events"),
              icon: "display",
              help: NSLocalizedString("help_source_display", comment: "Display source help"),
              kinds: [.displayConfigured]),
        .init(sourceID: SensorID.sleepWake.rawValue,
              title: NSLocalizedString("event_sleep_wake", comment: "Sleep / wake events"),
              icon: "moon.zzz",
              help: NSLocalizedString("help_source_sleep_wake", comment: "Sleep/wake source help"),
              kinds: [.willSleep, .didWake]),
    ]

    private var activeRows: [StimulusRow] {
        var result = Self.rows
        if yamete.trackpadSourcePresent {
            result.append(.init(
                sourceID: SensorID.trackpadActivity.rawValue,
                title: NSLocalizedString("event_trackpad", comment: "Trackpad activity events"),
                icon: "hand.point.up.left",
                help: NSLocalizedString("help_source_trackpad", comment: "Trackpad source help"),
                kinds: [.trackpadTouching, .trackpadSliding, .trackpadContact, .trackpadTapping, .trackpadCircling]
            ))
        }
        if yamete.mouseSourcePresent {
            result.append(.init(
                sourceID: SensorID.mouseActivity.rawValue,
                title: NSLocalizedString("event_mouse", comment: "Mouse events"),
                icon: "computermouse",
                help: NSLocalizedString("help_source_mouse", comment: "Mouse source help"),
                kinds: [.mouseClicked, .mouseScrolled]
            ))
        }
        if yamete.keyboardSourcePresent {
            result.append(.init(
                sourceID: SensorID.keyboardActivity.rawValue,
                title: NSLocalizedString("event_keyboard", comment: "Keyboard events"),
                icon: "keyboard",
                help: NSLocalizedString("help_source_keyboard", comment: "Keyboard source help"),
                kinds: [.keyboardTyped]
            ))
        }
        if AppleSPUDevice.isHardwarePresent() {
            result.append(.init(
                sourceID: SensorID.gyroscope.rawValue,
                title: NSLocalizedString("event_gyroscope", comment: "Gyroscope events"),
                icon: "gyroscope",
                help: NSLocalizedString("help_source_gyroscope", comment: "Gyroscope source help"),
                kinds: [.gyroSpike]
            ))
            result.append(.init(
                sourceID: SensorID.lidAngle.rawValue,
                title: NSLocalizedString("event_lid_angle", comment: "Lid angle events"),
                icon: "laptopcomputer",
                help: NSLocalizedString("help_source_lid_angle", comment: "Lid angle source help"),
                kinds: [.lidOpened, .lidClosed, .lidSlammed]
            ))
            result.append(.init(
                sourceID: SensorID.ambientLight.rawValue,
                title: NSLocalizedString("event_ambient_light", comment: "Ambient light events"),
                icon: "sun.max.circle",
                help: NSLocalizedString("help_source_ambient_light", comment: "Ambient light source help"),
                kinds: [.alsCovered, .lightsOff, .lightsOn]
            ))
        }
        return result
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(activeRows, id: \.sourceID) { row in
                let isExpanded = Binding(
                    get: { expandedSources.contains(row.sourceID) },
                    set: { expanded in
                        if expanded { expandedSources.insert(row.sourceID) }
                        else { expandedSources.remove(row.sourceID) }
                    }
                )
                SensorAccordionCard(
                    title: row.title,
                    icon: row.icon,
                    isEnabled: sourceBinding(id: row.sourceID),
                    isExpanded: isExpanded,
                    help: row.help
                ) {
                    sourceContent(row: row)
                }
            }
        }
    }

    // MARK: - Source accordion content

    @ViewBuilder
    private func sourceContent(row: StimulusRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(row.kinds, id: \.rawValue) { kind in
                outputMatrixRow(kind: kind)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }

    // MARK: - Output matrix row

    /// A button spec: all parameters needed to render one MatrixToggle.
    private struct OutputButtonSpec {
        let id: String
        let icon: String
        let label: String
        let binding: Binding<Bool>
        let outputEnabled: Bool
    }

    /// Pure helper exposed for tests: count of buttons rendered for the given
    /// hardware-availability matrix. Mirrors the conditional appends inside
    /// `outputButtonSpecs(kind:)` exactly. The 4 always-on outputs (sound,
    /// flash, notification, LED) are followed by haptic / brightness / tint
    /// only when the corresponding flag is true. Volume override is a sub-
    /// mode of Sound and never adds a button.
    static func outputButtonCount(
        hapticAvailable: Bool,
        displayBrightnessAvailable: Bool,
        displayTintAvailable: Bool
    ) -> Int {
        4
        + (hapticAvailable ? 1 : 0)
        + (displayBrightnessAvailable ? 1 : 0)
        + (displayTintAvailable ? 1 : 0)
    }

    /// Builds the ordered list of output buttons available on this system.
    /// Always-available outputs come first; hardware-gated outputs appended
    /// only when the hardware is present. Result count drives the fluid grid split.
    private func outputButtonSpecs(kind: ReactionKind) -> [OutputButtonSpec] {
        var s: [OutputButtonSpec] = [
            .init(id: "sound", icon: "speaker.wave.2",
                  label: NSLocalizedString("legend_sound", comment: "Sound output short label"),
                  binding: matrixBinding(\.soundReactionMatrix, kind: kind),
                  outputEnabled: settings.soundEnabled),
            .init(id: "flash", icon: "sun.max",
                  label: NSLocalizedString("legend_flash", comment: "Flash output short label"),
                  binding: matrixBinding(\.flashReactionMatrix, kind: kind),
                  outputEnabled: settings.flashEnabled),
            .init(id: "notif", icon: "bell.badge",
                  label: NSLocalizedString("legend_notif", comment: "Notification output short label"),
                  binding: matrixBinding(\.notificationReactionMatrix, kind: kind),
                  outputEnabled: settings.notificationsEnabled),
            .init(id: "led", icon: "keyboard.badge.eye",
                  label: NSLocalizedString("legend_led", comment: "LED output short label"),
                  binding: matrixBinding(\.ledReactionMatrix, kind: kind),
                  outputEnabled: settings.keyboardBrightnessEnabled),
        ]
        if yamete.hapticAvailable {
            s.append(.init(id: "haptic", icon: "waveform",
                label: NSLocalizedString("legend_haptic", comment: "Haptic output short label"),
                binding: matrixBinding(\.hapticReactionMatrix, kind: kind),
                outputEnabled: settings.hapticEnabled))
        }
        if yamete.displayBrightnessAvailable {
            s.append(.init(id: "bright", icon: "sun.max.fill",
                label: NSLocalizedString("legend_bright", comment: "Brightness output short label"),
                binding: matrixBinding(\.displayBrightnessReactionMatrix, kind: kind),
                outputEnabled: settings.displayBrightnessEnabled))
        }
        if yamete.displayTintAvailable {
            s.append(.init(id: "tint", icon: "paintbrush.pointed",
                label: NSLocalizedString("legend_tint", comment: "Tint output short label"),
                binding: matrixBinding(\.displayTintReactionMatrix, kind: kind),
                outputEnabled: settings.displayTintEnabled))
        }
        // Volume override is a sub-mode of Sound (not a separate button) — it fires
        // alongside audio playback when both sound is routed and volume override is on.
        return s
    }

    @ViewBuilder
    private func outputMatrixRow(kind: ReactionKind) -> some View {
        let specs = outputButtonSpecs(kind: kind)
        VStack(alignment: .leading, spacing: 4) {
            Text(label(for: kind))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(specs, id: \.id) { spec in
                    matrixToggle(icon: spec.icon, label: spec.label,
                                 binding: spec.binding, outputEnabled: spec.outputEnabled)
                }
            }
            kindTuning(kind: kind)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Per-kind tuning sliders

    /// Pure helper exposed for tests. For a kind, returns the (low, high)
    /// keyPath pair on `SettingsStore` that drives the slider. Returns nil
    /// for kinds without a range-slider tuning. Single-value sliders (e.g.
    /// `.mouseScrolled`) are exposed separately via `kindSingleTuningKeyPath`.
    /// This is the single source of truth shared by `kindTuning(kind:)`
    /// rendering and binding-integrity tests.
    @MainActor
    internal static func kindTuningBindings(
        _ kind: ReactionKind
    ) -> (low: ReferenceWritableKeyPath<SettingsStore, Double>,
          high: ReferenceWritableKeyPath<SettingsStore, Double>)? {
        switch kind {
        case .trackpadTouching: return (\SettingsStore.trackpadTouchingMin, \SettingsStore.trackpadTouchingMax)
        case .trackpadSliding:  return (\SettingsStore.trackpadSlidingMin,  \SettingsStore.trackpadSlidingMax)
        case .trackpadContact:  return (\SettingsStore.trackpadContactMin,  \SettingsStore.trackpadContactMax)
        case .trackpadTapping:  return (\SettingsStore.trackpadTapMin,      \SettingsStore.trackpadTapMax)
        default: return nil
        }
    }

    /// Kinds whose tuning is a single-value slider (no high counterpart).
    @MainActor
    internal static func kindSingleTuningKeyPath(
        _ kind: ReactionKind
    ) -> ReferenceWritableKeyPath<SettingsStore, Double>? {
        switch kind {
        case .mouseScrolled: return \SettingsStore.mouseScrollThreshold
        default:             return nil
        }
    }

    @ViewBuilder
    private func kindTuning(kind: ReactionKind) -> some View {
        @Bindable var s = settings
        let lw: CGFloat = 40

        switch kind {
        case .trackpadTouching:
            RangeSlider(low: $s.trackpadTouchingMin, high: $s.trackpadTouchingMax,
                        bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
                .padding(.top, 2)
        case .trackpadSliding:
            RangeSlider(low: $s.trackpadSlidingMin, high: $s.trackpadSlidingMax,
                        bounds: 0.0...1.0, labelWidth: lw, format: Fmt.percent)
                .padding(.top, 2)

        case .trackpadContact:
            // Duration range: fires while held after min, won't re-fire until > max reset
            RangeSlider(low: $s.trackpadContactMin, high: $s.trackpadContactMax,
                        bounds: 0.1...5.0, labelWidth: lw, format: Fmt.seconds)
                .padding(.top, 2)

        case .trackpadTapping:
            // Tap rate range (taps per 2 s window)
            let tapsPerSec: @Sendable (Double) -> String = {
                String(format: NSLocalizedString("unit_taps_per_sec", comment: "Tap rate format"), $0)
            }
            RangeSlider(low: $s.trackpadTapMin, high: $s.trackpadTapMax,
                        bounds: 0.5...10.0, labelWidth: lw, format: tapsPerSec)
                .padding(.top, 2)

        case .mouseScrolled:
            SingleSlider(value: $s.mouseScrollThreshold, bounds: 1.0...15.0,
                         labelWidth: lw, format: Fmt.multiplier)
                .padding(.top, 2)

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func matrixToggle(icon: String, label: String, binding: Binding<Bool>, outputEnabled: Bool = true) -> some View {
        Toggle(isOn: binding) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: 9, weight: .medium))
            }
        }
        .toggleStyle(MatrixToggleStyle(outputEnabled: outputEnabled))
    }

    // MARK: - Bindings

    private func sourceBinding(id: String) -> Binding<Bool> {
        let store = settings
        return Binding(
            get: { store.enabledStimulusSourceIDs.contains(id) },
            set: { enabled in
                var ids = store.enabledStimulusSourceIDs
                if enabled { if !ids.contains(id) { ids.append(id) } }
                else { ids.removeAll { $0 == id } }
                store.enabledStimulusSourceIDs = ids
            }
        )
    }

    private func matrixBinding(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, ReactionToggleMatrix>,
        kind: ReactionKind
    ) -> Binding<Bool> {
        let store = settings
        return Binding(
            get: { store[keyPath: keyPath].enabled(kind) },
            set: { enabled in
                var matrix = store[keyPath: keyPath]
                matrix.set(kind, enabled)
                store[keyPath: keyPath] = matrix
            }
        )
    }

    // MARK: - Kind labels

    private func label(for kind: ReactionKind) -> String {
        Self.label(for: kind)
    }

    /// Internal seam for tests: the localized label string for every
    /// `ReactionKind` rendered as the per-kind matrix-row title. Mirrors the
    /// instance variant exactly.
    @MainActor
    internal static func label(for kind: ReactionKind) -> String {
        switch kind {
        case .usbAttached:              NSLocalizedString("kind_usb_attached", comment: "USB attached label")
        case .usbDetached:              NSLocalizedString("kind_usb_detached", comment: "USB detached label")
        case .acConnected:              NSLocalizedString("kind_ac_connected", comment: "AC connected label")
        case .acDisconnected:           NSLocalizedString("kind_ac_disconnected", comment: "AC disconnected label")
        case .audioPeripheralAttached:  NSLocalizedString("kind_audio_attached", comment: "Audio attached label")
        case .audioPeripheralDetached:  NSLocalizedString("kind_audio_detached", comment: "Audio detached label")
        case .bluetoothConnected:       NSLocalizedString("kind_bt_connected", comment: "Bluetooth connected label")
        case .bluetoothDisconnected:    NSLocalizedString("kind_bt_disconnected", comment: "Bluetooth disconnected label")
        case .thunderboltAttached:      NSLocalizedString("kind_tb_attached", comment: "Thunderbolt attached label")
        case .thunderboltDetached:      NSLocalizedString("kind_tb_detached", comment: "Thunderbolt detached label")
        case .displayConfigured:        NSLocalizedString("kind_display_configured", comment: "Display configured label")
        case .willSleep:                NSLocalizedString("kind_will_sleep", comment: "Will sleep label")
        case .didWake:                  NSLocalizedString("kind_did_wake", comment: "Did wake label")
        case .trackpadTouching:         NSLocalizedString("kind_trackpad_touching", comment: "Trackpad touching label")
        case .trackpadSliding:          NSLocalizedString("kind_trackpad_sliding", comment: "Trackpad sliding label")
        case .trackpadContact:          NSLocalizedString("kind_trackpad_contact", comment: "Trackpad contact label")
        case .trackpadTapping:          NSLocalizedString("kind_trackpad_tapping", comment: "Trackpad tapping label")
        case .trackpadCircling:         NSLocalizedString("kind_trackpad_circling", comment: "Trackpad circling label")
        case .mouseClicked:             NSLocalizedString("kind_mouse_clicked",  comment: "Mouse clicked label")
        case .mouseScrolled:            NSLocalizedString("kind_mouse_scrolled", comment: "Mouse scrolled label")
        case .keyboardTyped:            NSLocalizedString("kind_keyboard_typed", comment: "Keyboard typed label")
        case .gyroSpike:                NSLocalizedString("kind_gyro_spike",     comment: "Gyroscope spike label")
        case .lidOpened:                NSLocalizedString("kind_lid_opened",     comment: "Lid opened label")
        case .lidClosed:                NSLocalizedString("kind_lid_closed",     comment: "Lid closed label")
        case .lidSlammed:               NSLocalizedString("kind_lid_slammed",    comment: "Lid slammed label")
        case .alsCovered:               NSLocalizedString("kind_als_covered",    comment: "Ambient light covered label")
        case .lightsOff:                NSLocalizedString("kind_lights_off",     comment: "Lights off label")
        case .lightsOn:                 NSLocalizedString("kind_lights_on",      comment: "Lights on label")
        case .impact:                   ""
        }
    }
}
