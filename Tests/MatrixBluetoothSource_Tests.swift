import XCTest
@testable import YameteCore
@testable import SensorKit

/// Bluetooth connect/disconnect matrix.
///
/// Bug class: IOKit's `IOServiceAddMatchingNotification` for
/// `IOBluetoothDevice` emits one event per device match/terminate. There is
/// no time-based debounce — each event must publish independently. If a
/// regression introduces erroneous "same-device" deduplication (treating
/// reconnect as a no-op), the user would miss the second connect.
///
/// `_injectConnect(name:)` and `_injectDisconnect(name:)` mirror the
/// `kIOFirstMatchNotification` / `kIOTerminatedNotification` callback,
/// bypassing `IORegistryEntryCreateCFProperty` lookups. Yields into the
/// same AsyncStream the production callback yields into.
@MainActor
final class MatrixBluetoothSourceTests: XCTestCase {

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

    // MARK: - Cell: connect/disconnect pair both publish

    func testConnectThenDisconnect_bothPublish() async {
        let bus = await makeBus()
        let source = BluetoothSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectConnect(name: "AirPods Pro")
        try? await Task.sleep(for: .milliseconds(15))
        await source._injectDisconnect(name: "AirPods Pro")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .bluetoothConnected }.count, 1,
            "[scenario=connect-disconnect-pair] connect must publish once")
        XCTAssertEqual(collected.filter { $0.kind == .bluetoothDisconnected }.count, 1,
            "[scenario=connect-disconnect-pair] disconnect must publish once")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: multiple devices in flight tracked independently

    func testMultipleDevices_eachTrackedIndependently() async {
        let bus = await makeBus()
        let source = BluetoothSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectConnect(name: "AirPods Pro")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectConnect(name: "Magic Keyboard")
        try? await Task.sleep(for: .milliseconds(5))
        await source._injectConnect(name: "Magic Trackpad")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .bluetoothConnected }.count, 3,
            "[scenario=multiple-devices] each distinct connect must publish, got \(collected.filter { $0.kind == .bluetoothConnected }.count)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: reconnect after disconnect (same device, both publish)

    func testReconnectAfterDisconnect_bothPublish() async {
        let bus = await makeBus()
        let source = BluetoothSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.4) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectConnect(name: "AirPods Pro")
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectDisconnect(name: "AirPods Pro")
        try? await Task.sleep(for: .milliseconds(10))
        await source._injectConnect(name: "AirPods Pro")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .bluetoothConnected }.count, 2,
            "[scenario=reconnect] both connects must publish (no spurious dedup), got \(collected.filter { $0.kind == .bluetoothConnected }.count)")
        XCTAssertEqual(collected.filter { $0.kind == .bluetoothDisconnected }.count, 1,
            "[scenario=reconnect] disconnect publishes once")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kind threshold — empty name

    func testEmptyName_doesNotCrashAndPublishes() async {
        let bus = await makeBus()
        let source = BluetoothSource()
        source.start(publishingTo: bus)

        let collectTask = Task { await self.collect(from: bus, seconds: 0.3) }
        try? await Task.sleep(for: .milliseconds(20))

        await source._injectConnect(name: "")
        try? await Task.sleep(for: .milliseconds(150))

        let collected = await collectTask.value
        XCTAssertEqual(collected.filter { $0.kind == .bluetoothConnected }.count, 1,
            "[scenario=empty-name] empty payload still publishes (no crash, no silent drop)")
        source.stop()
        await bus.close()
    }
    // MARK: - Cell: idempotent start — second start() does not double-install
    func testDoubleStart_doesNotDoubleInstallNotifications() async {
        let bus = await makeBus()
        let source = BluetoothSource()
        source.start(publishingTo: bus)
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 1,
            "[scenario=bt-double-start-idempotency] second start must be a no-op; expected installCount=1, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

    // MARK: - Cell: kernel-failure short-circuit — bad attachKr/detachKr ⇒ no install
    func testKernelFailure_doesNotInstall() async {
        let bus = await makeBus()
        let source = BluetoothSource()
        source._forceKernelFailureKr = KERN_FAILURE
        source.start(publishingTo: bus)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source._testInstallationCount, 0,
            "[scenario=bt-kernel-failure] kernel-success guard must short-circuit; expected installCount=0, got \(source._testInstallationCount)")
        source.stop()
        await bus.close()
    }

}
