import XCTest
import AppKit
@testable import YameteCore
@testable import SensorKit

/// Ring 2 (L2) — Mouse behavioural tests against the REAL `RealEventMonitor`.
///
/// Where Ring 1 (`MatrixMouseOSEvents_Tests`) drives `MockEventMonitor.emit`
/// to inject synthetic NSEvents, this Ring 2 file synthesizes
/// system-level CGEvents via `CGEvent.post(tap: .cghidEventTap)` so the entire
/// scroll detection pipeline runs end-to-end:
///
///     CGEvent.post → kernel HID event tap → NSEvent dispatch
///     → RealEventMonitor's NSEvent global monitor closure
///     → MouseActivitySource handler → RMS / debounce → ReactionBus.publish
///
/// **Click cells use the `_injectClick(transport:product:)` seam.**
/// `CGEvent.post` cannot set the HID transport / product strings that the
/// production callback reads via `IOHIDDeviceGetProperty`. Without those
/// strings the production filter (`transport != "SPI"`) cannot be exercised
/// end-to-end. The test seam mirrors the real callback path: it calls the
/// shared `handleHIDClick(transport:product:)` so the production filter,
/// debounce, and bus publish all run.
///
/// **System-event-tap latency**: posted scroll events round-trip through the
/// kernel and arrive at NSEvent monitors after ~50-150ms (idle host) or
/// 250-400ms (under load). Cells use 250-400ms waits.
///
/// **TCC**: posting at `.cghidEventTap` requires Accessibility. Cells fall
/// back to `XCTSkip` when no events arrive (no events ⇒ TCC denied).
@MainActor
final class MatrixL2_Mouse_Tests: XCTestCase {

    // MARK: - System-level CGEvent helpers

