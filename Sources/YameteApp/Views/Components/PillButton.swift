import SwiftUI
import AppKit

// MARK: - PillButton
//
// Tappable pink pill — `themePillButton` modifier wrapped as a first-class
// `Button` view. Replaces the repeated `Button { ... } label: { Text(...)
// .themePillButton(...) }.buttonStyle(.plain)` blocks in FooterSection.

internal struct PillButton: View {
    let title: String
    let action: () -> Void

    var background: Color = Theme.deepRose.opacity(0.15)
    var foreground: Color = Theme.pink
    var bold: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .themePillButton(background: background,
                                 foreground: foreground,
                                 bold: bold)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LinkPillButton
//
// PillButton that opens a URL in the user's default browser via NSWorkspace.
// Used by the Privacy / Support footer links.

internal struct LinkPillButton: View {
    let title: String
    let url: URL

    var body: some View {
        PillButton(title: title) {
            NSWorkspace.shared.open(url)
        }
    }
}
