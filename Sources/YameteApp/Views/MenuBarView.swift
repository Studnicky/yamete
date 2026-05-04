#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import SwiftUI
import AppKit

// MARK: - MenuBarView (two-column composition root)

public struct MenuBarView: View {
    @Environment(Yamete.self) var yamete
    @Environment(MenuBarFace.self) var menuBarFace
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var audioDevices: [AudioOutputDevice] = []
    @State private var displays: [NSScreen] = NSScreen.screens
    @State private var availableSensors: [String] = []

    public init() {}

    // Conservative screen-height cap for the scrollable content area.
    // Uses the smallest connected screen so the panel never overflows a laptop display.
    private var maxScrollHeight: CGFloat {
        let minH = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800
        return max(300, minH - 233)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderSection()
            Divider()

            // fixedSize makes the ScrollView report its content's ideal height (not the
            // panel frame height) so NSHostingView.fittingSize is correct.
            // frame(maxHeight:) caps it — scroll activates when content exceeds the screen.
            // GeometryReader on the HStack (not outer VStack) reads content height directly;
            // preferences bubble up so onPreferenceChange below triggers panel resize.
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    leftColumn
                        .frame(width: Theme.columnWidth, alignment: .top)
                    rightColumn
                        .frame(width: Theme.columnWidth, alignment: .top)
                        .overlay(
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 1),
                            alignment: .leading
                        )
                }
            }
            .frame(maxHeight: maxScrollHeight)

            Divider()
            ImpactCounterStrip()
            Divider()
            FooterSection()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Theme.twoColumnMenuWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: MenuContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            // Send the natural total height (fixedSize VStack reports ideal, not panel height)
            NotificationCenter.default.post(name: .menuBarContentSizeChanged,
                                            object: NSNumber(value: Double(height)))
        }
        .onPreferenceChange(AccordionAnimationDurationKey.self) { duration in
            // Forward the largest in-flight accordion duration to the panel
            // resize so the NSPanel animation matches the SwiftUI reveal.
            NotificationCenter.default.post(name: .menuBarAnimationDurationChanged,
                                            object: NSNumber(value: duration))
        }
        .onAppear {
            refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarPanelDidShow)) { _ in
            refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioDeviceManager.devicesDidChangeNotification)) { _ in
            refreshAudioDevices()
            refreshSensors()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshDisplays()
        }
    }

    // MARK: - Left column: Detection + Stimuli

    @ViewBuilder private var leftColumn: some View {
        VStack(spacing: 0) {
            SensitivitySection()
            Divider()
            SensorSection(availableSensors: availableSensors)
            Divider()
            StimuliSection()
        }
    }

    // MARK: - Right column: Responses + Devices

    @ViewBuilder private var rightColumn: some View {
        VStack(spacing: 0) {
            DeviceSection(audioDevices: audioDevices, displays: displays)
            Divider()
            ResponseSection()

            if let error = yamete.sensorError {
                Divider()
                Text(error)
                    .font(.caption).foregroundStyle(Theme.mauve)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.sectionPadding)
            }
        }
    }

    // MARK: - Private refresh helpers

    private func refreshAll() {
        refreshAudioDevices()
        refreshDisplays()
        refreshSensors()
    }

    private func refreshAudioDevices() {
        let latest = AudioDeviceManager.outputDevices()
        if latest.map(\.uid) != audioDevices.map(\.uid)
            || latest.map(\.displayName) != audioDevices.map(\.displayName) {
            audioDevices = latest
        }
    }

    private func refreshDisplays() {
        let latest = NSScreen.screens
        if latest.map(\.displayID) != displays.map(\.displayID) {
            displays = latest
        }
    }

    private func refreshSensors() {
        let latest = yamete.allSensorSources
            .filter { $0.isAvailable }
            .map(\.id.rawValue)
        if latest != availableSensors {
            availableSensors = latest
        }
    }
}

// MARK: - Panel size change preference key

private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Shared formatters (used by all tuning sections)

