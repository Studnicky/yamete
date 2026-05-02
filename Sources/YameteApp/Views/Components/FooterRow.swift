import SwiftUI

// MARK: - FooterRow
//
// Standard footer row: leading icon/spinner, caption-styled label, flexible
// spacer, then custom trailing content supplied by the caller (toggle, pill
// button, multiple pill buttons, etc.). Replaces the eight hand-rolled
// `HStack { Image.themeFooterIcon(); Text.font(.caption); Spacer(); ... }`
// constructions in FooterSection.
//
// The leading slot is a view builder so callers can supply a `ProgressView`
// (for the "Checking…" update state) or a custom-tinted icon when needed,
// while the common case uses the static convenience initialiser.

internal struct FooterRow<Leading: View, Label: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var label: () -> Label
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading()
            label()
            Spacer()
            trailing()
        }
        .padding(Theme.footerPadding)
    }
}

// MARK: - Convenience constructors for the common variants.

extension FooterRow where Leading == ThemedFooterIcon, Label == FooterCaption {
    /// SF Symbol leading icon + caption-styled label (secondary foreground).
    init(icon: String, label: String,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(
            leading: { ThemedFooterIcon(symbol: icon) },
            label:   { FooterCaption(text: label, style: .secondary) },
            trailing: trailing
        )
    }

    /// Variant with a tertiary-colored label (used for the version row).
    init(icon: String, label: String, tertiary: Bool,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(
            leading: { ThemedFooterIcon(symbol: icon) },
            label:   { FooterCaption(text: label,
                                     style: tertiary ? .tertiary : .secondary) },
            trailing: trailing
        )
    }
}

// MARK: - Helper subviews exposed for direct use when callers need the
// label styling without the row chrome (e.g. inside the update-status
// branches that compose their own leading icon).

internal struct ThemedFooterIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).themeFooterIcon()
    }
}

internal struct FooterCaption: View {
    enum Style { case secondary, tertiary, pink }
    let text: String
    var style: Style = .secondary

    var body: some View {
        let view = Text(text).font(.caption)
        switch style {
        case .secondary: view.foregroundStyle(.secondary)
        case .tertiary:  view.foregroundStyle(.tertiary)
        case .pink:      view.foregroundStyle(Theme.pink)
        }
    }
}
