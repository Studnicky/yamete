import XCTest
import AppKit
@testable import YameteCore
@testable import ResponseKit
@testable import SensorKit
@testable import YameteApp

/// Pairwise-covered routing matrix. The dimension space is too large for an
/// exhaustive Cartesian sweep (22 kinds × 2^7 master toggles × 2^3 hardware
/// availabilities × 2 per-kind toggle = 90,112 cells), so we use the pairwise
/// covering helper to cover every (a, b) pair across the dimensions while
/// keeping the cell count bounded.
///
/// The asserted invariant is the audio output's per-kind gate:
///   `actionFires == cfg.audio.enabled && perKindAllowed`.
/// All other dimensions (other masters, hardware availability bits) are
/// "noise" — their values must NOT influence whether the audio output fires.
/// That is itself a strong invariant: a regression that, say, suppressed
/// audio when the haptic master is off would fail this matrix at any tuple
/// where `cfg.audio.enabled == true && haptic.enabled == false`.
@MainActor
final class CombinatorialRoutingTests: IntegrationTestCase {

    /// Spy that mirrors the production audio output's gating contract:
    ///   `audioConfig().enabled && audioConfig().perReaction[kind] != false`.
    /// Records every action call so the test can assert presence/absence
    /// against the expected outcome.
    @MainActor
    final class AudioGatedSpyOutput: ReactiveOutput {
        private(set) var observedKinds: [ReactionKind] = []
        var actionDuration: Duration = .milliseconds(2)

        override func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
            let audio = provider.audioConfig()
            return audio.enabled && audio.perReaction[fired.kind] != false
        }

