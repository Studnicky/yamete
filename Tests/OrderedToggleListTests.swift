import XCTest
@testable import YameteApp

// MARK: - Test fixture

private struct Item: Identifiable, Hashable {
    let id: String
}

// MARK: - OrderedToggleListTests

@MainActor
final class OrderedToggleListTests: XCTestCase {

    // MARK: - Empty list

    func testEmptyList_rendersNothing() {
        var items = [Item]()
        var enabledIDs = Set<String>()
        // sorted returns empty when input is empty.
        let result = OrderedToggleListModel<Item>.sorted(items, enabledIDs: enabledIDs)
        XCTAssertTrue(result.isEmpty)
        // applyMove on empty is a no-op.
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: [],
            from: IndexSet(),
            to: 0
        )
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Enabled items appear above disabled items

    func testEnabledItemsAppearAboveDisabledItems() {
        let a = Item(id: "a")
        let b = Item(id: "b")
        let c = Item(id: "c")
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["b"]

        OrderedToggleListModel.applyEnabledStateChange(
            item: a,
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: []
        )
        // After enabling a, both a and b should be in the enabled partition (first).
        let enabledItems = items.prefix(enabledIDs.count)
        XCTAssertTrue(enabledItems.allSatisfy { enabledIDs.contains($0.id) },
                      "All items in the first \(enabledIDs.count) positions must be enabled")
        // c is disabled and should be at the end.
        XCTAssertFalse(enabledIDs.contains("c"))
        XCTAssertEqual(items.last?.id, "c")
    }

    func testDisabledItemsAppearBelowEnabledItems() {
        let a = Item(id: "a")
        let b = Item(id: "b")
        let c = Item(id: "c")
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a", "b", "c"]

        // Disable b — b should move to the disabled partition (after a and c).
        OrderedToggleListModel.applyEnabledStateChange(
            item: b,
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: []
        )
        XCTAssertFalse(enabledIDs.contains("b"))
        // The disabled item must appear below enabled items.
        let disabledIndex = items.firstIndex(where: { $0.id == "b" })!
        let enabledCount = enabledIDs.count
        XCTAssertGreaterThanOrEqual(disabledIndex, enabledCount,
                                    "Disabled item must appear at or after index \(enabledCount)")
    }

    // MARK: - Drag within enabled group: reorder without flipping state

    func testDragWithinEnabledGroup_reordersWithoutFlippingState() {
        let a = Item(id: "a")
        let b = Item(id: "b")
        let c = Item(id: "c")
        // Start: all enabled, order a-b-c.
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a", "b", "c"]

        // Move c (index 2) to index 0 — within the enabled group.
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: [],
            from: IndexSet(integer: 2),
            to: 0
        )

