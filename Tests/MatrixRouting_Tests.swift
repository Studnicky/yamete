import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Matrix-style routing tests. Cross-product of every `ReactionKind` ×
/// master-toggle × per-reaction-gate state asserting the
/// `ReactiveOutput.shouldFire` decision is correct. Uses synthetic
/// `FiredReaction` values directly — no real bus subscription, no real
/// audio I/O — so the cell count can be large without test runtime
/// exploding.
///
/// Each assertion is scoped to one (output × kind × master × per-reaction)
/// cell. The total cell count is reported in the test name as a sanity
/// signal that the matrix didn't shrink silently.
@MainActor
final class MatrixRouting_Tests: XCTestCase {

    /// Matrix runner: spy / gated-spy outputs over every reaction kind ×
    /// (allow=true,allow=false) × matrixSpy returns the value of `allow`.
    func testSpyShouldFireMatrix() {
        var cells = 0
        for kind in ReactionKind.allCases {
            for allow in [true, false] {
                let spy = MatrixSpyOutput()
                spy.allow = allow
                let provider = MockConfigProvider()
                let fired = makeFired(kind: kind)
                XCTAssertEqual(spy.shouldFire(fired, provider: provider), allow,
                    "MatrixSpy.shouldFire kind=\(kind) allow=\(allow) must mirror allow")
                cells += 1
            }
        }
        XCTAssertEqual(cells, ReactionKind.allCases.count * 2)
    }

    /// `GatedSpyOutput` consults `audioConfig().perReaction[kind]`.
    /// Cross-product over (every kind × {allowed, blocked}) confirming
    /// the gate observes the matrix.
    func testGatedSpyMatrixObservesPerReaction() {
        var cells = 0
        for kind in ReactionKind.allCases {
            for blocked in [false, true] {
                let provider = MockConfigProvider()
                if blocked { provider.audio.perReaction[kind] = false }
                let spy = GatedSpyOutput()
                let fired = makeFired(kind: kind)
                let expected = !blocked
                XCTAssertEqual(spy.shouldFire(fired, provider: provider), expected,
                    "GatedSpy kind=\(kind) blocked=\(blocked) → expected=\(expected)")
                cells += 1
            }
        }
        XCTAssertEqual(cells, ReactionKind.allCases.count * 2)
    }

    // MARK: - DisplayBrightness routing matrix
    //
    // The display-brightness output gates on (master enabled × intensity ≥ threshold).
    // Reaction kind has no per-reaction matrix here — every kind is allowed.
    // The assertion permutation is therefore (kind × master × intensity-band).

    func testDisplayBrightnessRoutingMatrix() {
        // Only `.impact` carries a per-firing measured intensity; other
        // kinds resolve via `ReactionsConfig.eventIntensity` lookup so
        // this matrix iterates impact intensity values + non-impact
        // kinds at their canonical synthesized intensity.
        let intensities: [Float] = [0.0, 0.1, 0.3, 0.5, 0.8, 1.0]
        let thresholds: [Double] = [0.0, 0.3, 0.5]
        var cells = 0
        // Impact: vary intensity directly
        for masterOn in [true, false] {
            for threshold in thresholds {
                for intensity in intensities {
                    let provider = MockConfigProvider()
                    provider.displayBrightness.enabled = masterOn
                    provider.displayBrightness.threshold = threshold
                    let output = DisplayBrightnessFlash()
                    let fired = makeFired(kind: .impact, intensity: intensity)
                    let expected = masterOn && Double(intensity) >= threshold
                    XCTAssertEqual(output.shouldFire(fired, provider: provider), expected,
                        "DisplayBrightness impact master=\(masterOn) thresh=\(threshold) intensity=\(intensity) expected=\(expected)")
                    cells += 1
                }
            }
        }
        // Non-impact kinds: intensity is fixed by ReactionsConfig.eventIntensity.
        for kind in ReactionKind.allCases where kind != .impact {
            let canonicalIntensity = ReactionsConfig.eventIntensity[kind] ?? 0.5
            for masterOn in [true, false] {
                for threshold in thresholds {
                    let provider = MockConfigProvider()
                    provider.displayBrightness.enabled = masterOn
                    provider.displayBrightness.threshold = threshold
                    let output = DisplayBrightnessFlash()
                    let fired = makeFired(kind: kind)
                    let expected = masterOn && Double(canonicalIntensity) >= threshold
                    XCTAssertEqual(output.shouldFire(fired, provider: provider), expected,
                        "DisplayBrightness kind=\(kind) master=\(masterOn) thresh=\(threshold) canonical=\(canonicalIntensity) expected=\(expected)")
                    cells += 1
                }
            }
        }
        let expected = (2 * thresholds.count * intensities.count)
                     + ((ReactionKind.allCases.count - 1) * 2 * thresholds.count)
        XCTAssertEqual(cells, expected)
    }