internal enum Fmt {
    static let percent: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_percent", comment: "Percentage format"), Int($0 * 100)) }
    static let gforce: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_gforce", comment: "G-force format"), $0) }
    static let multiplier: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_multiplier", comment: "Multiplier format"), $0) }
    static let seconds: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), $0) }
    static let hz: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_hz", comment: "Hertz format"), Int($0)) }
    static let ms: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_milliseconds", comment: "Milliseconds format"), $0 / 1000) }
    static let amplitude: @Sendable (Double) -> String = { String(format: "%.3f", $0) }
    static let warmup: @Sendable (Double) -> String = { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), $0 / 50.0) }
    static let warmupInt: @Sendable (Int) -> String = { String(format: NSLocalizedString("unit_seconds", comment: "Seconds format"), Double($0) / 50.0) }
    static let confirmations: @Sendable (Int) -> String = { String(format: NSLocalizedString("confirmations_format", comment: "Confirmation hit count"), $0) }
    static let consensus: @Sendable (Int) -> String = { String(format: NSLocalizedString("consensus_format", comment: "Impact sensor count format"), $0) }
}

// MARK: - Generic toggle binding for array-backed selections

@MainActor
internal func arrayToggleBinding<T: Equatable & Sendable>(
    _ array: Binding<[T]>, element: T
) -> Binding<Bool> {
    Binding(
        get: { array.wrappedValue.contains(element) },
        set: { enabled in
            var items = array.wrappedValue
            if enabled { if !items.contains(element) { items.append(element) } }
            else { items.removeAll { $0 == element } }
            array.wrappedValue = items
        }
    )
}

// MARK: - Shared label width for tuning sliders

internal let tuningLabelWidth: CGFloat = 50

// MARK: - Header (app identity + impact counter)

internal struct HeaderSection: View {
    @Environment(Yamete.self) var yamete
    @Environment(MenuBarFace.self) var menuBarFace
    @Environment(SettingsStore.self) var settings
    @State private var rotator = MenuHeaderRotator()

    /// Cross-fade duration between rotator pages. Tuned so the swap reads
    /// as a deliberate transition, not a flicker — matches the
    /// AccordionCard expand/collapse curve.
    private static let crossfadeDuration: Double = 0.45

