#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import SwiftUI

// MARK: - OrderedToggleListModel

/// Pure-logic partition and move helper for `OrderedToggleList`.
/// Extracted so tests can drive the state-machine without instantiating
/// a SwiftUI body.
public struct OrderedToggleListModel<Item: Identifiable & Hashable> {

    // MARK: Partition

    /// Returns `items` reordered so that enabled items appear first (in their
    /// current relative order within the enabled group), followed by disabled
    /// items (in their current relative order within the disabled group).
    public static func sorted(
        _ items: [Item],
        enabledIDs: Set<Item.ID>
    ) -> [Item] {
        let enabled  = items.filter {  enabledIDs.contains($0.id) }
        let disabled = items.filter { !enabledIDs.contains($0.id) }
        return enabled + disabled
    }

    // MARK: Move

    /// Applies a `.onMove` offset-set move to `items`, adjusting `enabledIDs`
    /// when the destination crosses the enabled/disabled partition boundary.
    ///
    /// The boundary is the count of currently-enabled items **before** the
    /// move is applied. Items dropped above that boundary become enabled;
    /// items dropped at-or-below it become disabled. Pinned items cannot
    /// have their enabled state flipped off.
    ///
    /// - Parameters:
    ///   - items:      The current ordered array (enabled first, then disabled).
    ///   - enabledIDs: Current enabled-ID set. Mutated in place if a boundary
    ///                 crossing is detected.
    ///   - pinnedIDs:  IDs whose enabled state is immutable (cannot be disabled).
    ///   - source:     The `IndexSet` passed by SwiftUI `.onMove`.
    ///   - destination: The destination index passed by SwiftUI `.onMove`.
    public static func applyMove(
        items: inout [Item],
        enabledIDs: inout Set<Item.ID>,
        pinnedIDs: Set<Item.ID>,
        from source: IndexSet,
        to destination: Int
    ) {
        let enabledCount = items.filter { enabledIDs.contains($0.id) }.count

        // Perform the array move first (standard MutableCollection move).
        items.move(fromOffsets: source, toOffset: destination)

        // Recalculate membership based on final position.
        // After the move the array is in the user's new order; we walk it and
        // assign enabled/disabled based on where items sit relative to the
        // boundary (first `enabledCount` slots = enabled group).
        //
        // Special case: if a pinned item would land in the disabled half,
        // clamp the enabled count so it remains in the enabled group.
        var newEnabledCount = enabledCount
        // If destination < source.min, items moved upward; if destination >=
        // source.max, items moved downward. In either case the array is already
        // in the correct final order — we only need to recompute partition
        // membership from positions.
        //
        // Rebuild enabledIDs from positions: the first `newEnabledCount` items
        // are the enabled group. Walk from high index down to push any pinned
        // item back into enabled if it landed in the disabled half.
        for idx in 0..<items.count {
            let item = items[idx]
            let isInEnabledHalf = idx < newEnabledCount
            if !isInEnabledHalf && pinnedIDs.contains(item.id) {
                // Pinned item ended up below the boundary — keep it enabled by
                // extending the boundary one position.
                newEnabledCount = idx + 1
            }
        }

        // Apply updated enabledIDs.
        var updated = Set<Item.ID>()
        for idx in 0..<items.count {
            if idx < newEnabledCount {
                updated.insert(items[idx].id)
            }
        }
        // Preserve pinned items in enabled set regardless of boundary.
        for id in pinnedIDs where items.contains(where: { $0.id == id }) {
            updated.insert(id)
        }
        enabledIDs = updated
    }

    // MARK: Toggle

    /// Toggles `item`'s membership in `enabledIDs`, then moves it to the
    /// appropriate partition in `items`. Pinned items cannot be disabled.
    public static func applyEnabledStateChange(
        item: Item,
        items: inout [Item],
        enabledIDs: inout Set<Item.ID>,
        pinnedIDs: Set<Item.ID>
    ) {
        let currentlyEnabled = enabledIDs.contains(item.id)

        // Pinned items cannot be turned off.
        if currentlyEnabled && pinnedIDs.contains(item.id) { return }

        if currentlyEnabled {
            enabledIDs.remove(item.id)
        } else {
            enabledIDs.insert(item.id)
        }

        // Re-sort: keep relative order within each group.
        items = sorted(items, enabledIDs: enabledIDs)
    }
}

