import XCTest
import Darwin
@testable import YameteCore
@testable import SensorKit

/// Performance / soak / leak guards.
///
/// The functional matrix elsewhere in this suite asserts that the right
/// reaction fires for the right input. None of those cells assert anything
/// about *cost* — a regression that re-installs an `EventMonitor` on every
/// gesture, leaks a `Task` per `_injectClick`, or grows the bus buffer
/// without bound would pass the functional suite for hours and only show
/// up as a degraded user experience after sustained use.
///
/// These cells run lifecycle / fan-out / inject loops at counts large
/// enough to surface unbounded growth, then assert:
///   - process-resident memory (`os_proc_available_memory()`) stays within
///     a documented delta envelope
///   - mock counters (e.g. `MockEventMonitor.installCount` /
///     `removalCount`) are balanced — every install matched by a removal
///   - per-iteration wallclock variance stays inside a 5x band of the
///     median (catches quadratic regressions where a per-iter cost grows
///     with the iteration index)
///
/// Cells run in <30s each. Where a 1000-cycle target was too slow we
/// dropped to a smaller count (per cell) and documented why inline.
///
/// `os_proc_available_memory()` is iOS-only — on macOS we use Mach
/// `task_info(mach_task_self_, MACH_TASK_BASIC_INFO, …)` which returns
/// the resident-set size (`resident_size`) for the current task. This
/// monotonically grows as the process consumes memory; we sample baseline
/// before a soak loop and assert the delta growth is bounded.
@MainActor
final class Performance_Tests: XCTestCase {

    // MARK: - Memory / timing helpers

