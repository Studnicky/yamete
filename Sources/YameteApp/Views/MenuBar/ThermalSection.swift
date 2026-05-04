#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - Thermal section (single-toggle, no tunables)
//
// `ThermalSource` publishes discrete `ProcessInfo.thermalState`
// transitions — `.nominal` / `.fair` / `.serious` / `.critical`.
// All thresholds and the transition cadence are OS-defined; the
// user has nothing to tune. The section therefore reduces to a
// single AccordionCard with a header toggle and an empty body
// row reserved for the per-output × per-kind matrix wired by
// `StimuliSection`.

internal struct ThermalSection: View {
    @Environment(SettingsStore.self) var settings
    @State private var isExpanded = false

    public var body: some View {
        AccordionCard(
            title: NSLocalizedString("section_thermal", comment: "Thermal section header"),
            isExpanded: $isExpanded
        ) {
            ThermalSectionContent()
        }
    }
}

// MARK: - Content (used when nesting inside another card)

internal struct ThermalSectionContent: View {
    @Environment(SettingsStore.self) var settings

    public var body: some View {
        VStack(spacing: 6) {
            Text(NSLocalizedString("help_source_thermal", comment: "Thermal source help"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.accordionInner)
    }
}
