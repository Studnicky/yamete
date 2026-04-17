import SwiftUI

// MARK: - Notification locale picker

/// Themed dropdown for selecting which lproj bundle the notification body
/// strings are loaded from. Lists every locale present in the app bundle,
/// resolved to its native display name (e.g. "Français", "日本語").
internal struct NotificationLocalePicker: View {
    @Binding var selection: String

    private static let options: [(id: String, name: String)] = {
        // Bundle.main.localizations may include "Base"; filter it out.
        let ids = Bundle.main.localizations.filter { $0 != "Base" }
        let formatter = Locale(identifier: "en_US_POSIX")
        let options = ids.map { id -> (String, String) in
            let display = Locale(identifier: id).localizedString(forIdentifier: id)
                ?? formatter.localizedString(forIdentifier: id)
                ?? id
            return (id, display.capitalized(with: Locale(identifier: id)))
        }
        return options.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }()

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack {
                        Text(option.name)
                        if option.id == effectiveSelection {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(displayName(for: effectiveSelection))
                    .font(.caption)
                    .foregroundStyle(Theme.pink)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.mauve)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.listBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.listCornerRadius))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// If `selection` is empty (sentinel for "follow system"), resolve to the
    /// best-matching available locale so the picker shows that as selected.
    private var effectiveSelection: String {
        if !selection.isEmpty { return selection }
        return Bundle.main.preferredLocalizations.first ?? "en"
    }

    private func displayName(for id: String) -> String {
        Self.options.first(where: { $0.id == id })?.name ?? id
    }
}
