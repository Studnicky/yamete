import XCTest
import CoreGraphics
@testable import YameteCore
@testable import ResponseKit

/// Pairwise-covered lifecycle invariants for every driver-injected output.
///
/// For each output, drive `(input intensity × multiplier × prior driver state)`
/// through the full `preAction → action → postAction` trio and assert the
/// driver received the right calls in the right order. The single load-bearing
/// invariant we assert is the **restore guarantee**: after the lifecycle
/// completes the driver must observe the prior state, regardless of the
/// peak value reached during action.
@MainActor
final class CombinatorialOutputBoundaryTests: IntegrationTestCase {

    // MARK: - DisplayBrightnessFlash

    func testDisplayBrightnessBoundaryCombinatorial() async {
        let inputs:   [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        let multipliers: [Float] = [0.5, 1.0, 1.5]
        let priors:   [Float] = [0.0, 0.5, 1.0]
        let arities = [inputs.count, multipliers.count, priors.count]
        // Defensive filter — see comment in testDisplayTintBoundaryCombinatorial.
        let tuples = PairwiseCovering.generate(arities: arities).filter { $0.count == arities.count }
        XCTAssertGreaterThan(tuples.count, 0, "pairwise generator must produce coverage tuples")

        var assertedCells = 0
        for tuple in tuples {
            let intensity  = inputs[tuple[0]]
            let multiplier = multipliers[tuple[1]]
            let priorLevel = priors[tuple[2]]

            let mockDriver = MockDisplayBrightnessDriver()
            mockDriver.setAvailable(true)
            mockDriver.setCannedLevel(priorLevel)
            let flash = DisplayBrightnessFlash(driver: mockDriver)
            let cfg = MockConfigProvider()
            cfg.displayBrightness.enabled = true
            cfg.displayBrightness.boost = 0.5

            let fired = FiredReaction(
                reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity,
                                              confidence: 1.0, sources: [])),
                clipDuration: 0.05,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: Date())

            await flash.preAction(fired, multiplier: multiplier, provider: cfg)
            await flash.action(fired, multiplier: multiplier, provider: cfg)
            await flash.postAction(fired, multiplier: multiplier, provider: cfg)

            let coords = "[intensity=\(intensity) mult=\(multiplier) prior=\(priorLevel)]"
            guard let last = mockDriver.setHistory.last else {
                XCTFail("\(coords) no set() calls recorded")
                continue
            }
            XCTAssertEqual(last.level, priorLevel, accuracy: 0.001,
                "\(coords) restore must return to prior=\(priorLevel), got \(last.level)")
            assertedCells += 1
        }
        XCTAssertEqual(assertedCells, tuples.count,
                       "every pairwise tuple must drive one assertion")
    }

    // MARK: - DisplayTintFlash

    /// Invariant: postAction MUST call `restore(displayID:)` exactly once,
    /// regardless of input intensity / multiplier / availability.
    func testDisplayTintBoundaryCombinatorial() async {
        let inputs:   [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        let multipliers: [Float] = [0.5, 1.0, 1.5]
        let availables = [true, false]
        let arities = [inputs.count, multipliers.count, availables.count]
        // Defensive filter: the pairwise generator can emit short tuples on its
        // last extension pass when the final dim's arity is smaller than the
        // seed cross-product covers (a known greedy-IPO edge case). Drop
        // any tuple whose length does not match the dimension count so the
        // matrix below indexes safely.
        let tuples = PairwiseCovering.generate(arities: arities).filter { $0.count == arities.count }

        var assertedCells = 0
        for tuple in tuples {
            let intensity  = inputs[tuple[0]]
            let multiplier = multipliers[tuple[1]]
            let available  = availables[tuple[2]]

            let mockDriver = MockDisplayTintDriver()
            mockDriver.setAvailable(available)
            let tint = DisplayTintFlash(driver: mockDriver)
            let cfg = MockConfigProvider()
            cfg.displayTint.enabled = true

            let fired = FiredReaction(
                reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity,
                                              confidence: 1.0, sources: [])),
                clipDuration: 0.05,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: Date())

            await tint.preAction(fired, multiplier: multiplier, provider: cfg)
            await tint.action(fired, multiplier: multiplier, provider: cfg)
            await tint.postAction(fired, multiplier: multiplier, provider: cfg)

            let coords = "[intensity=\(intensity) mult=\(multiplier) avail=\(available)]"
            // Restore must always run. Gamma writes only happen when the driver
            // is available — but the restore call is unconditional (the
            // existing matrix asserts this in MatrixOutputBoundary_Tests).
            XCTAssertEqual(mockDriver.restoreHistory.count, 1,
                "\(coords) postAction must call restore exactly once, got \(mockDriver.restoreHistory.count)")
            if available {
                XCTAssertGreaterThan(mockDriver.applyGammaHistory.count, 0,
                    "\(coords) action must apply gamma when driver is available")
            } else {
                XCTAssertEqual(mockDriver.applyGammaHistory.count, 0,
                    "\(coords) no gamma writes when driver unavailable")
            }
            assertedCells += 1
        }
        XCTAssertEqual(assertedCells, tuples.count,
                       "every pairwise tuple must drive one assertion")
    }

    // MARK: - LEDFlash

    /// Invariant: postAction restores keyboard backlight to the level captured
    /// at preAction. We pin priorLevel ∈ {0.1, 0.5, 0.9} and verify the last
    /// `setLevel` write equals priorLevel.
    func testLEDFlashBoundaryCombinatorial() async {
        let inputs:   [Float] = [0.1, 0.5, 0.9]
        let multipliers: [Float] = [0.5, 1.0, 1.5]
        let priors:   [Float] = [0.1, 0.5, 0.9]
        let arities = [inputs.count, multipliers.count, priors.count]
        // Defensive filter — see comment in testDisplayTintBoundaryCombinatorial.
        let tuples = PairwiseCovering.generate(arities: arities).filter { $0.count == arities.count }

        var assertedCells = 0
        for tuple in tuples {
            let intensity  = inputs[tuple[0]]
            let multiplier = multipliers[tuple[1]]
            let priorLevel = priors[tuple[2]]

            let mockDriver = MockLEDBrightnessDriver()
            mockDriver.setKeyboardBacklightAvailable(true)
            mockDriver.setCapsLockAccessGranted(true)
            mockDriver.setCurrentLevel(priorLevel)
            mockDriver.stageAutoEnabled(true)
            let led = LEDFlash(driver: mockDriver)
            led.setUp()
            let cfg = MockConfigProvider()
            cfg.led.enabled = true

            // Clip duration ≥ ReactionsConfig.ledMinPulseDuration (0.10s) so
            // the action loop actually pulses.
            let fired = FiredReaction(
                reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity,
                                              confidence: 1.0, sources: [])),
                clipDuration: 0.20,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: Date())

            await led.preAction(fired, multiplier: multiplier, provider: cfg)
            await led.action(fired, multiplier: multiplier, provider: cfg)
            await led.postAction(fired, multiplier: multiplier, provider: cfg)

            let coords = "[intensity=\(intensity) mult=\(multiplier) prior=\(priorLevel)]"
            guard let last = mockDriver.setLevelHistory.last else {
                XCTFail("\(coords) no setLevel calls recorded")
                continue
            }
            XCTAssertEqual(last, priorLevel, accuracy: 0.001,
                "\(coords) restore must return keyboard backlight to prior=\(priorLevel), got \(last)")
            assertedCells += 1
        }
        XCTAssertEqual(assertedCells, tuples.count,
                       "every pairwise tuple must drive one assertion")
    }

    // MARK: - NotificationResponder

    /// Invariant: when auth is `.authorized` and the post does not fail, the
    /// driver records exactly one post per fired reaction. The pairwise sweep
    /// covers (intensity × multiplier × shouldFailPost) — failure injection
    /// must NOT produce a post record.
    func testNotificationResponderBoundaryCombinatorial() async {
        let inputs:   [Float] = [0.1, 0.5, 0.9]
        let multipliers: [Float] = [0.5, 1.0, 1.5]
        let failPost = [false, true]
        let arities = [inputs.count, multipliers.count, failPost.count]
        // Defensive filter — see comment in testDisplayTintBoundaryCombinatorial.
        let tuples = PairwiseCovering.generate(arities: arities).filter { $0.count == arities.count }

        var assertedCells = 0
        for tuple in tuples {
            let intensity  = inputs[tuple[0]]
            let multiplier = multipliers[tuple[1]]
            let shouldFail = failPost[tuple[2]]

            let mockDriver = MockSystemNotificationDriver()
            mockDriver.setAuth(.authorized)
            mockDriver.setShouldFailPost(shouldFail)
            let responder = NotificationResponder(driver: mockDriver, localeProvider: { "en" })
            let cfg = MockConfigProvider()
            cfg.notification = NotificationOutputConfig(
                enabled: true,
                perReaction: MockConfigProvider.allKindsEnabled(),
                dismissAfter: 0.05,
                localeID: "en"
            )

            let fired = FiredReaction(
                reaction: .impact(FusedImpact(timestamp: Date(), intensity: intensity,
                                              confidence: 1.0, sources: [])),
                clipDuration: 0.05,
                soundURL: nil,
                faceIndices: [0],
                publishedAt: Date())

            await responder.action(fired, multiplier: multiplier, provider: cfg)

            let coords = "[intensity=\(intensity) mult=\(multiplier) failPost=\(shouldFail)]"
            let expectedPosts = shouldFail ? 0 : 1
            XCTAssertEqual(mockDriver.posts.count, expectedPosts,
                "\(coords) expected \(expectedPosts) post(s), got \(mockDriver.posts.count)")
            assertedCells += 1
        }
        XCTAssertEqual(assertedCells, tuples.count,
                       "every pairwise tuple must drive one assertion")
    }
}
