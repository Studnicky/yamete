import SwiftUI

// MARK: - Reusable device toggle list

internal struct DeviceToggleList<ID: Hashable>: View {
    let items: [(name: String, id: ID)]
    let emptyMessage: String?
    let noneSelectedMessage: String?
    let selectedIDs: [ID]
    let binding: (ID) -> Binding<Bool>
    /// Optional leading icon name (SF Symbols) per row. Returns nil to
    /// render the row without an icon. Audio rows pass a transport-class
    /// icon here so the user can tell at a glance whether the output is
    /// a monitor speaker, a USB device, headphones, etc.
    let leadingIcon: ((ID) -> String?)?
    /// Optional trailing footnote per row. Audio rows pass the paired
    /// display name ("attached to LG UltraFine") here when EDID matching
    /// or built-in pairing succeeded.
    let trailingFootnote: ((ID) -> String?)?

    init(items: [(name: String, id: ID)], emptyMessage: String? = nil,
         noneSelectedMessage: String? = nil, selectedIDs: [ID] = [],
         leadingIcon: ((ID) -> String?)? = nil,
         trailingFootnote: ((ID) -> String?)? = nil,
         binding: @escaping (ID) -> Binding<Bool>) {
        self.items = items; self.emptyMessage = emptyMessage
        self.noneSelectedMessage = noneSelectedMessage
        self.selectedIDs = selectedIDs
        self.leadingIcon = leadingIcon
        self.trailingFootnote = trailingFootnote
        self.binding = binding
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Toggle(isOn: binding(item.id)) {
                    HStack(alignment: .center, spacing: 6) {
                        if let icon = leadingIcon?(item.id) {
                            Image(systemName: icon)
                                .imageScale(.small)
                                .foregroundStyle(Theme.stateInert)
                                .frame(width: 14)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let footnote = trailingFootnote?(item.id) {
                                Text(footnote)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.stateInert)
                                    .lineLimit(1)
                            }
                        }
                    }
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
