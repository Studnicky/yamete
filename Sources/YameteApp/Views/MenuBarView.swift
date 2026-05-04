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
    @Environment(SettingsStore.self) var settings
    @State private var rotator = MenuHeaderRotator()

    /// Cross-fade duration for the subtext rotation. ~3.5s ease-in-out
    /// reads as a slow pulse rather than a flicker — deliberate enough
    /// that the user notices the transition without it feeling busy.
    private static let crossfadeDuration: Double = 3.5

    public var body: some View {
        // Application icon — the same image macOS shows in the Dock /
        // Finder / status-item launch icon. NEVER substituted with a
        // reaction face; the menu header stays calm even while an impact
        // is in flight (the menu-bar status-item icon is the surface
        // that reflects live reactions).
        let icon = NSApp.applicationIconImage
        let body = rotator.current

        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Static title — never rotates.
                Text(NSLocalizedString("app_title", comment: "Application name"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.pink)

                // Rotating subtext — notification body strings drawn from
                // the user's enabled stimulus kinds. `.id(body)` triggers
                // SwiftUI to dispose the old text and animate the new one
                // in; the slow ease-in-out cross-fade reads as a pulse.
                Text(body)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(body)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: Self.crossfadeDuration), value: body)
            }

            Spacer(minLength: 0)

            if !yamete.fusion.isRunning {
                Text(NSLocalizedString("status_paused", comment: "Detection paused indicator"))
                    .font(.caption)
                    .foregroundStyle(Theme.mauve)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.mauve.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .onAppear {
            rebuildPages()
            rotator.start()
        }
        .onDisappear { rotator.stop() }
        // Only the locale change should rebuild the pool — the moan
        // strings are independent of which stimuli/sensors the user
        // has enabled, so toggling those does not affect the rotation.
        .onChange(of: settings.resolvedNotificationLocale) { _, _ in rebuildPages() }
    }

    /// Recompute the rotator's body pool from the user's currently-enabled
    /// reaction kinds and selected locale. Called on launch and whenever
    /// either input changes.
    private func rebuildPages() {
        let appTagline = NSLocalizedString("app_tagline", comment: "Application tagline")
        // Pool: tagline + every impact-tier moan in the user's locale.
        // Event-body strings are not included — the rotator surfaces
        // spicy reaction copy only.
        let pages = MenuHeaderRotator.buildBodies(
            appTagline: appTagline,
            locale: settings.resolvedNotificationLocale
        )
        rotator.setPages(pages)
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
