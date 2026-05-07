#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI
import AppKit

// MARK: - DiagnosticsRow

/// Renders the live `yamete.diagnostics` list directly below the menu's
/// top header. Hidden (zero footprint) when there are no active
/// diagnostics; otherwise stacks one pill per diagnostic and renders a
/// trailing divider so the section reads as a distinct band.
///
/// Sort order: errors first, then warnings, then info — within a
/// severity, the order Yamete inserted them. The view itself does no
/// sorting; it trusts `Yamete.diagnostics` to deliver pre-sorted items.
internal struct DiagnosticsRow: View {
    @Environment(Yamete.self) var yamete

    var body: some View {
        let items = yamete.diagnostics
        if !items.isEmpty {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        DiagnosticPill(diagnostic: item)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
            }
        }
    }
}

// MARK: - DiagnosticPill

/// Single-line pill rendering one `Diagnostic`. Severity drives icon +
/// colour; the optional CTA renders as a trailing button.
private struct DiagnosticPill: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .imageScale(.medium)
                .frame(width: 16)
            Text(diagnostic.title)
                .font(.caption)
                .foregroundStyle(Theme.stateInert)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let cta = diagnostic.cta {
                Button(cta.label) {
                    NSWorkspace.shared.open(cta.url)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Theme.stateActive)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch diagnostic.severity {
        case .info:    return "pause.circle"
        case .warning: return "exclamationmark.triangle"
        case .error:   return "exclamationmark.octagon"
        }
    }

    private var tint: Color {
        switch diagnostic.severity {
        case .info:    return Theme.stateWarning   // Same warm tone as the old paused pill — it still reads as "neutral but not active"
        case .warning: return Theme.stateWarning
        case .error:   return .red
        }
    }
}
