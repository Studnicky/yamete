#if canImport(YameteCore)
import YameteCore
#endif
import SwiftUI

// MARK: - Sensors & Detection (collapsible)

internal struct SensorSection: View {
    @Environment(SettingsStore.self) var settings
    @Environment(ImpactController.self) var controller
    let availableSensors: [String]
    @State private var isExpanded = false

    public var body: some View {
        @Bindable var s = settings

        AccordionCard(title: NSLocalizedString("section_sensitivity_sensors", comment: "Sensitivity & Sensors accordion title"), isExpanded: $isExpanded) {
            let lw = tuningLabelWidth

            sensorList()

            let enabledCount = availableSensors.filter { s.enabledSensorIDs.contains($0) }.count

            VStack(spacing: 10) {
                if enabledCount >= 2 {
                    Divider()
                    SettingRow(icon: "person.3",
                               title: NSLocalizedString("setting_consensus", comment: "Sensor consensus setting title"),
                               help: NSLocalizedString("help_consensus", comment: "Sensor consensus setting help text")) {
                        SingleSliderInt(value: $s.consensusRequired, bounds: 1...enabledCount,
                                        labelWidth: lw, format: Fmt.consensus)
                    }
                }

                Divider()

                SettingRow(icon: "timer",
                           title: NSLocalizedString("setting_cooldown", comment: "Cooldown setting title"),
                           help: NSLocalizedString("help_cooldown", comment: "Cooldown setting help text")) {
                    SingleSlider(value: $s.debounce, bounds: Detection.debounceRange,
                                 labelWidth: lw, format: Fmt.seconds)
                }
            }
            .padding(Theme.accordionInner)
        }
        .onAppear { clampConsensus() }
        .onChange(of: settings.enabledSensorIDs) { _, _ in clampConsensus() }
    }

    @ViewBuilder
    private func sensorList() -> some View {
        let adapters = controller.allAdapters
            .filter { availableSensors.contains($0.id.rawValue) }
            .sorted { $0.name < $1.name }
        VStack(spacing: 0) {
            ForEach(Array(adapters.enumerated()), id: \.offset) { i, adapter in
                Toggle(isOn: sensorBinding(id: adapter.id.rawValue)) {
                    Text(adapter.name).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).tint(Theme.pink).controlSize(.mini)
                .padding(Theme.toggleRowPadding)
                if i < adapters.count - 1 { Divider().padding(.leading, Theme.listDividerInset) }
            }
        }
        .padding(.vertical, 4)
    }

    private func clampConsensus() {
        let enabledCount = availableSensors.filter { settings.enabledSensorIDs.contains($0) }.count
        if enabledCount >= 1 && settings.consensusRequired > enabledCount {
            settings.consensusRequired = enabledCount
        }
    }

    private func sensorBinding(id: String) -> Binding<Bool> {
        @Bindable var s = settings
        return arrayToggleBinding($s.enabledSensorIDs, element: id)
    }

}
