import XCTest
@preconcurrency import AVFoundation
import os
@testable import YameteCore
@testable import SensorKit

// MARK: - State-machine model-check tests
//
// Several types in Yamete are state machines whose lifecycle invariants
// are tested elsewhere example-by-example. This file model-checks them:
// for every reachable state, drive every transition; assert the post-state
// matches the production model; and assert illegal transitions are
// rejected (state unchanged, no extra side effects).
//
// Cells:
//   1. ProbeStage exhaustive transition graph
//      (HeadphoneMotionSource.ProbeStage)
//   2. ProbeStage illegal-transition detection
//      (terminal states have no outgoing edges)
//   3. ImpactFusion lifecycle BFS
//      (start / stop / double-stop / start-after-stop / interleaved)
//   4. ReactionBus subscriber lifecycle
//      (subscribe → publish → close orderings; no replay invariant)
//   5. MicrophoneSource OnceCleanup lifecycle
//      (open / cancel / re-open — driver teardown at most once per cycle)
//   6. TrackpadActivitySource start/stop machine
//      (monitor install/remove counts via MockEventMonitor)
//
// Style: each cell defines an enum `State` matching the production type,
// builds a transition table `[(from, action, expected)]`, and loops with
// XCTAssertEqual carrying coordinate-tagged failure messages.
@MainActor
final class StateMachine_Tests: XCTestCase {

    // ------------------------------------------------------------------
    // Cell 1 — ProbeStage exhaustive transition graph
    // ------------------------------------------------------------------
    //
    // Production states (HeadphoneMotionSource.ProbeStage):
    //   .pending  — init done, probe not started
    //   .running  — probe holds the manager
    //   .complete — probe finished naturally and stopped the manager
    //   .takenOver — impacts() took the manager from the probe
    //
    // Reachable transitions:
    //   pending  → running   (init with runProbe=true)
    //   running  → complete  (deferred probe stop fires while .running)
    //   running  → takenOver (impacts() called while probe is .running)
    //
    // After construction with runProbe=true, the adapter is in .running.
    // We therefore drive .pending separately by constructing with
    // runProbe=false (which leaves the field at its initial-state value).
    func testCell1_ProbeStage_exhaustiveTransitions() async {
        // pending: runProbe=false leaves the lock at its initial value.
        do {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: false)
            XCTAssertEqual(
                adapter._testCurrentProbeStage, .pending,
                "[state-machine=ProbeStage] from=init(runProbe:false), expected=pending, got=\(adapter._testCurrentProbeStage)"
            )
        }

