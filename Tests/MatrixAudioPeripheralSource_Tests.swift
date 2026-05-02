import XCTest
@testable import YameteCore
@testable import SensorKit

/// Audio peripheral attach/detach matrix.
///
/// Bug class: the `AudioObjectAddPropertyListenerBlock` callback fires once
/// per device-set change but the callback gets the FULL device set, not a
/// delta. The dedup in `handleChange(newDevices:names:)` is the
/// `Set.subtracting` diff against `knownDevices`. If the diff regresses to
/// emitting one event per device in the new set instead of per-added-device,
/// every change spams the bus with the entire current peripheral list. If
/// the dedup misses the "no actual change" case (CoreAudio fires for any
/// property change, not just attach/detach), an identical-set re-notify
/// publishes nothing — the test pins that.
///
/// `_injectAttach(uid:name:)` and `_injectDetach(uid:name:)` mirror the
/// CoreAudio listener's per-callback diff against the known set, bypassing
/// the system `Self.snapshot()` query.
@MainActor
final class MatrixAudioPeripheralSourceTests: XCTestCase {

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

    // MARK: - Cell: adding 1 device to set of 5 → exactly 1 attached publish

    func testAddOneToSetOfFive_publishesOneAttached() async {
        let bus = await makeBus()
        let source = AudioPeripheralSource()
        source.start(publishingTo: bus)
        // Seed baseline so the diff has something to subtract against.
        source._testSeedKnownDevices(["uid-A", "uid-B", "uid-C", "uid-D", "uid-E"])

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(uid: "uid-NEW", name: "USB Mic")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let attaches = collected.filter { $0.kind == .audioPeripheralAttached }
        let detaches = collected.filter { $0.kind == .audioPeripheralDetached }
        XCTAssertEqual(attaches.count, 1,
            "[scenario=add-one-to-five] expected 1 attached publish for the new uid, got \(attaches.count)")
        XCTAssertEqual(detaches.count, 0,
            "[scenario=add-one-to-five] no devices removed, must not publish detached, got \(detaches.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: removing 1 device → exactly 1 detached publish

    func testRemoveOneFromSet_publishesOneDetached() async {
        let bus = await makeBus()
        let source = AudioPeripheralSource()
        source.start(publishingTo: bus)
        source._testSeedKnownDevices(["uid-A", "uid-B", "uid-C"])

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectDetach(uid: "uid-B", name: "Audio Device")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let attaches = collected.filter { $0.kind == .audioPeripheralAttached }
        let detaches = collected.filter { $0.kind == .audioPeripheralDetached }
        XCTAssertEqual(detaches.count, 1,
            "[scenario=remove-one] expected 1 detached publish for removed uid, got \(detaches.count)")
        XCTAssertEqual(attaches.count, 0,
            "[scenario=remove-one] no devices added, must not publish attached, got \(attaches.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: identical-set re-notify → zero publishes

    /// CoreAudio fires its listener for ANY power-property change, not just
    /// attach/detach. If the listener body sees the same device set it had
    /// last time, the diff must produce nothing.
    func testIdenticalSetReNotify_publishesNothing() async {
        let bus = await makeBus()
        let source = AudioPeripheralSource()
        source.start(publishingTo: bus)
        source._testSeedKnownDevices(["uid-A", "uid-B"])

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        // Re-attach an existing uid — diff should produce no added/removed.
        await source._injectAttach(uid: "uid-A", name: "Audio Device")
        try? await Task.sleep(for: .milliseconds(50))
        // Detach of a uid not in the set — diff should also produce nothing.
        await source._injectDetach(uid: "uid-NEVER-PRESENT", name: "Phantom")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        let audioEvents = collected.filter {
            $0.kind == .audioPeripheralAttached || $0.kind == .audioPeripheralDetached
        }
        XCTAssertEqual(audioEvents.count, 0,
            "[scenario=identical-set-re-notify] no real diff → no publish, got \(audioEvents.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kind threshold — empty uid passes through

    func testEmptyUID_publishes() async {
        let bus = await makeBus()
        let source = AudioPeripheralSource()
        source.start(publishingTo: bus)
        source._testSeedKnownDevices([])

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectAttach(uid: "", name: "")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(
            collected.filter { $0.kind == .audioPeripheralAttached }.count, 1,
            "[scenario=empty-uid] empty uid is degenerate but the source must not crash and must publish"
        )
        source.stop()
        await bus.close()
    }
    // MARK: - Cell: idempotent start — second start() does not double-install listener
    func testDoubleStart_doesNotDoubleInstallListener() async {
        let bus = await makeBus()
        let source = AudioPeripheralSource()
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 1,
            "[scenario=audio-double-start-idempotency] second start must be a no-op; expected installCount=1, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kernel-failure short-circuit — bad listener status ⇒ no install
    func testKernelFailure_doesNotInstall() async {
        let bus = await makeBus()
        let source = AudioPeripheralSource()
        source._forceListenerStatus = OSStatus(-1)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 0,
            "[scenario=audio-kernel-failure] kernel-success guard must short-circuit; expected installCount=0, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

}
