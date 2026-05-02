import SwiftUI

// MARK: - EnableToggleRow
//
// Icon + title + flexible spacer + themed mini-switch. The single most common
// repeated pattern across MenuBar sections — appears in the trackpad accordion
// (sliding/contact/tapping/circle), in ResponseSection (volume override, LED),
// in DeviceSection (active-display toggle), and in FooterSection (launch at
// login, debug logging).
//
// The label dims when the row is disabled — the `dimmed` flag lets the parent
// override the auto-derived state (e.g. when an outer accordion controls it).

internal struct EnableToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    /// Tooltip exposed via `.help(...)`. Empty string suppresses the tooltip.
    var help: String = ""

    /// When non-nil, drives the dimmed state independently of `isOn`. Use this
    /// for rows where the toggle's binding is the same value driving dimming
    /// (passing `!isOn` would feel redundant) — leave `nil` to follow `isOn`.
    var dimmed: Bool? = nil

    /// When non-nil, overrides the icon color. Lets the parent show the icon
    /// in `Theme.pink` when active and a muted color when inactive.
    var iconColor: Color? = nil

    var body: some View {
        let isDimmed = dimmed ?? !isOn

        HStack(spacing: 6) {
            IconLabel(icon: icon, title: title, dimmed: isDimmed,
                      iconColor: iconColor)
            Spacer()
            Toggle("", isOn: $isOn).themeMiniSwitch()
        }
        .help(help)
    }
}
