import SwiftUI

internal struct SelectionList<ID: Hashable>: View {
    struct Item {
        let title: String
        let subtitle: String?
        let icon: String
        let id: ID
    }

    let items: [Item]
    @Binding var selection: ID

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button(action: { selection = item.id }) {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selection == item.id ? Theme.pink : Theme.mauve)
                            .frame(width: 14)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(selection == item.id ? .primary : .primary)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer()

                        Image(systemName: selection == item.id ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(selection == item.id ? Theme.pink : Color.secondary.opacity(0.5))
                    }
                    .padding(Theme.toggleRowPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if i < items.count - 1 {
                    Divider().padding(.leading, Theme.listDividerInset)
                }
            }
        }
        .background(Theme.listBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.listCornerRadius))
    }
}