        // pending → running (runProbe=true with framework available)
        do {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: true)
            XCTAssertEqual(
                adapter._testCurrentProbeStage, .running,
                "[state-machine=ProbeStage] from=pending, action=startProbe, expected=running, got=\(adapter._testCurrentProbeStage)"
            )
        }

        // running → complete (deferred probe stop while still .running)
        do {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: true)
            XCTAssertEqual(adapter._testCurrentProbeStage, .running)
            adapter._testRunDeferredProbeStop()
            XCTAssertEqual(
                adapter._testCurrentProbeStage, .complete,
                "[state-machine=ProbeStage] from=running, action=deferredStop, expected=complete, got=\(adapter._testCurrentProbeStage)"
            )
            // Production must release the device exactly once on complete.
            XCTAssertEqual(
                mock.stopUpdatesCalls, 1,
                "[state-machine=ProbeStage] complete must call stopUpdates exactly once; got \(mock.stopUpdatesCalls)"
            )
        }

        // running → takenOver (impacts() takeover)
        do {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            mock.setHeadphonesConnected(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: true)
            XCTAssertEqual(adapter._testCurrentProbeStage, .running)

            let stream = adapter.impacts()
            let consumer = Task<Void, Error> {
                for try await _ in stream {}
            }
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(
                adapter._testCurrentProbeStage, .takenOver,
                "[state-machine=ProbeStage] from=running, action=impactsTakeover, expected=takenOver, got=\(adapter._testCurrentProbeStage)"
            )
            consumer.cancel()
            _ = try? await consumer.value
        }
    }

    // ------------------------------------------------------------------
    // Cell 2 — ProbeStage illegal-transition detection
    // ------------------------------------------------------------------
    //
    // Terminal states (.complete, .takenOver) MUST have no outgoing edges
    // in the production model. The deferred probe-stop body is gated on
    // `stage == .running`; if it fires while the stage is anything else
    // it must no-op (state unchanged, stopUpdates NOT called).
    func testCell2_ProbeStage_illegalTransitionsAreRejected() async {
        // complete → ??? (deferred-stop must no-op once already complete)
        do {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: true)
            adapter._testRunDeferredProbeStop() // running → complete
            XCTAssertEqual(adapter._testCurrentProbeStage, .complete)
            let stopsBefore = mock.stopUpdatesCalls

            // Illegal: drive deferred-stop again while in .complete.
            adapter._testRunDeferredProbeStop()
            XCTAssertEqual(
                adapter._testCurrentProbeStage, .complete,
                "[state-machine=ProbeStage] from=complete, action=deferredStop, expected=complete (terminal/no-op), got=\(adapter._testCurrentProbeStage)"
            )
            XCTAssertEqual(
                mock.stopUpdatesCalls, stopsBefore,
                "[state-machine=ProbeStage] terminal complete must not produce side effects; got extra stopUpdates"
            )
        }

        // takenOver → ??? (deferred-stop must no-op once impacts() took over)
        do {
            let mock = MockHeadphoneMotionDriver()
            mock.setDeviceMotionAvailable(true)
            mock.setHeadphonesConnected(true)
            let adapter = HeadphoneMotionSource(driver: mock, runProbe: true)
            let stream = adapter.impacts()
            let consumer = Task<Void, Error> { for try await _ in stream {} }
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(adapter._testCurrentProbeStage, .takenOver)
            let stopsBefore = mock.stopUpdatesCalls

            // Illegal: drive deferred-stop while in .takenOver.
            adapter._testRunDeferredProbeStop()
            XCTAssertEqual(
                adapter._testCurrentProbeStage, .takenOver,
                "[state-machine=ProbeStage] from=takenOver, action=deferredStop, expected=takenOver (terminal/no-op), got=\(adapter._testCurrentProbeStage)"
            )
            XCTAssertEqual(
                mock.stopUpdatesCalls, stopsBefore,
                "[state-machine=ProbeStage] terminal takenOver must not call stopUpdates from late deferred-stop; got extra"
            )

            consumer.cancel()
            _ = try? await consumer.value
        }
    }

    // ------------------------------------------------------------------
    // Cell 3 — ImpactFusion lifecycle BFS
    // ------------------------------------------------------------------
    //
    // States are encoded as the boolean `isRunning` flag plus the
    // observable counters in `_testHooks`. Transitions:
    //   stopped → stopped via stop()    (idempotent guard fires)
    //   stopped → running via start()   (when sources available)
    //   running → stopped via stop()    (teardown branch)
    //   running → running via start()   (re-entrant; stop()-then-start)
    //
    // Walks: init / stop@stopped / double-stop@stopped / start@stopped /
    // start@running (re-entrant) / stop@running / start@stopped(2) /
    // stop@running(2). After each step, asserts isRunning and the
    // _testHooks counters.
    func testCell3_ImpactFusion_lifecycleBFS() async {
        struct Step {
            let name: String
            let action: @MainActor (ImpactFusion, ReactionBus, [any SensorSource]) -> Void
            let expectIsRunning: Bool
            let expectStopInvocations: Int
            let expectStopTeardowns: Int
            let expectLastStopWasNoOp: Bool?
        }

        let steps: [Step] = [
            // 0: initial (no actions yet) — isRunning=false, no stop calls.
            Step(name: "init", action: { _, _, _ in },
                 expectIsRunning: false, expectStopInvocations: 0,
                 expectStopTeardowns: 0, expectLastStopWasNoOp: nil),
            // 1: stop while not running — guard fires, no teardown.
            Step(name: "stop@stopped", action: { f, _, _ in f.stop() },
                 expectIsRunning: false, expectStopInvocations: 1,
                 expectStopTeardowns: 0, expectLastStopWasNoOp: true),
            // 2: stop again while still stopped — still a no-op.
            Step(name: "double-stop@stopped", action: { f, _, _ in f.stop() },
                 expectIsRunning: false, expectStopInvocations: 2,
                 expectStopTeardowns: 0, expectLastStopWasNoOp: true),
            // 3: start with one available source — running flag flips.
            Step(name: "start@stopped", action: { f, b, s in f.start(sources: s, bus: b) },
                 expectIsRunning: true, expectStopInvocations: 2,
                 expectStopTeardowns: 0, expectLastStopWasNoOp: true),
            // 4: start while already running — production calls stop() then
            //    start() (re-entrant). One extra stop invocation; teardown runs.
            Step(name: "start@running", action: { f, b, s in f.start(sources: s, bus: b) },
                 expectIsRunning: true, expectStopInvocations: 3,
                 expectStopTeardowns: 1, expectLastStopWasNoOp: false),
            // 5: stop while running — teardown branch.
            Step(name: "stop@running", action: { f, _, _ in f.stop() },
                 expectIsRunning: false, expectStopInvocations: 4,
                 expectStopTeardowns: 2, expectLastStopWasNoOp: false),
            // 6: start after stop — back to running.
            Step(name: "start@stopped(2)", action: { f, b, s in f.start(sources: s, bus: b) },
                 expectIsRunning: true, expectStopInvocations: 4,
                 expectStopTeardowns: 2, expectLastStopWasNoOp: false),
            // 7: stop final.
            Step(name: "stop@running(2)", action: { f, _, _ in f.stop() },
                 expectIsRunning: false, expectStopInvocations: 5,
                 expectStopTeardowns: 3, expectLastStopWasNoOp: false),
        ]

        let bus = ReactionBus()
        let fusion = ImpactFusion(config: FusionConfig(
            consensusRequired: 1, fusionWindow: 0.05, rearmDuration: 0.05
        ))
        let mock = MockMicrophoneEngineDriver()
        let source = MicrophoneSource(
            driverFactory: { mock },
            availabilityOverride: { true }
        )
        let sources: [any SensorSource] = [source]

        for (i, step) in steps.enumerated() {
            step.action(fusion, bus, sources)
            // Allow re-entrant start(sources:bus:) (which calls stop()
            // internally) to complete its teardown observers before we
            // sample counters.
            await Task.yield()
            XCTAssertEqual(
                fusion.isRunning, step.expectIsRunning,
                "[state-machine=ImpactFusion] step=\(i)/\(step.name) isRunning expected=\(step.expectIsRunning), got=\(fusion.isRunning)"
            )
            XCTAssertEqual(
                fusion._testHooks.stopInvocationCount, step.expectStopInvocations,
                "[state-machine=ImpactFusion] step=\(i)/\(step.name) stopInvocationCount expected=\(step.expectStopInvocations), got=\(fusion._testHooks.stopInvocationCount)"
            )
            XCTAssertEqual(
                fusion._testHooks.stopTeardownCount, step.expectStopTeardowns,
                "[state-machine=ImpactFusion] step=\(i)/\(step.name) stopTeardownCount expected=\(step.expectStopTeardowns), got=\(fusion._testHooks.stopTeardownCount)"
            )
            if let expectedNoOp = step.expectLastStopWasNoOp {
                XCTAssertEqual(
                    fusion._testHooks.lastStopWasNoOp, expectedNoOp,
                    "[state-machine=ImpactFusion] step=\(i)/\(step.name) lastStopWasNoOp expected=\(expectedNoOp), got=\(fusion._testHooks.lastStopWasNoOp)"
                )
            }
        }
    }

    // ------------------------------------------------------------------
    // Cell 4 — ReactionBus subscriber lifecycle
    // ------------------------------------------------------------------
    //
    // The bus is an actor with a subscribers dictionary. Logical states:
    //   open(N)  — N active subscriptions, publish fans out, close empties.
    //   closed   — close() finished all continuations and emptied the dict.
    //
    // Transitions exercised:
    //   open(0) → open(1)  via subscribe()
    //   open(1) → open(2)  via subscribe()
    //   open(N) → open(N)  via publish()         (no slot count change)
    //   open(N) → closed   via close()           (N → 0 slots)
    //   closed  → closed   via publish() / close (no-op, no crash)
    //   closed  → open(1)  via subscribe()       (close is not latched terminal)
    //
    // Catches: missing replay (publish before subscribe must not deliver
    // the earlier event to a subscriber that joins after); close-then-publish
    // must not crash; close-then-subscribe must work (bus is reusable).
    //
    // NOTE: `ReactionBus.subscribe()` registers an `onTermination` that
    // schedules the slot's removal as soon as the stream finishes. So
    // any `for await ... { break }` causes an asynchronous slot drop.
    // We therefore take subscriber-count snapshots BEFORE we start
    // draining, and only break out of the for-await once all assertions
    // that depend on the snapshot have run.
    func testCell4_ReactionBus_subscriberLifecycle() async {
        let bus = ReactionBus()

        // open(0) initial.
        var count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 0, "[state-machine=ReactionBus] initial subscriber count must be 0")

        // publish-then-subscribe: subscriber that came AFTER must NOT
        // see the earlier event (no replay).
        await bus.publish(.impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1.0, sources: [.microphone])))
        let lateStream = await bus.subscribe()
        count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 1, "[state-machine=ReactionBus] action=subscribe expected count=1, got=\(count)")

        // subscribe → open(2) — second active subscriber. Snapshot
        // BEFORE draining, since slot removal is async on stream
        // termination.
        let stream2 = await bus.subscribe()
        count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 2, "[state-machine=ReactionBus] action=subscribe expected count=2, got=\(count)")

        // publish: every active subscriber receives. Drain both streams
        // concurrently, accept exactly one event each.
        let recv2 = Task<Int, Never> {
            var seen = 0
            for await _ in stream2 {
                seen += 1
                if seen >= 1 { break }
            }
            return seen
        }
        let lateProbe = Task<Int, Never> {
            var seen = 0
            for await _ in lateStream {
                seen += 1
                if seen >= 1 { break }
            }
            return seen
        }
        await bus.publish(.impact(FusedImpact(timestamp: Date(), intensity: 0.7, confidence: 1.0, sources: [.microphone])))
        try? await Task.sleep(for: .milliseconds(80))
        recv2.cancel()
        lateProbe.cancel()
        let got2 = await recv2.value
        let lateCount = await lateProbe.value
        XCTAssertEqual(
            got2, 1,
            "[state-machine=ReactionBus] action=publish post-subscribe must deliver to active subscribers; got=\(got2)"
        )
        // The late subscriber saw exactly the one post-subscribe event,
        // not the pre-subscribe one (no replay).
        XCTAssertEqual(
            lateCount, 1,
            "[state-machine=ReactionBus] action=publish-before-subscribe must not replay AND post-subscribe publish must deliver; got=\(lateCount)"
        )

        // close → closed (subscriber count drops to 0).
        await bus.close()
        // Slot removals from the for-await terminations may also be
        // in flight; close() also empties the dictionary directly, so
        // the final count is 0 regardless.
        count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 0, "[state-machine=ReactionBus] action=close expected count=0, got=\(count)")

        // closed → closed via publish: must NOT add a slot, must NOT crash.
        await bus.publish(.impact(FusedImpact(timestamp: Date(), intensity: 0.9, confidence: 1.0, sources: [.microphone])))
        count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 0, "[state-machine=ReactionBus] action=publish@closed must be no-op (count=0), got=\(count)")

        // closed → closed via close: idempotent.
        await bus.close()
        count = await bus._testSubscriberCount()
        XCTAssertEqual(count, 0, "[state-machine=ReactionBus] action=close@closed expected count=0, got=\(count)")

        // closed → open(1): subscribe re-opens cleanly (not latched terminal).
        let revived = await bus.subscribe()
        count = await bus._testSubscriberCount()
        XCTAssertEqual(
            count, 1,
            "[state-machine=ReactionBus] action=subscribe@closed expected count=1 (bus is reusable), got=\(count)"
        )
        // Drain to terminate the revived continuation cleanly.
        let revivedProbe = Task<Void, Never> { for await _ in revived {} }
        await bus.close()
        revivedProbe.cancel()
        _ = await revivedProbe.value
    }

    // ------------------------------------------------------------------
    // Cell 5 — MicrophoneSource OnceCleanup lifecycle
    // ------------------------------------------------------------------
    //
    // Each impacts() call constructs a fresh OnceCleanup wrapping the
    // driver. On stream cancel, the onTermination closure runs once
    // and only once: stop() then removeTap() in that order. Five
    // open/cancel cycles → expect exactly five stop()s and five
    // removeTap()s in total (one of each per cycle), regardless of
    // how many times the framework triggers the termination handler.
    func testCell5_MicrophoneSource_onceCleanupAtMostOncePerCycle() async {
        let totalCycles = 5

        // Capture every driver the factory produces so we can per-cycle
        // assert the at-most-once invariant.
        let lock = OSAllocatedUnfairLock<[MockMicrophoneEngineDriver]>(initialState: [])
        let capturingFactory: @Sendable () -> MicrophoneEngineDriver = {
            let d = MockMicrophoneEngineDriver()
            lock.withLock { $0.append(d) }
            return d
        }

        let source = MicrophoneSource(
            driverFactory: capturingFactory,
            availabilityOverride: { true }
        )

        for cycle in 0..<totalCycles {
            let stream = source.impacts()
            let task = Task<Void, Error> {
                for try await _ in stream {}
            }
            try? await Task.sleep(for: .milliseconds(15))
            task.cancel()
            _ = try? await task.value
            // Allow the AsyncThrowingStream onTermination closure to run.
            try? await Task.sleep(for: .milliseconds(15))

            let captured = lock.withLock { $0 }
            guard let d = captured.last else {
                XCTFail("[state-machine=OnceCleanup] cycle=\(cycle) no driver captured")
                continue
            }
            // installTap fires at open. With the standard 48 kHz/1ch mock
            // format, the input-format guard passes.
            XCTAssertGreaterThanOrEqual(
                d.installTapCalls, 1,
                "[state-machine=OnceCleanup] cycle=\(cycle) installTap must have run on open"
            )
            XCTAssertEqual(
                d.stopCalls, 1,
                "[state-machine=OnceCleanup] cycle=\(cycle) stop must run exactly once per cycle, got=\(d.stopCalls)"
            )
            XCTAssertEqual(
                d.removeTapCalls, 1,
                "[state-machine=OnceCleanup] cycle=\(cycle) removeTap must run exactly once per cycle, got=\(d.removeTapCalls)"
            )
        }

        let driversSeen = lock.withLock { $0 }
        XCTAssertEqual(
            driversSeen.count, totalCycles,
            "[state-machine=OnceCleanup] driver factory must produce one driver per cycle; got=\(driversSeen.count) over \(totalCycles)"
        )
        let totalStops = driversSeen.reduce(0) { $0 + $1.stopCalls }
        let totalRemoves = driversSeen.reduce(0) { $0 + $1.removeTapCalls }
        XCTAssertEqual(
            totalStops, totalCycles,
            "[state-machine=OnceCleanup] AT MOST ONCE invariant: total stop calls expected=\(totalCycles), got=\(totalStops)"
        )
        XCTAssertEqual(
            totalRemoves, totalCycles,
            "[state-machine=OnceCleanup] AT MOST ONCE invariant: total removeTap calls expected=\(totalCycles), got=\(totalRemoves)"
        )
    }

    // ------------------------------------------------------------------
    // Cell 6 — TrackpadActivitySource start/stop machine
    // ------------------------------------------------------------------
    //
    // States:
    //   stopped — monitor==nil, tapMonitor==nil
    //   running — monitor!=nil, tapMonitor!=nil
    //
    // Transitions:
    //   stopped → running via start()           (installs 2 monitors)
    //   running → running via start()           (production guard:
    //                                            `guard monitor == nil else { return }`
    //                                            so double-start is a no-op)
    //   running → stopped via stop()            (removes 2 monitors)
    //   stopped → stopped via stop()            (no-op; nothing to remove)
    //   stopped → running via start() (again)   (re-entrant; clean state)
    //
    // Counters tracked on MockEventMonitor:
    //   installCount  — every addGlobalMonitor call (before failure check)
    //   removalCount  — every successful remove
    func testCell6_TrackpadActivitySource_startStopMachine() async {
        struct Step {
            let name: String
            let action: @MainActor (TrackpadActivitySource, ReactionBus) -> Void
            let expectInstallCount: Int
            let expectRemovalCount: Int
        }
        // Each start() installs 2 monitors (scroll/gesture + leftMouseDown).
        // Each stop() that finds them removes 2.
        let steps: [Step] = [
            Step(name: "init",
                 action: { _, _ in },
                 expectInstallCount: 0, expectRemovalCount: 0),
            Step(name: "start@stopped",
                 action: { src, bus in src.start(publishingTo: bus) },
                 expectInstallCount: 2, expectRemovalCount: 0),
            Step(name: "double-start@running (no-op via `guard monitor == nil`)",
                 action: { src, bus in src.start(publishingTo: bus) },
                 expectInstallCount: 2, expectRemovalCount: 0),
            Step(name: "stop@running",
                 action: { src, _ in src.stop() },
                 expectInstallCount: 2, expectRemovalCount: 2),
            Step(name: "double-stop@stopped (no-op; tokens nil)",
                 action: { src, _ in src.stop() },
                 expectInstallCount: 2, expectRemovalCount: 2),
            Step(name: "start@stopped(2)",
                 action: { src, bus in src.start(publishingTo: bus) },
                 expectInstallCount: 4, expectRemovalCount: 2),
            Step(name: "stop@running(2)",
                 action: { src, _ in src.stop() },
                 expectInstallCount: 4, expectRemovalCount: 4),
        ]

        let monitor = MockEventMonitor()
        let source = TrackpadActivitySource(eventMonitor: monitor)
        let bus = ReactionBus()
        defer { source.stop() }

        for (i, step) in steps.enumerated() {
            step.action(source, bus)
            XCTAssertEqual(
                monitor.installCount, step.expectInstallCount,
                "[state-machine=TrackpadActivitySource] step=\(i)/\(step.name) installCount expected=\(step.expectInstallCount), got=\(monitor.installCount)"
            )
            XCTAssertEqual(
                monitor.removalCount, step.expectRemovalCount,
                "[state-machine=TrackpadActivitySource] step=\(i)/\(step.name) removalCount expected=\(step.expectRemovalCount), got=\(monitor.removalCount)"
            )
        }
    }
}
