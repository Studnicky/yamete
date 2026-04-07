import SwiftUI

/// Shared app color palette.
enum Theme {
    static let pink      = Color(red: 0.867, green: 0.357, blue: 0.522)  // #DD5B85
    static let deepRose  = Color(red: 0.643, green: 0.165, blue: 0.357)  // #A42A5B
    static let mauve     = Color(red: 0.784, green: 0.471, blue: 0.663)  // #C878A9
    static let lightPink = Color(red: 0.949, green: 0.588, blue: 0.659)  // #F296A8
    static let dark      = Color(red: 0.055, green: 0.055, blue: 0.055)  // #0E0E0E

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
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            Button(action: { isExpanded.toggle() }) {
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

            // Expanded content
            if isExpanded {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.deepRose.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .padding(.horizontal, 8).padding(.vertical, 4)
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
                    .padding(.leading, 19).padding(.top, 2)
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19).padding(.bottom, 4)
            }
        }
    }
}