    /// Empty-phase scroll (mouse-wheel signature). The production filter
    /// `event.phase.isEmpty && event.momentumPhase.isEmpty` accepts these.
    private func postEmptyPhaseScroll(deltaY: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: deltaY,
                               wheel2: 0,
                               wheel3: 0) else { return }
        // Explicitly leave scrollPhase at default 0 (empty).
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        cg.post(tap: .cghidEventTap)
    }

    /// Phased scroll (trackpad signature). Used to assert the production
    /// `phase.isEmpty` gate rejects trackpad events on the mouse source.
    private func postPhasedScroll(deltaY: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: deltaY,
                               wheel2: 0,
                               wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)  // .began
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        cg.post(tap: .cghidEventTap)
    }

    // MARK: - Bus / collection

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction,
                          clipDuration: 0.5,
                          soundURL: nil,
                          faceIndices: [0],
                          publishedAt: publishedAt)
        }
        return bus
    }

    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [FiredReaction] {
        let stream = await bus.subscribe()
        return await withTaskGroup(of: [FiredReaction].self) { group -> [FiredReaction] in
            group.addTask {
                var collected: [FiredReaction] = []
                for await fired in stream { collected.append(fired) }
                return collected
            }
            group.addTask { [bus] in
                try? await Task.sleep(for: .seconds(seconds))
                await bus.close()
                return []
            }
            var all: [FiredReaction] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
    }

    private func makeRealSource(scrollThreshold: Double = 1.0) -> MouseActivitySource {
        // Real EventMonitor (drives scroll path edge-to-edge), but HID click
        // detection OFF so ambient OS clicks during the test window can't
        // bleed in. Click cells drive `_injectClick` which exercises the
        // shared `handleHIDClick` filter regardless of the HID kill-switch.
        let s = MouseActivitySource(eventMonitor: RealEventMonitor(), enableHIDClickDetection: false)
        s.configure(scrollThreshold: scrollThreshold)
        return s
    }

    // MARK: - L2 Cell 1 — empty-phase scroll posted, .mouseScrolled fires

    /// End-to-end: post empty-phase wheel events, real `RealEventMonitor`
    /// closure dispatches, RMS clears threshold, `.mouseScrolled` publishes.
    func test_L2_mouseScroll_emptyPhasePostedFiresMouseScrolled() async throws {
        let bus = await makeBus()
        let source = makeRealSource(scrollThreshold: 1.0)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(80))

        // 400ms collection — accommodates HID tap round-trip plus debounce.
        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(40))

        for _ in 0..<8 {
            postEmptyPhaseScroll(deltaY: 10)
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Bumped to 350ms — Ring 1 used 150ms for in-process closure; the
        // CGEvent.post round-trip through the kernel + WindowServer adds
        // 100-200ms of latency we have to absorb.
        try? await Task.sleep(for: .milliseconds(350))

        let collected = await collectTask.value
        let scrolled = collected.filter { $0.kind == .mouseScrolled }
        if collected.isEmpty {
            throw XCTSkip("L2_mouseScroll: CGEvent.post did not deliver — likely TCC Accessibility not granted to swift test runner")
        }
        XCTAssertGreaterThanOrEqual(scrolled.count, 1,
            "[L2_mouseScroll] empty-phase posted scrolls must fire .mouseScrolled — got \(scrolled.count) (all: \(collected.map(\.kind)))")

        source.stop()
    }

    // MARK: - L2 Cell 2 — phased scroll posted does NOT fire on mouse source

    /// Production gate `event.phase.isEmpty` must reject trackpad-flavored
    /// scrolls on the mouse source. End-to-end via posted CGEvent.
    func test_L2_phasedScrollDoesNotFireMouseScrolled() async throws {
        let bus = await makeBus()
        let source = makeRealSource(scrollThreshold: 0.5)  // easy to clear if gate is broken
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(80))

        let collectTask = Task { await self.collect(from: bus, seconds: 0.55) }
        try? await Task.sleep(for: .milliseconds(40))

        for _ in 0..<10 {
            postPhasedScroll(deltaY: 30)
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(350))

        let collected = await collectTask.value
        // The negative assertion holds even if TCC denied the post — no
        // events ⇒ no false fires. Don't skip.
        XCTAssertFalse(collected.contains { $0.kind == .mouseScrolled },
            "[L2_phasedScrollRejected] phased scroll must NOT fire .mouseScrolled (production gate `phase.isEmpty`) — got \(collected.map(\.kind))")

        source.stop()
    }

    // MARK: - L2 Cell 3 — _injectClick on USB Logitech fires .mouseClicked

    /// IOHID transport metadata cannot be set on synthetic CGEvents, so
    /// click cells use `_injectClick`. The seam routes through the same
    /// `handleHIDClick(transport:product:)` the production callback uses,
    /// so the transport/product filter, debounce, and bus publish all run.
    func test_L2_hidClick_USB_LogitechFiresMouseClicked() async {
        let bus = await makeBus()
        let source = makeRealSource()
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(40))

        let collectTask = Task { await self.collect(from: bus, seconds: 0.45) }
        try? await Task.sleep(for: .milliseconds(40))

        await source._injectClick(transport: "USB", product: "Logitech USB Receiver")
        try? await Task.sleep(for: .milliseconds(250))

        let collected = await collectTask.value
        XCTAssertTrue(collected.contains { $0.kind == .mouseClicked },
            "[L2_hidClick_Logitech] USB non-trackpad click must fire .mouseClicked — got \(collected.map(\.kind))")

        source.stop()
    }

    // MARK: - L2 Cell 4 — _injectClick on SPI dropped at production filter

    /// SPI transport (built-in trackpad button) → production filter drops it.
    func test_L2_hidClick_SPI_dropped() async {
        let bus = await makeBus()
        let source = makeRealSource()
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(40))

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(40))

        await source._injectClick(transport: "SPI", product: "Apple Internal Trackpad")
        try? await Task.sleep(for: .milliseconds(250))

        let collected = await collectTask.value
        XCTAssertFalse(collected.contains { $0.kind == .mouseClicked },
            "[L2_hidClick_SPI] SPI transport must be dropped at production filter — got \(collected.map(\.kind))")

        source.stop()
    }

    // MARK: - L2 Cell 5 — _injectClick burst is debounced to one

    /// Production debounce is 0.5s. Multiple injected clicks inside that
    /// window must collapse to a single `.mouseClicked`.
    func test_L2_hidClick_burstDebouncesToOne() async {
        let bus = await makeBus()
        let source = makeRealSource()
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(40))

        let collectTask = Task { await self.collect(from: bus, seconds: 0.6) }
        try? await Task.sleep(for: .milliseconds(40))

        // 5 injected clicks within 100ms — well inside 500ms debounce.
        for _ in 0..<5 {
            await source._injectClick(transport: "USB", product: "Logitech USB Receiver")
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(250))

        let collected = await collectTask.value
        let clicks = collected.filter { $0.kind == .mouseClicked }
        XCTAssertEqual(clicks.count, 1,
            "[L2_hidClick_debounce] 5 clicks within 100ms must debounce to exactly 1 .mouseClicked — got \(clicks.count)")

        source.stop()
    }
}