// MARK: - OrderedToggleList

/// A reusable SwiftUI component that renders a toggleable, reorderable list.
///
/// Items are auto-partitioned into two groups: enabled (above) and disabled
/// (below). Within each group the user's explicit drag order is respected.
/// Dragging an item across the partition boundary flips its enabled state.
/// Pinned items cannot be disabled but can still be reordered.
///
/// The component uses a `VStack` of rows (no `List`) to match the compact
/// menubar popover style used elsewhere in the app.
public struct OrderedToggleList<Item: Identifiable & Hashable>: View {

    // MARK: - Bindings

    /// All items in the user's current order (enabled first, then disabled,
    /// each subgroup ordered by user-set position).
    @Binding var items: [Item]

    /// IDs of currently-enabled items.
    @Binding var enabledIDs: Set<Item.ID>

    // MARK: - Configuration

    /// Items whose enabled state cannot be flipped off (but can still be
    /// reordered within the enabled group).
    let pinnedIDs: Set<Item.ID>

    /// Per-row label view builder supplied by the caller.
    let label: (Item) -> AnyView

    // MARK: - Init

    public init(
        items: Binding<[Item]>,
        enabledIDs: Binding<Set<Item.ID>>,
        pinnedIDs: Set<Item.ID> = [],
        @ViewBuilder label: @escaping (Item) -> some View
    ) {
        _items = items
        _enabledIDs = enabledIDs
        self.pinnedIDs = pinnedIDs
        self.label = { AnyView(label($0)) }
    }

    // MARK: - Drag state

    @State private var draggingID: Item.ID? = nil

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                row(for: item, at: idx)
                if idx < items.count - 1 {
                    Divider().padding(.leading, Theme.listDividerInset)
                }
            }
        }
        .background(Theme.listBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.listCornerRadius))
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(for item: Item, at index: Int) -> some View {
        let isEnabled = enabledIDs.contains(item.id)
        let isPinned  = pinnedIDs.contains(item.id)
        let isAboveBoundary = index < enabledIDs.count

        HStack(spacing: 4) {
            // Drag handle — ⠿ glyph styled to match the list density.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(Theme.stateInert.opacity(0.5))
                .frame(width: 14)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            guard draggingID == nil || draggingID == item.id else { return }
                            draggingID = item.id
                            handleDrag(item: item, currentIndex: index, translation: value.translation.height)
                        }
                        .onEnded { _ in draggingID = nil }
                )

            // Toggle (disabled for pinned items).
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in
                    var mutableItems = items
                    var mutableIDs   = enabledIDs
                    OrderedToggleListModel.applyEnabledStateChange(
                        item: item,
                        items: &mutableItems,
                        enabledIDs: &mutableIDs,
                        pinnedIDs: pinnedIDs
                    )
                    items     = mutableItems
                    enabledIDs = mutableIDs
                }
            ))
            .themeMiniSwitch()
            .disabled(isPinned && isEnabled)

            // Caller-provided label.
            label(item)
                .font(.system(size: 11))
                .foregroundStyle(isEnabled ? .primary : Theme.stateInert)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.toggleRowPadding)
        .opacity(isAboveBoundary ? 1.0 : 0.7)
    }

    // MARK: - Drag handler

    /// Translates a drag gesture's vertical translation into a move operation.
    /// Each row is approximately `Theme.toggleRowPadding.top + 11 + Theme.toggleRowPadding.bottom`
    /// tall. We compute how many rows the drag spans and call `applyMove`.
    private func handleDrag(item: Item, currentIndex: Int, translation: CGFloat) {
        let rowHeight: CGFloat = 22
        let offset = Int((translation / rowHeight).rounded())
        guard offset != 0 else { return }

        let targetIndex = (currentIndex + offset).clamped(to: 0...(items.count))
        guard targetIndex != currentIndex else { return }

        let source = IndexSet(integer: currentIndex)
        var mutableItems = items
        var mutableIDs   = enabledIDs
        OrderedToggleListModel.applyMove(
            items: &mutableItems,
            enabledIDs: &mutableIDs,
            pinnedIDs: pinnedIDs,
            from: source,
            to: targetIndex
        )
        items      = mutableItems
        enabledIDs = mutableIDs
    }
}