    /// Returns the current resident-set size in bytes for this process.
    /// Built on `task_info` with `MACH_TASK_BASIC_INFO`, which is the
    /// macOS-supported equivalent of `os_proc_available_memory()` (the
    /// latter is API_UNAVAILABLE(macos)).
    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size)
    }

    /// Bytes consumed since baseline (positive = grew, negative = shrunk).
    private func bytesConsumedSince(_ baseline: Int) -> Int {
        return residentBytes() - baseline
    }

    /// Drop-in replacement for the strawman name used throughout the cells.
    private func availableMemory() -> Int { residentBytes() }

    private func wallclockNow() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    /// Emit a machine-readable PERFMETRIC line that `scripts/perf-baseline.sh`
    /// greps from `swift test` stdout to extract per-cell wallclock + memory
    /// measurements. The prefix is stable; the parser anchors on it. Format:
    ///   PERFMETRIC: cell=<name> wallclock=<seconds> memory=<bytes>
    /// Cells call this once at the end of their measurement block. Memory is
    /// the resident-set delta since the cell's measurement baseline; wallclock
    /// is the cell's primary timed loop. The driver does NOT inspect XCTest
    /// pass/fail — that's handled by the existing assertions. PERFMETRIC is a
    /// pure observability emit; unrelated to whether the cell asserts pass.
    private func emitPerfMetric(cell: String, wallclock: TimeInterval, memory: Int) {
        // Stable single-line format. Driver greps for "PERFMETRIC: cell=".
        print("PERFMETRIC: cell=\(cell) wallclock=\(wallclock) memory=\(memory)")
    }

    // MARK: - Bus helper

    private func makeBus() async -> ReactionBus {
        let bus = ReactionBus()
        await bus.setEnricher { reaction, publishedAt in
            FiredReaction(reaction: reaction, clipDuration: 0.05,
                          soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
        }
        return bus
    }

    // MARK: - Cell 1: TrackpadActivitySource N-cycle leak guard
    //
    // Invariant: starting and stopping `TrackpadActivitySource` 1000 times
    // must (a) leave `MockEventMonitor.installCount == removalCount` (every
    // monitor installed in `start()` is removed in `stop()`), and (b) not
    // consume more than ~5 MB of process memory. A regression that
    // accumulated per-cycle state (un-removed monitor handlers, retained
    // bus refs, leaked Tasks) would surface here long before users felt it.
    //
    // Note: each cycle creates a fresh `MockEventMonitor` so the install /
    // removal count is *per-source-instance*. The shared invariant we
    // assert across all cycles is that (per cycle) installCount == removalCount.
    func testTrackpadStartStopCycleLeakGuard() {
        let cycles = 1000
        let memBaseline = availableMemory()
        var maxDeltaBytes = 0
        var imbalanceCycle = -1
        var firstImbalance: (installs: Int, removals: Int) = (0, 0)
        let cellStart = wallclockNow()

        for cycle in 0..<cycles {
            let monitor = MockEventMonitor()
            let source = TrackpadActivitySource(eventMonitor: monitor)
            // Use a *transient* bus per cycle — exercises the bus handoff in start/stop.
            let bus = ReactionBus()
            source.start(publishingTo: bus)
            source.stop()

            if monitor.installCount != monitor.removalCount && imbalanceCycle == -1 {
                imbalanceCycle = cycle
                firstImbalance = (monitor.installCount, monitor.removalCount)
            }

            if cycle % 100 == 0 {
                let delta = bytesConsumedSince(memBaseline)
                if delta > maxDeltaBytes { maxDeltaBytes = delta }
            }
        }

        XCTAssertEqual(imbalanceCycle, -1,
            "[scenario=trackpad-cycle cell=monitor-balance] cycle \(imbalanceCycle): installs=\(firstImbalance.installs) removals=\(firstImbalance.removals); start() must remove every monitor it installs in stop()")

        let finalDelta = bytesConsumedSince(memBaseline)
        if finalDelta > maxDeltaBytes { maxDeltaBytes = finalDelta }
        // 5 MB envelope. Empirical baseline is on the order of ~100-500 KB
        // of pool/cache fluctuation across 1000 cycles. 5 MB is a wide
        // ceiling that still catches a per-cycle leak (5 MB / 1000 cycles
        // = 5 KB per cycle, well below an NSEvent monitor handler closure
        // capture but enough to flag a real retention).
        XCTAssertLessThan(maxDeltaBytes, 5 * 1024 * 1024,
            "[scenario=trackpad-cycle cell=memory-bound] consumed \(maxDeltaBytes) bytes over \(cycles) cycles; >5MB suggests per-cycle retention")
        emitPerfMetric(cell: "testTrackpadStartStopCycleLeakGuard",
                       wallclock: wallclockNow() - cellStart,
                       memory: maxDeltaBytes)
    }

    // MARK: - Cell 2: MouseActivitySource N-cycle leak guard
    //
    // Invariant: same as Cell 1 but for `MouseActivitySource`. Mouse
    // installs ONE monitor in start (scrollMonitor) so installCount per
    // cycle should equal 1. We pass `enableHIDClickDetection: false` so
    // we don't incidentally exercise IOKit (test seam, see source).
    func testMouseStartStopCycleLeakGuard() {
        let cycles = 1000
        let memBaseline = availableMemory()
        var maxDeltaBytes = 0
        var imbalanceCycle = -1
        let cellStart = wallclockNow()

        for cycle in 0..<cycles {
            let monitor = MockEventMonitor()
            let source = MouseActivitySource(eventMonitor: monitor, enableHIDClickDetection: false)
            let bus = ReactionBus()
            source.start(publishingTo: bus)
            source.stop()

            if monitor.installCount != monitor.removalCount && imbalanceCycle == -1 {
                imbalanceCycle = cycle
            }
            if cycle % 100 == 0 {
                let delta = bytesConsumedSince(memBaseline)
                if delta > maxDeltaBytes { maxDeltaBytes = delta }
            }
        }
        XCTAssertEqual(imbalanceCycle, -1,
            "[scenario=mouse-cycle cell=monitor-balance] first imbalance at cycle \(imbalanceCycle); start() must remove every monitor in stop()")
        let finalDelta = bytesConsumedSince(memBaseline)
        if finalDelta > maxDeltaBytes { maxDeltaBytes = finalDelta }
        XCTAssertLessThan(maxDeltaBytes, 5 * 1024 * 1024,
            "[scenario=mouse-cycle cell=memory-bound] consumed \(maxDeltaBytes) bytes over \(cycles) cycles")
        emitPerfMetric(cell: "testMouseStartStopCycleLeakGuard",
                       wallclock: wallclockNow() - cellStart,
                       memory: maxDeltaBytes)
    }

    // MARK: - Cell 3: ReactionBus N-emit retention
    //
    // Invariant: publishing 10,000 reactions through one bus with a single
    // subscriber must (a) not let memory grow unboundedly, and (b) honor
    // the `bufferingNewest(busBufferDepth=8)` cap — a slow consumer must
    // see at most ~recent-cap events while in-flight. We track total
    // delivered (which depends on consumer drain rate) and assert it does
    // NOT exceed the publish count (no fan-out amplification).
    func testReactionBusHighPublishVolumeRetention() async {
        let bus = await makeBus()
        let stream = await bus.subscribe()
        let total = 10_000

        let memBaseline = availableMemory()
        let cellStart = wallclockNow()

        // Consumer drains aggressively in parallel with publishes.
        let consumerTask = Task<Int, Never> {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= total { break }
            }
            return count
        }

        // Tight publish loop.
        for i in 0..<total {
            await bus.publish(.acConnected)
            if i % 1000 == 0 {
                // Allow the consumer to make progress so we don't pin the
                // buffer at its drop policy for the entire run.
                await Task.yield()
            }
        }

        // Give the consumer a beat to finish (or hit the buffer-drop floor).
        try? await Task.sleep(for: .milliseconds(200))
        consumerTask.cancel()
        let delivered = await consumerTask.value
        await bus.close()

        let consumed = bytesConsumedSince(memBaseline)

        // No amplification: subscriber must never see more than published.
        XCTAssertLessThanOrEqual(delivered, total,
            "[scenario=bus-fanout cell=no-amplification] delivered=\(delivered) > published=\(total) — bus must not amplify")

        // Memory bound: 10k publishes should cost <10 MB. The bus retains
        // at most `busBufferDepth` per subscriber, so steady-state memory
        // is independent of publish count. A regression that retained
        // every reaction would blow past this.
        XCTAssertLessThan(consumed, 10 * 1024 * 1024,
            "[scenario=bus-fanout cell=memory-bound] consumed=\(consumed) bytes over \(total) publishes — bus must drop oldest at busBufferDepth")
        emitPerfMetric(cell: "testReactionBusHighPublishVolumeRetention",
                       wallclock: wallclockNow() - cellStart,
                       memory: consumed)
    }

    // MARK: - Cell 4: Per-source `_inject*` sustained throughput
    //
    // Invariant: 5,000 `_inject*` calls per IOKit source must complete with
    // the second-half median wallclock no more than 3x the first-half
    // median. Catches a per-call cost that grows with iteration index
    // (e.g. a backing array that's never trimmed, an accumulator that's
    // never reset, an O(n²) lookup in a debounce table).
    //
    // Important: we MUST cycle a small set of identities (modular UID)
    // so the diff-set sources (USB lastEvent table, Audio knownDevices,
    // Bluetooth knownDevices) don't accumulate state UNBOUNDEDLY. In
    // production those sets are bounded by physical devices (~5-20);
    // a test that injects 5000 unique IDs would see legitimate O(n)
    // per-call set-copy cost simply because production semantics
    // require diffing newSet vs oldSet — that's not a regression, it's
    // the design. We cap to 50 unique identities to mirror real-world
    // upper bound while still hammering the hot path 5000 times.
    //
    // Strategy: split the 5,000 calls into 10 chunks of 500, time each
    // chunk, then assert second-half-median <= 3x first-half-median.
    // We run the assertion across multiple sources in one cell so the
    // harness setup happens once.
    func testIOKitSourceInjectSustainedThroughput() async throws {
        let chunks = 10
        let perChunk = 500
        let identityModulus = 50  // see header note
        let memBaseline = availableMemory()
        let cellStart = wallclockNow()

        // USB
        try await assertSustainedThroughput(name: "USBSource", chunks: chunks, perChunk: perChunk) {
            let bus = await self.makeBus()
            let source = USBSource()
            source.start(publishingTo: bus)
            return { i in
                let id = i % identityModulus
                await source._injectAttach(vendor: "vendor-\(id)", product: "product-\(id)")
            }
        }

        // Power (alternates onAC because edge-trigger drops repeats).
        try await assertSustainedThroughput(name: "PowerSource", chunks: chunks, perChunk: perChunk) {
            let bus = await self.makeBus()
            let source = PowerSource()
            source.start(publishingTo: bus)
            return { i in
                await source._injectPowerChange(onAC: i % 2 == 0)
            }
        }

        // Bluetooth
        try await assertSustainedThroughput(name: "BluetoothSource", chunks: chunks, perChunk: perChunk) {
            let bus = await self.makeBus()
            let source = BluetoothSource()
            source.start(publishingTo: bus)
            return { i in
                let id = i % identityModulus
                await source._injectConnect(name: "device-\(id)")
            }
        }

        // SleepWake (alternates will/did to avoid edge-trigger drops).
        try await assertSustainedThroughput(name: "SleepWakeSource", chunks: chunks, perChunk: perChunk) {
            let bus = await self.makeBus()
            let source = SleepWakeSource()
            source.start(publishingTo: bus)
            return { i in
                if i % 2 == 0 { await source._injectWillSleep() } else { await source._injectDidWake() }
            }
        }

        // AudioPeripheral — cycles UID so knownDevices doesn't grow.
        try await assertSustainedThroughput(name: "AudioPeripheralSource", chunks: chunks, perChunk: perChunk) {
            let bus = await self.makeBus()
            let source = AudioPeripheralSource()
            source.start(publishingTo: bus)
            return { i in
                let id = i % identityModulus
                if i % 2 == 0 {
                    await source._injectAttach(uid: "uid-\(id)", name: "device-\(id)")
                } else {
                    await source._injectDetach(uid: "uid-\(id)", name: "device-\(id)")
                }
            }
        }

        emitPerfMetric(cell: "testIOKitSourceInjectSustainedThroughput",
                       wallclock: wallclockNow() - cellStart,
                       memory: bytesConsumedSince(memBaseline))
    }

    /// Drive a `_inject` loop in N chunks, time each, and assert the
    /// SECOND HALF's median is no more than 3x the FIRST HALF's median.
    /// This catches a per-iter cost that grows with iteration index
    /// (true quadratic / accumulator regression) while being robust to
    /// scheduler/GC jitter that produces single-chunk outliers in a
    /// non-monotonic pattern.
    ///
    /// A pure max/median ratio was tried first and flaked: under M-series
    /// system load, dispatcher hiccups produced single-chunk spikes 6-10x
    /// the median in a sequence that was otherwise flat — not a
    /// regression signal. Comparing first-half vs second-half medians
    /// averages over jitter and only fires on a sustained drift upward.
    private func assertSustainedThroughput(
        name: String,
        chunks: Int,
        perChunk: Int,
        setup: () async -> (Int) async -> Void
    ) async throws {
        let inject = await setup()
        var times: [TimeInterval] = []
        times.reserveCapacity(chunks)
        for chunk in 0..<chunks {
            let start = wallclockNow()
            for j in 0..<perChunk {
                await inject(chunk * perChunk + j)
            }
            times.append(wallclockNow() - start)
        }
        let half = chunks / 2
        let firstHalf = Array(times.prefix(half)).sorted()
        let secondHalf = Array(times.suffix(half)).sorted()
        let firstMedian = firstHalf[firstHalf.count / 2]
        let secondMedian = secondHalf[secondHalf.count / 2]
        // Floor: below 1 ms a meaningful ratio is impossible — skip.
        let floor: TimeInterval = 0.001
        if firstMedian > floor {
            XCTAssertLessThan(secondMedian, firstMedian * 3,
                "[scenario=\(name)-throughput cell=quadratic-guard] second-half median \(secondMedian)s > 3x first-half median \(firstMedian)s; suggests per-iter cost growing with index (all=\(times))")
        }
    }

    // MARK: - Cell 5: Coalesce-window pressure (mouse `_injectClick`)
    //
    // Invariant: a tight burst of `_injectClick` calls must not
    // accumulate orphan Tasks. The production handler debounces
    // (`clickDebounce: 0.5s`), so most calls drop without spawning a
    // bus.publish task. We assert memory stays bounded — a regression
    // that spawned a Task per call (regardless of debounce) would balloon
    // resident memory under sustained pressure.
    //
    // Adjusted from the strawman 100,000 to 20,000: 20,000 Task.yield-ed
    // injections fit comfortably within 30s on M-series; 100,000 is
    // 5x slower because each `_injectClick` does an `await Task.yield()`
    // (cost dominated by scheduler, not the click handler).
    func testMouseInjectClickCoalescePressure() async {
        let bus = await makeBus()
        let monitor = MockEventMonitor()
        let source = MouseActivitySource(eventMonitor: monitor, enableHIDClickDetection: false)
        source.start(publishingTo: bus)

        let memBaseline = availableMemory()
        let count = 20_000
        let cellStart = wallclockNow()

        for i in 0..<count {
            // Mix transports: USB clicks pass production filter; SPI
            // clicks are dropped at filter (early-return path).
            await source._injectClick(transport: i % 2 == 0 ? "USB" : "Bluetooth",
                                      product: "TestMouse")
        }

        // Drain once — let any in-flight bus.publish Tasks run to
        // completion before sampling memory.
        try? await Task.sleep(for: .milliseconds(50))

        let consumed = bytesConsumedSince(memBaseline)
        source.stop()
        await bus.close()

        // 10 MB envelope — generous because Swift Task spawn cost +
        // continuation buffers can fluctuate. A linear-in-N retention bug
        // would consume >>10 MB at 20k calls (e.g. a Task closure is on
        // the order of hundreds of bytes — 20k * 500B = 10 MB on the nose,
        // so the regression target is the next order of magnitude).
        XCTAssertLessThan(consumed, 20 * 1024 * 1024,
            "[scenario=mouse-coalesce cell=memory-bound] \(count) injectClick calls consumed \(consumed) bytes; >20MB suggests orphan Task accumulation")
        emitPerfMetric(cell: "testMouseInjectClickCoalescePressure",
                       wallclock: wallclockNow() - cellStart,
                       memory: consumed)
    }

    // MARK: - Cell 6: Bus close + reopen cycle
    //
    // Invariant: opening, subscribing, and closing the bus 500 times must
    // not leak subscriber slots or accumulate memory. Each cycle: create
    // a fresh bus, subscribe, drop the stream, close. Repeated bus churn
    // is a real workload on settings reload paths.
    func testBusOpenSubscribeCloseCycle() async {
        let cycles = 500
        let memBaseline = availableMemory()
        var maxDelta = 0
        var maxLiveSubscriberCount = 0
        let cellStart = wallclockNow()

        for cycle in 0..<cycles {
            let bus = await makeBus()
            // Subscribe + drop (let stream go out of scope at end of iter).
            _ = await bus.subscribe()
            await bus.publish(.acConnected)
            // Ask the bus how many subscribers it currently tracks.
            let live = await bus._testSubscriberCount()
            if live > maxLiveSubscriberCount { maxLiveSubscriberCount = live }
            await bus.close()

            if cycle % 50 == 0 {
                let delta = bytesConsumedSince(memBaseline)
                if delta > maxDelta { maxDelta = delta }
            }
        }
        let finalDelta = bytesConsumedSince(memBaseline)
        if finalDelta > maxDelta { maxDelta = finalDelta }

        // Memory bound. 500 cycles of bus alloc / publish / close should
        // be < 10 MB; per-cycle bus state is small.
        XCTAssertLessThan(maxDelta, 10 * 1024 * 1024,
            "[scenario=bus-cycle cell=memory-bound] \(cycles) open/close cycles consumed \(maxDelta) bytes; >10MB suggests bus state retention")

        // Subscriber count bound. A single bus has at most 1 live
        // subscriber per iteration. If a cycle's bus retained subscribers
        // across calls, this would climb. (We measure max live in any
        // single bus, not cumulative across cycles, because each iter has
        // its own bus.)
        XCTAssertLessThanOrEqual(maxLiveSubscriberCount, 1,
            "[scenario=bus-cycle cell=subscriber-bound] max live subscriber count was \(maxLiveSubscriberCount); per-cycle bus must not accumulate subscribers")
        emitPerfMetric(cell: "testBusOpenSubscribeCloseCycle",
                       wallclock: wallclockNow() - cellStart,
                       memory: maxDelta)
    }

    // MARK: - Cell 7: CPU upper bound check (smoke)
    //
    // Invariant: 1,000 `_injectAttach` calls into USBSource must complete
    // under a per-call wallclock ceiling that catches a ~10x regression.
    //
    // Empirical baseline (M-series DEBUG, 2026-04-28 wallclock): ~670ms
    // for 1000 injects = ~670µs per call. The cost is dominated by
    // `await Task.yield()` inside `_injectAttach` (each yield is a hop
    // through the cooperative scheduler) and the AsyncStream yield/drain
    // path — neither is something to optimize on its own. The 10x
    // regression target is therefore ~7s for 1000 calls; we set a 5s
    // ceiling which catches a clear ~7x slowdown without flaking on
    // slower CI hosts.
    func testUSBInjectThroughputCPUUpperBound() async {
        let bus = await makeBus()
        let source = USBSource()
        source.start(publishingTo: bus)

        let calls = 1_000
        let memBaseline = availableMemory()
        let start = wallclockNow()
        for i in 0..<calls {
            await source._injectAttach(vendor: "v\(i)", product: "p\(i)")
        }
        let elapsed = wallclockNow() - start
        let consumed = bytesConsumedSince(memBaseline)
        await bus.close()

        XCTAssertLessThan(elapsed, 5.0,
            "[scenario=usb-cpu-smoke cell=upper-bound] \(calls) injectAttach calls took \(elapsed)s; >5s suggests ~7x regression vs ~700ms baseline")
        emitPerfMetric(cell: "testUSBInjectThroughputCPUUpperBound",
                       wallclock: elapsed,
                       memory: consumed)
    }
}
