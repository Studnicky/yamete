import SwiftUI

// MARK: - IconLabel
//
// Small SF Symbol + caption-styled label, used as the leading element of most
// rows in the menu bar UI (settings rows, footer rows, sub-toggles).
// Centralises the size / color / icon-frame conventions so individual sections
// stop hand-rolling `Image(systemName:).font(.caption).foregroundStyle(...)`.

internal struct IconLabel: View {
    let icon: String
    let title: String

    /// When true, render in dimmed (.secondary on title) state. Used when the
    /// row's parent toggle is off so the label fades alongside.
    var dimmed: Bool = false

    /// SF Symbol font size. 10 is the menu-bar default. Footer uses 10 as well.
    var iconSize: CGFloat = 10

    /// Frame width applied to the icon so multiple rows align their text edges.
    /// Pass `nil` to skip the fixed frame (lets icons size naturally).
    var iconWidth: CGFloat? = nil

    /// Optional override for the icon color. Defaults to `.secondary`. Pass a
    /// theme color (e.g. `Theme.pink`) to highlight an active icon.
    var iconColor: Color? = nil

    var body: some View {
        let icView = Image(systemName: icon)
            .font(.system(size: iconSize))
            .foregroundStyle(iconColor ?? Color.secondary)
        let titleView = Text(title)
            .font(.caption)
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)

        HStack(spacing: 5) {
            if let w = iconWidth {
                icView.frame(width: w)
            } else {
                icView
            }
            titleView
        }
    }
}
