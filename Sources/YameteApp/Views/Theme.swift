import SwiftUI

// MARK: - Accordion API
//
// `AccordionCard` and `SensorAccordionCard` accept an optional
// `contentRowCount: Int = 1` parameter. Pass the approximate number of
// content rows the accordion contains when expanded. The accordion derives
// an animation duration from this hint (0.10s floor, 0.30s ceiling, ~25ms
// per row) so large columns animate slower than small ones, keeping the
// panel resize and the SwiftUI reveal in lockstep. Existing call sites that
// omit the argument keep the minimum 0.125s duration — safe for tiny cards.
//
// The accordion publishes its current animation duration via
// `AccordionAnimationDurationKey` (a SwiftUI PreferenceKey, MAX-reduced).
// `MenuBarView` forwards that value into `StatusBarController` so the panel
// resize uses the same duration as the in-flight accordion reveal.

/// Preference key carrying the in-flight accordion animation duration up the
/// view hierarchy. Reduced by `max` so the largest visible accordion's
/// duration wins when several are present simultaneously.
struct AccordionAnimationDurationKey: PreferenceKey {
    static let defaultValue: Double = 0.15
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}

/// Shared app color palette and reusable style modifiers.
enum Theme {
    static let pink      = Color(red: 0.867, green: 0.357, blue: 0.522)  // #DD5B85
    static let deepRose  = Color(red: 0.643, green: 0.165, blue: 0.357)  // #A42A5B
    static let mauve     = Color(red: 0.784, green: 0.471, blue: 0.663)  // #C878A9
    static let lightPink = Color(red: 0.949, green: 0.588, blue: 0.659)  // #F296A8
    static let dark      = Color(red: 0.055, green: 0.055, blue: 0.055)  // #0E0E0E

    // MARK: - Layout constants

    /// Standard horizontal + vertical padding for section content
    static let sectionPadding = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    /// Compact padding for footer rows
    static let footerPadding = EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
    /// Inner padding for accordion content
    static let accordionInner = EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
    /// Padding for toggle rows in device/sensor lists
    static let toggleRowPadding = EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)

    // MARK: - Slider geometry (shared by RangeSlider and SingleSlider)

    static let sliderThumbWidth: CGFloat = 22
    static let sliderThumbHeight: CGFloat = 17
    static let sliderTrackHeight: CGFloat = 4

    // MARK: - Layout dimensions

    static let menuWidth: CGFloat = 290
    /// Width of each column in the two-column menu layout.
    static let columnWidth: CGFloat = 290
    /// Total width of the two-column menu (columnWidth × 2 + 1px divider).
    static let twoColumnMenuWidth: CGFloat = 581
    static let listCornerRadius: CGFloat = 6
    static let buttonCornerRadius: CGFloat = 5
    static let listBackground = Color.secondary.opacity(0.08)
    static let listDividerInset: CGFloat = 22
}

// MARK: - Reusable toggle style modifier

extension Toggle {
    /// Standard pink mini switch used throughout the app.
    /// `@MainActor` because `SwitchToggleStyle.switch` is main-actor isolated.
    @MainActor
    func themeMiniSwitch() -> some View {
        self.toggleStyle(.switch).tint(Theme.pink)
            .labelsHidden().controlSize(.mini)
    }
}

// MARK: - Reusable footer icon style

extension Image {
    /// Small pink icon used in footer rows.
    func themeFooterIcon() -> some View {
        self.font(.system(size: 10)).foregroundStyle(Theme.pink)
    }
}

// MARK: - Pill button modifier

extension View {
    /// Small pill-shaped button used in the footer.
    func themePillButton(background: Color = Theme.deepRose, foreground: Color = .white, bold: Bool = false) -> some View {
        self.font(bold ? .caption.bold() : .caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, bold ? 10 : 8).padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCornerRadius))
    }
}

extension Theme {
    /// Section header label style (no icon)
    static func sectionHeader(_ text: String, help: String = "") -> some View {
        Text(text)
            .font(.caption).foregroundStyle(Theme.pink).textCase(.uppercase)
            .help(help)
    }
}

/// Accordion card: collapsible section with a prominent header bar.
struct AccordionCard<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var contentRowCount: Int = 1
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    /// Per-instance animation duration scaled to content row count.
    /// Mirrors the static `animationDuration(forRows:)` formula so tests
    /// can assert the curve without instantiating a SwiftUI body.
    private var animationDuration: Double {
        Self.animationDuration(forRows: contentRowCount)
    }

    /// 0.10s for 1 row, scales linearly, capped at 0.30s.
    /// Empirically: ~25ms per row of content matches the panel resize budget
    /// without overshooting easeInOut's perceptual peak.
    static func animationDuration(forRows rows: Int) -> Double {
        let base = 0.10
        let perRow = 0.025
        let raw = base + Double(max(1, rows)) * perRow
        return min(0.30, max(0.10, raw))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar — toggle wraps animation at the call site (matches the
            // SettingHeader tooltip pattern: simple in-place opacity on the
            // conditional content, no .transition() override, no outer
            // .animation(value:) that would re-animate sibling identity changes).
            Button(action: {
                withAnimation(.easeInOut(duration: animationDuration)) { isExpanded.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.mauve)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.pink)
                    Spacer()
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10)).foregroundStyle(Theme.mauve.opacity(0.7))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.deepRose.opacity(0.12))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.top, 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.deepRose.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8).padding(.vertical, 4)
        // Publish the duration so the panel resize uses the same timing.
        // Always emitted (not gated on isExpanded) so the panel sees the
        // value during the reveal and during the subsequent collapse.
        .preference(key: AccordionAnimationDurationKey.self, value: animationDuration)
    }
}

