#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Sensitivity (reactivity range)

internal struct SensitivitySection: View {
    @Environment(SettingsStore.self) var settings

    /// Pure helper exposed for tests. Returns the (low, high) keyPaths bound
    /// to the sensitivity range slider. Keeps rendering and tests in sync.
    @MainActor
    internal static let sensitivityKeyPaths:
        (low: ReferenceWritableKeyPath<SettingsStore, Double>,
         high: ReferenceWritableKeyPath<SettingsStore, Double>) =
        (\SettingsStore.sensitivityMin, \SettingsStore.sensitivityMax)

    public var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 6) {
            SettingHeader(icon: "gauge.with.needle",
                          title: NSLocalizedString("setting_reactivity", comment: "Reactivity setting title"),
                          help: NSLocalizedString("help_reactivity", comment: "Reactivity setting help text"))
            SensitivityRuler()
            RangeSlider(low: $s.sensitivityMin, high: $s.sensitivityMax,
                        bounds: Detection.unitRange, labelWidth: tuningLabelWidth, format: Fmt.percent)
        }
        .padding(Theme.sectionPadding)
    }
}
