#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import SwiftUI
import AppKit

// MARK: - MenuBarView (composition root)

public struct MenuBarView: View {
    @Environment(ImpactController.self) var controller
    @Environment(SettingsStore.self) var settings
    @Environment(Updater.self) var updater
    @State private var audioDevices: [AudioOutputDevice] = []
    @State private var displays: [NSScreen] = NSScreen.screens
    @State private var availableSensors: [String] = []

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HeaderSection()
            Divider()
            ResponseSection()
            Divider()
            SensorSection(availableSensors: availableSensors)
            if settings.enabledSensorIDs.contains(SensorID.accelerometer.rawValue) {
                Divider()
                AccelTuningSection()
            }
            if settings.enabledSensorIDs.contains(SensorID.microphone.rawValue) {
                Divider()
                MicTuningSection()
            }
            if settings.enabledSensorIDs.contains(SensorID.headphoneMotion.rawValue) {
                Divider()
                HeadphoneTuningSection()
            }
            Divider()
            DeviceSection(audioDevices: audioDevices, displays: displays)

            if let error = controller.sensorError {
                Divider()
                Text(error)
                    .font(.caption).foregroundStyle(Theme.mauve)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.sectionPadding)
            }

            Divider()
            FooterSection()
        }
        .frame(width: Theme.menuWidth)
        .onAppear {
            AudioDeviceManager.startObserving()
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
        let latest = controller.allAdapters
            .filter { $0.isAvailable }
            .map(\.id.rawValue)
        if latest != availableSensors {
            availableSensors = latest
        }
    }
}

// MARK: - Shared formatters

/// Closure-typed value formatters used by the slider labels. Marked
/// `@Sendable` so they satisfy `-strict-concurrency=complete`. The closures
/// only call `NSLocalizedString` and `String(format:)`, both of which are
/// thread-safe.
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
    static let consensus: @Sendable (Int) -> String = { String(format: NSLocalizedString("consensus_format", comment: "Sensor consensus count"), $0) }
}

// MARK: - Generic toggle binding for array-backed selections

/// Bridges a `Binding<[T]>` and an element value into a `Binding<Bool>` for
/// switch-row use. `@MainActor` because all call sites are inside SwiftUI
/// view bodies and the `Binding` get/set closures fire on the main actor.
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

// MARK: - Header (impact counter)

internal struct HeaderSection: View {
    @Environment(ImpactController.self) var controller

    public var body: some View {
        HStack {
            Text(String(format: NSLocalizedString("impacts_today", comment: "Daily impact counter"), controller.impactCount))
            Spacer()
            if let tier = controller.lastImpactTier {
                Text(verbatim: String(format: NSLocalizedString("last_impact", comment: "Last impact tier label"), String(describing: tier)))
                    .foregroundStyle(.tertiary)
            }
            if !controller.isEnabled {
                Text(NSLocalizedString("status_paused", comment: "Detection paused indicator")).foregroundStyle(Theme.mauve)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

// MARK: - Shared detection gate parameters (crest factor, confirmations, warmup)

// Shared setting row builders for parameters common to all sensors.
// `@MainActor` because the wrapped SettingRow / SingleSlider initializers
// are SwiftUI views constructed inside a view body — always main-actor.
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