    // MARK: - DisplayTint routing matrix
    //
    // Tint gates on (master enabled × per-reaction[kind] != false × OS supports tint).
    // We cannot fake the OS gate, but we can still verify the master + per-reaction
    // half over the full kind cross-product on hosts where the OS gate is true.

    func testDisplayTintRoutingMatrix() {
        let onModernOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
        var cells = 0
        for kind in ReactionKind.allCases {
            for masterOn in [true, false] {
                for kindBlocked in [false, true] {
                    let provider = MockConfigProvider()
                    provider.displayTint.enabled = masterOn
                    if kindBlocked { provider.displayTint.perReaction[kind] = false }
                    let output = DisplayTintFlash()
                    let fired = makeFired(kind: kind)
                    let expected = onModernOS && masterOn && !kindBlocked
                    XCTAssertEqual(output.shouldFire(fired, provider: provider), expected,
                        "DisplayTint kind=\(kind) master=\(masterOn) kindBlocked=\(kindBlocked) → expected=\(expected)")
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, ReactionKind.allCases.count * 2 * 2)
    }

    // MARK: - ScreenFlash routing matrix
    //
    // Flash gates on (master × per-reaction[kind] != false).

    func testScreenFlashRoutingMatrix() {
        var cells = 0
        for kind in ReactionKind.allCases {
            for masterOn in [true, false] {
                for kindBlocked in [false, true] {
                    let provider = MockConfigProvider()
                    provider.flash.enabled = masterOn
                    if kindBlocked { provider.flash.perReaction[kind] = false }
                    let output = ScreenFlash()
                    let fired = makeFired(kind: kind)
                    let expected = masterOn && !kindBlocked
                    XCTAssertEqual(output.shouldFire(fired, provider: provider), expected,
                        "ScreenFlash kind=\(kind) master=\(masterOn) kindBlocked=\(kindBlocked) → expected=\(expected)")
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, ReactionKind.allCases.count * 2 * 2)
    }

    // MARK: - Haptic routing matrix (driver-injected to bypass hardware)
    //
    // Haptic adds a hardwareAvailable third gate. We inject a mock driver and
    // run the full (kind × hardwareAvailable × master × kindBlocked) cross-product.

    func testHapticRoutingMatrix() {
        var cells = 0
        for kind in ReactionKind.allCases {
            for hardwareOn in [true, false] {
                for masterOn in [true, false] {
                    for kindBlocked in [false, true] {
                        let driver = MockHapticEngineDriver()
                        driver.setHardwareAvailable(hardwareOn)
                        let output = HapticResponder(driver: driver)
                        let provider = MockConfigProvider()
                        provider.haptic.enabled = masterOn
                        if kindBlocked { provider.haptic.perReaction[kind] = false }
                        let fired = makeFired(kind: kind)
                        let expected = hardwareOn && masterOn && !kindBlocked
                        XCTAssertEqual(output.shouldFire(fired, provider: provider), expected,
                            "Haptic kind=\(kind) hw=\(hardwareOn) master=\(masterOn) kindBlocked=\(kindBlocked) → expected=\(expected)")
                        cells += 1
                    }
                }
            }
        }
        XCTAssertEqual(cells, ReactionKind.allCases.count * 2 * 2 * 2)
    }

    // MARK: - End-to-end bus routing
    //
    // Round-trip a kind through ReactionBus → MatrixSpyOutput.consume and verify
    // the spy observed exactly one action call per allowed kind.

    func testEndToEndBusDeliversAllowedKinds() async throws {
        let harness = BusHarness()
        await harness.setUp()
        let spy = MatrixSpyOutput()
        spy.allow = true
        let provider = MockConfigProvider()
        let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: provider) }
        defer { consumeTask.cancel() }

        try await Task.sleep(for: .milliseconds(20))
        await harness.bus.publish(.acConnected)
        // Coalesce window 16ms + action duration + buffer
        try await Task.sleep(for: .milliseconds(120))

        // Strong assertion: exactly the expected kind, not just "some action".
        XCTAssertEqual(spy.actionKinds(), [.acConnected],
                       "spy must observe exactly one .acConnected action and nothing else")
    }

    /// Lifecycle ordering invariant: every reaction drives the four phases in
    /// the strict order pre → action → post (reset is its own surface and
    /// only fires on cancellation/teardown). Each call carries the published
    /// kind. Timestamps are strictly increasing across the trio.
    func testLifecycleCallSequence_isStrictlyOrdered() async throws {
        let spy = MatrixSpyOutput()
        let provider = MockConfigProvider()
        let fired = makeFired(kind: .acConnected)

        await spy.preAction(fired, multiplier: 1.0, provider: provider)
        await spy.action(fired, multiplier: 1.0, provider: provider)
        await spy.postAction(fired, multiplier: 1.0, provider: provider)

        let phases = spy.calls.map(\.phase)
        XCTAssertEqual(phases, [.pre, .action, .post],
                       "exactly three lifecycle phases in pre→action→post order, got \(phases)")
        let kinds = spy.calls.compactMap(\.kind)
        XCTAssertEqual(kinds, [.acConnected, .acConnected, .acConnected],
                       "every phase must observe the published kind")
        // Non-decreasing timestamps across the three calls (guarded so a
        // missing phase doesn't crash on an out-of-range subscript). The
        // spy stamps each call with `Date()` before returning; back-to-back
        // calls under the same MainActor task may share a wall clock tick.
        guard spy.calls.count == 3 else { return }
        XCTAssertLessThanOrEqual(spy.calls[0].timestamp, spy.calls[1].timestamp,
                                 "preAction timestamp must not exceed action timestamp")
        XCTAssertLessThanOrEqual(spy.calls[1].timestamp, spy.calls[2].timestamp,
                                 "action timestamp must not exceed postAction timestamp")
    }

    /// Round-trip the same kind with `allow=false` and confirm the spy
    /// never sees an action call.
    func testEndToEndBusBlocksWhenShouldFireFalse() async throws {
        let harness = BusHarness()
        await harness.setUp()
        let spy = MatrixSpyOutput()
        spy.allow = false
        let provider = MockConfigProvider()
        let consumeTask = Task { await spy.consume(from: harness.bus, configProvider: provider) }
        defer { consumeTask.cancel() }

        try await Task.sleep(for: .milliseconds(20))
        await harness.bus.publish(.acConnected)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(spy.actions().isEmpty, "shouldFire=false drops the stimulus")
    }

    // MARK: - Helpers

    private func makeFired(kind: ReactionKind, intensity: Float = 0.5) -> FiredReaction {
        FiredReaction(
            reaction: reactionFor(kind: kind, intensity: intensity),
            clipDuration: 0.05,
            soundURL: nil,
            faceIndices: [0],
            publishedAt: Date()
        )
    }

    private func reactionFor(kind: ReactionKind, intensity: Float) -> Reaction {
        switch kind {
        case .impact:
            return .impact(FusedImpact(timestamp: Date(), intensity: intensity, confidence: 1.0, sources: []))
        case .usbAttached:              return .usbAttached(.init(name: "test", vendorID: 0, productID: 0))
        case .usbDetached:              return .usbDetached(.init(name: "test", vendorID: 0, productID: 0))
        case .acConnected:              return .acConnected
        case .acDisconnected:           return .acDisconnected
        case .audioPeripheralAttached: return .audioPeripheralAttached(.init(uid: "u", name: "n"))
        case .audioPeripheralDetached: return .audioPeripheralDetached(.init(uid: "u", name: "n"))
        case .bluetoothConnected:       return .bluetoothConnected(.init(address: "a", name: "n"))
        case .bluetoothDisconnected:    return .bluetoothDisconnected(.init(address: "a", name: "n"))
        case .thunderboltAttached:      return .thunderboltAttached(.init(name: "n"))
        case .thunderboltDetached:      return .thunderboltDetached(.init(name: "n"))
        case .displayConfigured:        return .displayConfigured
        case .willSleep:                return .willSleep
        case .didWake:                  return .didWake
        case .trackpadTouching:         return .trackpadTouching
        case .trackpadSliding:          return .trackpadSliding
        case .trackpadContact:          return .trackpadContact
        case .trackpadTapping:          return .trackpadTapping
        case .trackpadCircling:         return .trackpadCircling
        case .mouseClicked:             return .mouseClicked
        case .mouseScrolled:            return .mouseScrolled
        case .keyboardTyped:            return .keyboardTyped
        }
    }
}