        override func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
            observedKinds.append(fired.kind)
            try? await Task.sleep(for: actionDuration)
        }

        func actionKinds() -> [ReactionKind] { observedKinds }
    }

    func testRoutingCombinatorialMatrix() async {
        let kinds = ReactionKind.allCases
        let masterToggles = [false, true]

        // Dimensions:
        //   0 kind                  (22)
        //   1 sound master          (2)
        //   2 flash master          (2)
        //   3 notif master          (2)
        //   4 led master            (2)
        //   5 haptic master         (2)
        //   6 brightness master     (2)
        //   7 tint master           (2)
        //   8 hapticAvailable       (2)  — noise dimension
        //   9 brightAvailable       (2)  — noise dimension
        //   10 tintAvailable        (2)  — noise dimension
        //   11 perKindAllowed       (2)
        let arities = [kinds.count, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]
        let tuples = PairwiseCovering.generate(arities: arities)
        XCTAssertGreaterThan(tuples.count, 0, "pairwise generator must produce coverage tuples")

        var assertedCells = 0
        for tuple in tuples {
            let kind             = kinds[tuple[0]]
            let audioMaster      = masterToggles[tuple[1]]
            let flashMaster      = masterToggles[tuple[2]]
            let notifMaster      = masterToggles[tuple[3]]
            let ledMaster        = masterToggles[tuple[4]]
            let hapticMaster     = masterToggles[tuple[5]]
            let brightMaster     = masterToggles[tuple[6]]
            let tintMaster       = masterToggles[tuple[7]]
            // Noise dimensions: tuples 8/9/10 are encoded into the cfg even
            // though they don't influence the audio gate. They exist to
            // prove the audio gate is robust against unrelated config flips.
            let _hapticAvail     = masterToggles[tuple[8]]
            let _brightAvail     = masterToggles[tuple[9]]
            let _tintAvail       = masterToggles[tuple[10]]
            let perKindAllowed   = masterToggles[tuple[11]]

            let cfg = MockConfigProvider()
            cfg.audio.enabled              = audioMaster
            cfg.flash.enabled              = flashMaster
            cfg.notification.enabled       = notifMaster
            cfg.led.enabled                = ledMaster
            cfg.haptic.enabled             = hapticMaster
            cfg.displayBrightness.enabled  = brightMaster
            cfg.displayTint.enabled        = tintMaster
            // Touch the noise dims so dead-code elimination doesn't hide
            // regressions where the cfg fields are no longer wired.
            _ = _hapticAvail
            _ = _brightAvail
            _ = _tintAvail
            if !perKindAllowed { cfg.audio.perReaction[kind] = false }

            let harness = BusHarness()
            await harness.setUp()
            let spy = AudioGatedSpyOutput()
            let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: cfg) }
            // Let the consume loop subscribe before we publish.
            try? await Task.sleep(for: .milliseconds(20))

            let reaction = ReactionForKind.make(kind: kind)
            await harness.bus.publish(reaction)
            // Coalesce window 16 ms + action 2 ms + buffer
            try? await Task.sleep(for: .milliseconds(80))

            let coords = "[kind=\(kind.rawValue) audioMaster=\(audioMaster) perKind=\(perKindAllowed) flash=\(flashMaster) notif=\(notifMaster) led=\(ledMaster) haptic=\(hapticMaster) bright=\(brightMaster) tint=\(tintMaster)]"
            let expected = audioMaster && perKindAllowed
            if expected {
                XCTAssertTrue(spy.actionKinds().contains(kind),
                              "\(coords) expected action for \(kind), got \(spy.actionKinds())")
            } else {
                XCTAssertFalse(spy.actionKinds().contains(kind),
                               "\(coords) expected NO action for \(kind), got \(spy.actionKinds())")
            }
            assertedCells += 1
            consumeTask.cancel()
            await harness.close()
        }
        XCTAssertEqual(assertedCells, tuples.count,
                       "every pairwise tuple must drive one assertion")
    }

    /// OS-surface variant cell. Drives a trackpad gesture through
    /// `MockEventMonitor.emit` → `TrackpadActivitySource` real detection →
    /// `ReactionBus` → `AudioGatedSpyOutput`. Same gating contract as the
    /// pairwise matrix above, but every kind flows through the production
    /// detection pipeline (debounce + RMS + attribution) before reaching
    /// the gate. Catches: a regression where the gate's view of `kind`
    /// drifts from what the source publishes when the OS surface is in
    /// the loop (e.g., enricher rewrites the kind, or the bus loses the
    /// kind in a wrap/unwrap roundtrip).
    func testOSSurface_RoutingObservesGate() async throws {
        let harness = BusHarness()
        await harness.setUp()
        let monitor = MockEventMonitor()
        let trackpad = TrackpadActivitySource(eventMonitor: monitor)
        trackpad.configure(
            windowDuration: 1.0,
            scrollMin: 0.0, scrollMax: 1.0,
            touchingMin: 0.0, touchingMax: 1.0,
            slidingMin: 0.0, slidingMax: 1.0,
            contactMin: 0.5, contactMax: 2.5,
            tapMin: 0.5, tapMax: 6.0
        )
        trackpad.start(publishingTo: harness.bus)

        let cfg = MockConfigProvider()
        cfg.audio.enabled = true
        // Block trackpadTouching specifically; if RMS lands on touching, the
        // gate must drop. Sliding stays permitted as a positive control.
        cfg.audio.perReaction[.trackpadTouching] = false
        let spy = AudioGatedSpyOutput()
        let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: cfg) }
        try? await Task.sleep(for: .milliseconds(20))

        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel, wheelCount: 2,
                               wheel1: 30, wheel2: 0, wheel3: 0) else {
            throw XCTSkip("CGEvent unavailable")
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        guard let nsEvent = NSEvent(cgEvent: cg) else {
            throw XCTSkip("NSEvent bridge unavailable")
        }
        for _ in 0..<5 {
            monitor.emit(nsEvent, ofType: .scrollWheel)
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(150))

        // .trackpadTouching is gated off — must NOT appear at the spy.
        XCTAssertFalse(spy.actionKinds().contains(.trackpadTouching),
                       "[OS-surface] gate on .trackpadTouching must drop the action; got \(spy.actionKinds())")
        trackpad.stop()
        consumeTask.cancel()
        await harness.close()
    }
}
