import XCTest
@testable import YameteCore
@testable import SensorKit

/// USB attach/detach detection matrix.
///
/// Bug class: rapid IOKit USB callbacks (macOS often emits 2-3 spin-up
/// events per real attach) leak past the debounce gate, OR the boot-time
/// `kIOFirstMatchNotification` replay burst spams the bus with one
/// `.usbAttached` per currently-connected device.
///
/// This matrix drives `_injectAttach` / `_injectDetach`, which yield through
/// the same `AsyncStream` the production IOKit callback yields into and
/// run through the same `shouldPublish` (debounce + per-key dedup) +
/// `bus.publish` path the production drainer runs.
@MainActor
final class MatrixUSBSourceTests: XCTestCase {

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(
                reaction: reaction,
                clipDuration: 0.5,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: publishedAt
            )
        }
        return bus
    }

    private func collect(from bus: ReactionBus, seconds: TimeInterval) async -> [FiredReaction] {
        let stream = await bus.subscribe()
        let task = Task {
            var collected: [FiredReaction] = []
            for await fired in stream {
                collected.append(fired)
            }
            return collected
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        return await task.value
    }

    // MARK: - Cell: rapid same-device attach is debounced (3 → 1)

    func testRapidSameDeviceAttach_debouncedToOne() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        // Three rapid attach events for the same vendor/product within the
        // 50ms debounce window. Production must collapse to one publish.
        //
        // Original spacing was 10ms × 3 = 30ms total span. Under CI the
        // 10ms `Task.sleep`s stretch enough that the third inject can
        // land past the 50ms debounce boundary, producing 2 publishes
        // instead of 1. Inject back-to-back via `Task.yield()` so the
        // span is bounded by scheduler turnaround (sub-ms) regardless
        // of host load.
        await source._injectAttach(vendor: "Apple", product: "Magic Mouse")
        await Task.yield()
        await source._injectAttach(vendor: "Apple", product: "Magic Mouse")
        await Task.yield()
        await source._injectAttach(vendor: "Apple", product: "Magic Mouse")
        try? await Task.sleep(for: CITiming.scaledDuration(ms: 150))

        let collected = await collectTask.value
        let attaches = collected.filter { $0.kind == .usbAttached }
        XCTAssertEqual(attaches.count, 1,
            "[scenario=rapid-same-device-attach] expected debounce to collapse 3 → 1, got \(attaches.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: distinct devices each get their own slot (3 → 3)

    func testDistinctDeviceAttaches_allPass() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(vendor: "Apple",     product: "Magic Mouse")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectAttach(vendor: "Logitech",  product: "MX Master")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectAttach(vendor: "Razer",     product: "DeathAdder")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let attaches = collected.filter { $0.kind == .usbAttached }
        XCTAssertEqual(attaches.count, 3,
            "[scenario=distinct-device-attaches] independent debounce keys must allow 3 publishes, got \(attaches.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: attach/detach pair (different keys) both publish

    func testAttachThenDetachPair_bothPublish() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(vendor: "Apple", product: "Keyboard")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectDetach(vendor: "Apple", product: "Keyboard")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let attaches = collected.filter { $0.kind == .usbAttached }
        let detaches = collected.filter { $0.kind == .usbDetached }
        XCTAssertEqual(attaches.count, 1,
            "[scenario=attach-detach-pair] attach must publish once, got \(attaches.count)")
        XCTAssertEqual(detaches.count, 1,
            "[scenario=attach-detach-pair] detach must publish once (different debounce key), got \(detaches.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: debounce-just-over-threshold (80ms apart fire separately)

    func testAttachesSeparatedPastDebounce_bothPublish() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(vendor: "Apple", product: "Keyboard")
        try? await Task.sleep(for: .milliseconds(80)) // > 50ms debounce + slack
        await source._injectAttach(vendor: "Apple", product: "Keyboard")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let attaches = collected.filter { $0.kind == .usbAttached }
        XCTAssertEqual(attaches.count, 2,
            "[scenario=past-debounce-window] 80ms-apart attaches must fire separately, got \(attaches.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kind threshold — empty vendor/product strings

    /// Input-validation cell. The production callback resolves vendor/product
    /// from `IORegistryEntryCreateCFProperty` and substitutes "USB Device" /
    /// 0 when missing. The seam doesn't run that resolver, but the source
    /// must still NOT crash and must still publish (with whatever the
    /// degraded payload looks like). Asserts that empty strings flow through
    /// the pipeline without trapping.
    func testEmptyDeviceStrings_doesNotCrashAndPublishes() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(vendor: "", product: "")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .usbAttached }.count, 1,
            "[scenario=empty-device-strings] empty payload must still publish (no crash, no silent drop)")
        source.stop()
        await bus.close()
    }
    // MARK: - Cell: idempotent start — second start() does not double-install
    func testDoubleStart_doesNotDoubleInstallNotifications() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 1,
            "[scenario=usb-double-start-idempotency] second start must be a no-op; expected installCount=1, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kernel-failure short-circuit — bad attachKr/detachKr ⇒ no install
    func testKernelFailure_doesNotInstall() async {
        let bus = await makeBus()
        let source = USBSource()
        source._forceKernelFailureKr = KERN_FAILURE
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 0,
            "[scenario=usb-kernel-failure] kernel-success guard must short-circuit; expected installCount=0, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

}
