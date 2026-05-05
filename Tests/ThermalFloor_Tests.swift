//
// ThermalFloor_Tests
//
// Asserts the Detection.Thermal.shouldFire ratchet semantics and that
// ThermalSource respects the floor at publish time. The full transition
// matrix (4 states × 5 floor positions = 20 cells) is exhaustively
// driven so a regression in the gate math fails one named cell.
//
// Mutation pairing: ThermalSource floorProvider gate, Detection.Thermal
// rank table.
//
import XCTest
import os
@testable import YameteCore
@testable import SensorKit

@MainActor
final class ThermalFloor_Tests: XCTestCase {

    // MARK: - Pure rank table

    func testUIGate_thermalFloor_fullMatrix() {
        // (state raw 0..3, floor 0..4) -> expected fire?
        // floor 0 = off; floor 1 = critical only; floor 2 = serious + critical;
        // floor 3 = fair + serious + critical; floor 4 = everything.
        let cases: [(stateRaw: Int, floor: Int, expected: Bool)] = [
            (0, 0, false), (1, 0, false), (2, 0, false), (3, 0, false),
            (0, 1, false), (1, 1, false), (2, 1, false), (3, 1, true),
            (0, 2, false), (1, 2, false), (2, 2, true),  (3, 2, true),
            (0, 3, false), (1, 3, true),  (2, 3, true),  (3, 3, true),
            (0, 4, true),  (1, 4, true),  (2, 4, true),  (3, 4, true),
        ]
        for c in cases {
            XCTAssertEqual(
                Detection.Thermal.shouldFire(stateRaw: c.stateRaw, floor: c.floor),
                c.expected,
                "stateRaw=\(c.stateRaw) floor=\(c.floor): expected=\(c.expected)"
            )
        }
    }

    func testUIGate_thermalFloor_outOfBoundsIsOff() {
        XCTAssertFalse(Detection.Thermal.shouldFire(stateRaw: 0, floor: -1))
        XCTAssertFalse(Detection.Thermal.shouldFire(stateRaw: 3, floor: -1))
        XCTAssertFalse(Detection.Thermal.shouldFire(stateRaw: 0, floor: 99))
        XCTAssertFalse(Detection.Thermal.shouldFire(stateRaw: 3, floor: 99))
    }

    // MARK: - End-to-end via ThermalSource

    func test_thermalSource_floorGate_seriousDefault_blocksFair() async {
        let bus = ReactionBus()
        let mock = MockThermalProvider(initial: .nominal)
        let source = ThermalSource(provider: mock,
                                   floorProvider: { 2 })
        let received = LockedKinds()
        let stream = await bus.subscribe()
        let sink = Task {
            for await fired in stream { received.append(fired.reaction.kind) }
        }
        source.start(publishingTo: bus)
        mock.set(.fair)
        await source._testTriggerStateChange()
        mock.set(.serious)
        await source._testTriggerStateChange()
        try? await Task.sleep(nanoseconds: 200_000_000)
        await bus.close()
        sink.cancel()
        source.stop()
        XCTAssertEqual(received.snapshot(), [.thermalSerious],
                       "floor 2 should suppress .fair and pass .serious")
    }

    func test_thermalSource_floor0_suppressesEverything() async {
        let bus = ReactionBus()
        let mock = MockThermalProvider(initial: .nominal)
        let source = ThermalSource(provider: mock,
                                   floorProvider: { 0 })
        let received = LockedKinds()
        let stream = await bus.subscribe()
        let sink = Task {
            for await fired in stream { received.append(fired.reaction.kind) }
        }
        source.start(publishingTo: bus)
        for state in [ProcessInfo.ThermalState.fair, .serious, .critical] {
            mock.set(state)
            await source._testTriggerStateChange()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await bus.close()
        sink.cancel()
        source.stop()
        XCTAssertEqual(received.snapshot(), [], "floor 0 should publish nothing")
    }
}

// MARK: - Sendable mock + collector

private final class MockThermalProvider: ThermalStateProvider {
    private let lock = OSAllocatedUnfairLock<ProcessInfo.ThermalState>(initialState: .nominal)
    init(initial: ProcessInfo.ThermalState) { lock.withLock { $0 = initial } }
    var thermalState: ProcessInfo.ThermalState { lock.withLock { $0 } }
    func set(_ state: ProcessInfo.ThermalState) { lock.withLock { $0 = state } }
}

private final class LockedKinds: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[ReactionKind]>(initialState: [])
    func append(_ k: ReactionKind) { lock.withLock { $0.append(k) } }
    func snapshot() -> [ReactionKind] { lock.withLock { $0 } }
}