        // Order should now be c-a-b (or c-b-a depending on direction).
        XCTAssertEqual(items[0].id, "c", "c should be first after move to 0")
        // All items remain enabled.
        XCTAssertEqual(enabledIDs, Set(["a", "b", "c"]),
                       "enabledIDs must not change when dragging within enabled group")
    }

    func testDragWithinEnabledGroup_forwardMove() {
        let a = Item(id: "a")
        let b = Item(id: "b")
        let c = Item(id: "c")
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a", "b", "c"]

        // Move a (index 0) to after c (destination 3).
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: [],
            from: IndexSet(integer: 0),
            to: 3
        )

        XCTAssertEqual(items.last?.id, "a", "a should be last after move to end")
        XCTAssertEqual(enabledIDs, Set(["a", "b", "c"]))
    }

    // MARK: - Drag across boundary flips state

    func testDragFromEnabledToDisabledGroup_flipsState() {
        let a = Item(id: "a")
        let b = Item(id: "b")
        let c = Item(id: "c") // disabled
        // Initial: a, b enabled (index 0,1); c disabled (index 2).
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a", "b"]

        // Move b (index 1) to index 2 — within the disabled partition now.
        // Destination 2 is still within enabled half (boundary = 2), but
        // moving to index 3 (past boundary) should disable b.
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: [],
            from: IndexSet(integer: 1),
            to: 3  // destination past the end of enabled group
        )

        // b is now disabled (moved below the boundary).
        XCTAssertFalse(enabledIDs.contains("b"), "b should be disabled after crossing boundary")
        // a remains enabled.
        XCTAssertTrue(enabledIDs.contains("a"), "a should remain enabled")
    }

    func testDragFromDisabledToEnabledGroup_flipsState() {
        let a = Item(id: "a")
        let b = Item(id: "b")  // disabled
        let c = Item(id: "c")  // disabled
        // Initial: a enabled (index 0); b, c disabled (index 1, 2).
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a"]

        // Move c (index 2) to index 0 — into the enabled partition.
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: [],
            from: IndexSet(integer: 2),
            to: 0
        )

        // c should now be enabled (it landed in the enabled half).
        XCTAssertTrue(enabledIDs.contains("c"), "c should be enabled after move into enabled group")
        // Verify c is in the first enabledIDs.count positions.
        let newEnabledCount = enabledIDs.count
        let enabledSection = items.prefix(newEnabledCount)
        XCTAssertTrue(enabledSection.contains(where: { $0.id == "c" }),
                      "c must appear in the enabled partition")
    }

    // MARK: - Pinned item cannot be disabled via toggle

    func testPinnedItem_cannotBeDisabledViaToggleAction() {
        let a = Item(id: "a")  // pinned
        let b = Item(id: "b")
        var items = [a, b]
        var enabledIDs: Set<String> = ["a", "b"]
        let pinnedIDs: Set<String> = ["a"]

        // Attempt to toggle a off — should be a no-op.
        OrderedToggleListModel.applyEnabledStateChange(
            item: a,
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: pinnedIDs
        )

        XCTAssertTrue(enabledIDs.contains("a"), "Pinned item must remain enabled")
        XCTAssertEqual(items.count, 2)
    }

    func testPinnedItem_disableAttemptLeavesOrderUnchanged() {
        let a = Item(id: "a")  // pinned
        let b = Item(id: "b")
        var items = [a, b]
        var enabledIDs: Set<String> = ["a", "b"]
        let pinnedIDs: Set<String> = ["a"]

        let orderBefore = items.map(\.id)

        OrderedToggleListModel.applyEnabledStateChange(
            item: a,
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: pinnedIDs
        )

        XCTAssertEqual(items.map(\.id), orderBefore, "Order must not change on pinned toggle attempt")
    }

    // MARK: - Pinned item can still be reordered

    func testPinnedItem_canStillBeReordered() {
        let a = Item(id: "a")  // pinned
        let b = Item(id: "b")
        let c = Item(id: "c")
        // All enabled; a is pinned.
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a", "b", "c"]
        let pinnedIDs: Set<String> = ["a"]

        // Move a from index 0 to index 2 (still within enabled group).
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: pinnedIDs,
            from: IndexSet(integer: 0),
            to: 3
        )

        // a should have moved to the end of the enabled group.
        XCTAssertEqual(items.last?.id, "a", "Pinned item should have moved to last position")
        // a must still be enabled (it was pinned and all items remain enabled after intra-group move).
        XCTAssertTrue(enabledIDs.contains("a"), "Pinned item must remain enabled after reorder")
    }

    func testPinnedItem_cannotBeDroppedIntoDisabledGroup() {
        let a = Item(id: "a")  // pinned + enabled
        let b = Item(id: "b")  // enabled
        let c = Item(id: "c")  // disabled
        var items = [a, b, c]
        var enabledIDs: Set<String> = ["a", "b"]
        let pinnedIDs: Set<String> = ["a"]

        // Attempt to drag a (pinned, index 0) past the boundary into the
        // disabled group. The model should refuse to disable it, so a must
        // remain in enabledIDs even if the array position moved.
        OrderedToggleListModel.applyMove(
            items: &items,
            enabledIDs: &enabledIDs,
            pinnedIDs: pinnedIDs,
            from: IndexSet(integer: 0),
            to: 3  // past current boundary of 2
        )

        XCTAssertTrue(enabledIDs.contains("a"), "Pinned item must stay enabled even when dropped past boundary")
    }

    // MARK: - sorted helper

    func testSorted_enabledFirst() {
        let items = [Item(id: "a"), Item(id: "b"), Item(id: "c")]
        let enabledIDs: Set<String> = ["c"]
        let result = OrderedToggleListModel<Item>.sorted(items, enabledIDs: enabledIDs)
        XCTAssertEqual(result[0].id, "c", "Enabled item must appear first")
        XCTAssertFalse(enabledIDs.contains(result[1].id), "Second item must be disabled")
        XCTAssertFalse(enabledIDs.contains(result[2].id), "Third item must be disabled")
    }

    func testSorted_preservesRelativeOrderWithinGroup() {
        // Items: a(en), b(dis), c(en), d(dis) — enabled relative order must be a, c.
        let items = [Item(id: "a"), Item(id: "b"), Item(id: "c"), Item(id: "d")]
        let enabledIDs: Set<String> = ["a", "c"]
        let result = OrderedToggleListModel<Item>.sorted(items, enabledIDs: enabledIDs)
        XCTAssertEqual(result[0].id, "a")
        XCTAssertEqual(result[1].id, "c")
        XCTAssertEqual(result[2].id, "b")
        XCTAssertEqual(result[3].id, "d")
    }
}
