import SwiftUI

// MARK: - Reusable device toggle list

internal struct DeviceToggleList<ID: Hashable>: View {
    let items: [(name: String, id: ID)]
    let emptyMessage: String?
    let noneSelectedMessage: String?
    let selectedIDs: [ID]
    let binding: (ID) -> Binding<Bool>

    init(items: [(name: String, id: ID)], emptyMessage: String? = nil,
         noneSelectedMessage: String? = nil, selectedIDs: [ID] = [],
         binding: @escaping (ID) -> Binding<Bool>) {
        self.items = items; self.emptyMessage = emptyMessage
        self.noneSelectedMessage = noneSelectedMessage
        self.selectedIDs = selectedIDs; self.binding = binding
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Toggle(isOn: binding(item.id)) {
                    Text(item.name).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).tint(Theme.pink).controlSize(.mini)
                .padding(Theme.toggleRowPadding)
                if i < items.count - 1 { Divider().padding(.leading, Theme.listDividerInset) }
            }
            if items.isEmpty, let msg = emptyMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .padding(Theme.toggleRowPadding)
            } else if !items.isEmpty && selectedIDs.isEmpty, let msg = noneSelectedMessage {
                Divider()
                Text(msg).font(.caption).foregroundStyle(Theme.mauve)
                    .padding(Theme.toggleRowPadding)
            }
        }
        .background(Theme.listBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.listCornerRadius))
    }
}