// MARK: - Sensor / stimulus accordion with inline enable toggle

/// Accordion card where the header contains both an expand/collapse chevron
/// (left) and an independent enable/disable toggle (right). Used for both
/// sensor cards and stimulus source cards.
struct SensorAccordionCard<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isEnabled: Bool
    @Binding var isExpanded: Bool
    var help: String = ""
    var contentRowCount: Int = 1
    @ViewBuilder let content: () -> Content

    /// Per-instance animation duration scaled to content row count.
    /// Mirrors the static `animationDuration(forRows:)` formula so tests
    /// can assert the curve without instantiating a SwiftUI body.
    private var animationDuration: Double {
        Self.animationDuration(forRows: contentRowCount)
    }

    /// 0.10s for 1 row, scales linearly, capped at 0.30s.
    /// Mirror of `AccordionCard.animationDuration(forRows:)` — kept on the
    /// type so call sites and tests can derive the duration without
    /// instantiating a SwiftUI body.
    static func animationDuration(forRows rows: Int) -> Double {
        let base = 0.10
        let perRow = 0.025
        let raw = base + Double(max(1, rows)) * perRow
        return min(0.30, max(0.10, raw))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row — never animates, stays fixed at the top
            HStack(spacing: 6) {
                Button(action: {
                    withAnimation(.easeInOut(duration: animationDuration)) { isExpanded.toggle() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.mauve)
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(isEnabled ? Theme.pink : Theme.pink.opacity(0.35))
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isEnabled ? Theme.pink : Theme.pink.opacity(0.35))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help)

                Toggle("", isOn: $isEnabled)
                    .themeMiniSwitch()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.deepRose.opacity(isEnabled ? 0.14 : 0.07))

            // Drop-down body: matches the SettingHeader tooltip pattern — no
            // explicit .transition() (default opacity, in-place), no outer
            // .animation(value:) wrapping the whole card. The withAnimation at
            // the toggle call site is the only animation source, which keeps
            // sibling siblings from bouncing as their parent stack reflows.
            if isExpanded {
                VStack(spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.deepRose.opacity(isEnabled ? 0.35 : 0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Animate only the expand state — sibling reflows happen naturally below,
        // never above. No outer .animation() that captures unrelated state.
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isEnabled)
        .padding(.horizontal, 8).padding(.vertical, 4)
        // Publish the duration so the panel resize uses the same timing.
        // Always emitted (not gated on isExpanded) so the panel sees the
        // value during the reveal and during the subsequent collapse.
        .preference(key: AccordionAnimationDurationKey.self, value: animationDuration)
    }
}

// MARK: - Output matrix toggle style

/// Glossy pill button used for per-output × per-reaction toggles in the
/// stimulus section. Renders three distinct states based on routing and output:
/// - Routed ON + Output ON:  pink fill, bright pink label, pink border — fires
/// - Routed ON + Output OFF: transparent, dimmed pink label, pink outline — pending
/// - Routed OFF:             grey fill, grey label, grey border — won't fire
struct MatrixToggleStyle: ToggleStyle {
    /// When false, the button renders in "pending" state — routing is on but
    /// the output channel is disabled globally. The routing preference persists.
    var outputEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            configuration.label
                .frame(maxWidth: .infinity)
                .foregroundStyle(foreColor(configuration.isOn))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(bgColor(configuration.isOn), in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(strokeColor(configuration.isOn), lineWidth: strokeWidth(configuration.isOn))
                )
        }
        .buttonStyle(.plain)
    }

    private func foreColor(_ isOn: Bool) -> Color {
        if isOn && outputEnabled  { return Theme.pink }
        if isOn && !outputEnabled { return Theme.pink.opacity(0.45) }
        return Color.secondary.opacity(0.40)
    }

    private func bgColor(_ isOn: Bool) -> Color {
        if isOn && outputEnabled  { return Theme.pink.opacity(0.16) }
        if isOn && !outputEnabled { return Color.clear }
        return Color.secondary.opacity(0.08)
    }

    private func strokeColor(_ isOn: Bool) -> Color {
        if isOn && outputEnabled  { return Theme.pink.opacity(0.50) }
        if isOn && !outputEnabled { return Theme.pink.opacity(0.35) }
        return Color.secondary.opacity(0.14)
    }

    private func strokeWidth(_ isOn: Bool) -> CGFloat {
        // Dashed stroke isn't supported here, but thinner outline signals pending
        isOn && !outputEnabled ? 1.0 : 1.0
    }
}

/// Setting header with icon and tappable inline help.
/// Tap the icon or title to expand/collapse the help text.
struct SettingHeader: View {
    let icon: String
    let title: String
    let help: String
    @State private var showHelp = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(showHelp ? Theme.lightPink : (isHovered ? Theme.lightPink : Theme.pink))
                    .frame(width: 14)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(showHelp ? Theme.lightPink : (isHovered ? Theme.lightPink : Theme.pink))
                    .textCase(.uppercase)
                Spacer()
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showHelp.toggle() } }

            if showHelp {
                Theme.deepRose.opacity(0.3)
                    .frame(height: 1)
                    .padding(.leading, 19).padding(.top, 4)
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19).padding(.vertical, 4)
                Theme.deepRose.opacity(0.3)
                    .frame(height: 1)
                    .padding(.leading, 19).padding(.bottom, 4)
            }
        }
    }
}