    public var body: some View {
        let face = menuBarFace.reactionFace ?? FaceLibrary.shared.image(at: 0)
        let page = rotator.current

        VStack(spacing: 6) {
            // Centred app icon face. Falls back to FaceLibrary index 0 when
            // no impact is in flight; swaps to the live reaction face when
            // an impact lands (matching the menu-bar status item behaviour).
            if let face {
                Image(nsImage: face)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            }

            // Centred rotating title + body. Cross-fade triggered by the
            // page identity changing (`.id(page.id)` forces SwiftUI to
            // dispose the old subview and animate the replacement in).
            VStack(spacing: 2) {
                Text(page.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.pink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !page.body.isEmpty {
                    Text(page.body)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }
            .id(page.id)
            .transition(.opacity)
            .animation(.easeInOut(duration: Self.crossfadeDuration), value: page.id)

            // Paused indicator stays visible alongside the rotator so the
            // user always knows when detection is suspended.
            if !yamete.fusion.isRunning {
                Text(NSLocalizedString("status_paused", comment: "Detection paused indicator"))
                    .font(.caption)
                    .foregroundStyle(Theme.mauve)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.mauve.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .onAppear {
            rebuildPages()
            rotator.start()
        }
        .onDisappear { rotator.stop() }
        .onChange(of: settings.resolvedNotificationLocale) { _, _ in rebuildPages() }
        .onChange(of: settings.enabledStimulusSourceIDs) { _, _ in rebuildPages() }
        .onChange(of: settings.enabledSensorIDs) { _, _ in rebuildPages() }
    }

    /// Recompute the rotator pages from the user's currently-enabled
    /// reaction kinds and selected locale. Called on launch and whenever
    /// either input changes.
    private func rebuildPages() {
        let appTitle   = NSLocalizedString("app_title",   comment: "Application name")
        let appTagline = NSLocalizedString("app_tagline", comment: "Application tagline")
        let pages = MenuHeaderRotator.buildPages(
            appTitle: appTitle,
            appTagline: appTagline,
            enabledKinds: enabledReactionKinds(),
            locale: settings.resolvedNotificationLocale
        )
        rotator.setPages(pages)
    }

    /// All reaction kinds whose source is currently enabled. Mirrors the
    /// gating logic the bus uses when deciding whether to publish a kind:
    /// impact kinds gate on `enabledSensorIDs`; event/stimulus kinds gate
    /// on `enabledStimulusSourceIDs` membership.
    private func enabledReactionKinds() -> [ReactionKind] {
        var kinds: [ReactionKind] = []
        // Impact reactions always carry the same kind (.impact); skip and
        // let the rotator surface event phrasings only.
        let stimulusIDs = Set(settings.enabledStimulusSourceIDs)
        for kind in ReactionKind.allCases where kind != .impact {
            // Map kind → owning source ID via the ReactionKind doc-comment
            // convention (rawValue prefix). Cheaper than wiring a full
            // SourceContracts table at this UI layer; if a kind's source
            // can't be resolved, keep the kind so it still appears.
            if let sourceID = ownerStimulusSourceID(for: kind),
               !stimulusIDs.contains(sourceID) {
                continue
            }
            kinds.append(kind)
        }
        return kinds
    }

    /// Kinds map to one of a small set of stimulus source IDs by prefix.
    /// Returning `nil` means "no gating — always include this kind".
    private func ownerStimulusSourceID(for kind: ReactionKind) -> String? {
        let raw = kind.rawValue
        if raw.hasPrefix("usb")              { return SensorID.usb.rawValue }
        if raw.hasPrefix("ac")               { return SensorID.power.rawValue }
        if raw.hasPrefix("audioPeripheral")  { return SensorID.audioPeripheral.rawValue }
        if raw.hasPrefix("bluetooth")        { return SensorID.bluetooth.rawValue }
        if raw.hasPrefix("thunderbolt")      { return SensorID.thunderbolt.rawValue }
        if raw.hasPrefix("display")          { return SensorID.displayHotplug.rawValue }
        if raw == "willSleep" || raw == "didWake" { return SensorID.sleepWake.rawValue }
        if raw.hasPrefix("trackpad")         { return SensorID.trackpadActivity.rawValue }
        if raw.hasPrefix("mouse")            { return SensorID.mouseActivity.rawValue }
        if raw.hasPrefix("keyboard")         { return SensorID.keyboardActivity.rawValue }
        if raw.hasPrefix("gyro")             { return SensorID.gyroscope.rawValue }
        if raw.hasPrefix("lid")              { return SensorID.lidAngle.rawValue }
        if raw.hasPrefix("lights") || raw == "alsCovered" { return SensorID.ambientLight.rawValue }
        if raw.hasPrefix("thermal")          { return SensorID.thermal.rawValue }
        return nil
    }
}

// MARK: - Impact counter strip (between content and footer)

internal struct ImpactCounterStrip: View {
    @Environment(Yamete.self) var yamete
    @Environment(MenuBarFace.self) var menuBarFace

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 9))
                .foregroundStyle(Theme.pink.opacity(0.7))
            Text(String(format: NSLocalizedString("impacts_today", comment: "Daily impact counter"), menuBarFace.impactCount))
            Spacer()
            if let tier = menuBarFace.lastImpactTier {
                Text(verbatim: String(format: NSLocalizedString("last_impact", comment: "Last impact tier label"), String(describing: tier)))
                    .foregroundStyle(.tertiary)
            }
            if !yamete.fusion.isRunning {
                Text(NSLocalizedString("status_paused", comment: "Detection paused indicator"))
                    .foregroundStyle(Theme.mauve)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.mauve.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}

// MARK: - Shared detection gate parameter rows

@MainActor
internal enum GateRows {
    @ViewBuilder static func confirmations(_ binding: Binding<Int>, bounds: ClosedRange<Int>, lw: CGFloat) -> some View {
        SettingRow(icon: "checkmark.circle",
                   title: NSLocalizedString("setting_confirmations", comment: "Confirmations setting title"),
                   help: NSLocalizedString("help_confirmations", comment: "Confirmations setting help text")) {
            SingleSliderInt(value: binding, bounds: bounds, labelWidth: lw, format: Fmt.confirmations)
        }
    }

    @ViewBuilder static func crestFactor(_ binding: Binding<Double>, bounds: ClosedRange<Double>, lw: CGFloat) -> some View {
        SettingRow(icon: "chart.line.uptrend.xyaxis",
                   title: NSLocalizedString("setting_crest_factor", comment: "Crest factor setting title"),
                   help: NSLocalizedString("help_crest_factor", comment: "Crest factor setting help text")) {
            SingleSlider(value: binding, bounds: bounds, labelWidth: lw, format: Fmt.multiplier)
        }
    }

    @ViewBuilder static func warmup(_ binding: Binding<Int>, bounds: ClosedRange<Int>, lw: CGFloat) -> some View {
        SettingRow(icon: "flame",
                   title: NSLocalizedString("setting_warmup", comment: "Warmup setting title"),
                   help: NSLocalizedString("help_warmup", comment: "Warmup setting help text")) {
            SingleSliderInt(value: binding, bounds: bounds, labelWidth: lw, format: Fmt.warmupInt)
        }
    }
}
