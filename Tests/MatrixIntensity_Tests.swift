import XCTest
import Foundation
@testable import YameteCore
@testable import ResponseKit

/// Matrix-style intensity tests. Drive `FusedImpact.applySensitivity`
/// over the full range of in-band, out-of-band, and degenerate inputs
/// (negative, NaN, infinity) and assert the documented behavior.
///
/// The sensitivity model maps a raw 0...1 intensity through a
/// user-configured (sensitivityMin, sensitivityMax) band:
///   thresholdLow  = 1 - sensitivityMax
///   thresholdHigh = 1 - sensitivityMin
///   raw < thresholdLow  → nil
///   raw ≥ thresholdLow  → linear remap into 0...1, clamped
///
/// The matrix below covers every documented edge case.
final class MatrixIntensity_Tests: XCTestCase {

    /// Each row: (raw intensity, sensitivityMin, sensitivityMax,
    /// expected behavior)
    /// Expected categories:
    ///   .below — should return nil
    ///   .approximately(value) — should return value within 0.01
    ///   .nan — should return nil (or finite within 0...1)
    ///   .saturatedHigh — should return ≥ 0.99
    ///   .saturatedLow — should return ≤ 0.01
    enum Expected {
        case below
        case approximately(Float, Float)   // value, tolerance
        case nan
        case saturatedHigh
        case saturatedLow
    }

    /// Documented matrix of (raw, sensMin, sensMax, expected).
    func testApplySensitivityMatrix() {
        // sensitivityMin=0.0, sensitivityMax=1.0 → window is [0, 1], raw passes through clamped
        let cases: [(Float, Float, Float, Expected, String)] = [
            // Full-window (0, 1): raw passes through
            (-0.5,  0.0, 1.0, .below,                       "negative below thresholdLow=0"),
            (-0.01, 0.0, 1.0, .below,                       "small negative below thresholdLow=0"),
            ( 0.0,  0.0, 1.0, .saturatedLow,                "raw=0 at threshold → 0"),
            ( 0.001,0.0, 1.0, .approximately(0.001, 0.01),  "near-zero raw"),
            ( 0.25, 0.0, 1.0, .approximately(0.25, 0.01),   "quarter raw"),
            ( 0.5,  0.0, 1.0, .approximately(0.5, 0.01),    "half raw"),
            ( 0.75, 0.0, 1.0, .approximately(0.75, 0.01),   "three-quarter raw"),
            ( 0.99, 0.0, 1.0, .approximately(0.99, 0.01),   "high raw"),
            ( 1.0,  0.0, 1.0, .saturatedHigh,               "max raw → 1"),
            ( 1.01, 0.0, 1.0, .saturatedHigh,               "above 1 clamps to 1"),
            ( 1.5,  0.0, 1.0, .saturatedHigh,               "well above 1 clamps to 1"),

            // Narrower window: sensMin=0.3, sensMax=0.7 → [0.3, 0.7]
            ( 0.2,  0.3, 0.7, .below,                       "raw 0.2 below thresholdLow=0.3"),
            ( 0.3,  0.3, 0.7, .saturatedLow,                "raw 0.3 at thresholdLow → 0"),
            ( 0.5,  0.3, 0.7, .approximately(0.5, 0.05),    "raw 0.5 mid-band → 0.5"),
            ( 0.7,  0.3, 0.7, .saturatedHigh,               "raw 0.7 at thresholdHigh → 1"),
            ( 0.9,  0.3, 0.7, .saturatedHigh,               "raw above thresholdHigh clamps to 1"),

            // Pathological: NaN and Infinity
            ( Float.nan,      0.0, 1.0, .nan,               "NaN raw"),
            ( Float.infinity, 0.0, 1.0, .saturatedHigh,     "+Inf clamps to 1"),
            (-Float.infinity, 0.0, 1.0, .below,             "-Inf is below threshold"),
        ]

        for (raw, sMin, sMax, expected, label) in cases {
            let result = FusedImpact.applySensitivity(rawIntensity: raw, sensitivityMin: sMin, sensitivityMax: sMax)
            switch expected {
            case .below:
                XCTAssertNil(result, "\(label) → expected nil; got \(String(describing: result))")
            case .approximately(let target, let tol):
                guard let r = result else {
                    XCTFail("\(label) → expected ~\(target); got nil")
                    continue
                }
                XCTAssertEqual(r, target, accuracy: tol, label)
            case .nan:
                // NaN is allowed to surface as nil OR as a finite 0...1 value
                // (`>=` against NaN evaluates false in Swift, so the guard
                // returns nil — that is the documented behavior).
                if let r = result {
                    XCTAssertFalse(r.isNaN, "\(label): result must not be NaN if non-nil")
                    XCTAssertTrue((0.0...1.0).contains(r), "\(label): finite result must be in 0...1")
                }
            case .saturatedHigh:
                guard let r = result else {
                    XCTFail("\(label) → expected ≥0.99; got nil")
                    continue
                }
                XCTAssertGreaterThanOrEqual(r, 0.99, label)
            case .saturatedLow:
                guard let r = result else {
                    XCTFail("\(label) → expected ≤0.01; got nil")
                    continue
                }
                XCTAssertLessThanOrEqual(r, 0.01, label)
            }
        }
    }

    /// Boundary sweep: 100 evenly-spaced raw intensities × 5 sensitivity bands.
    /// Asserts the function's two universal invariants:
    ///   1. Returned value (when non-nil) is finite and in 0...1.
    ///   2. Function never throws or hangs (implicit by completing the loop).
    func testInvariantsAcrossSweep() {
        let bands: [(Float, Float)] = [
            (0.0, 1.0),
            (0.0, 0.5),
            (0.5, 1.0),
            (0.25, 0.75),
            (0.4, 0.6),
        ]
        var cells = 0
        for (sMin, sMax) in bands {
            for step in 0...100 {
                let raw = Float(step) / 100.0
                let result = FusedImpact.applySensitivity(rawIntensity: raw, sensitivityMin: sMin, sensitivityMax: sMax)
                if let r = result {
                    XCTAssertFalse(r.isNaN,       "sweep: result must not be NaN at raw=\(raw) band=(\(sMin),\(sMax))")
                    XCTAssertFalse(r.isInfinite,  "sweep: result must not be Infinity at raw=\(raw) band=(\(sMin),\(sMax))")
                    XCTAssertGreaterThanOrEqual(r, 0.0)
                    XCTAssertLessThanOrEqual(r,    1.0)
                }
                cells += 1
            }
        }
        XCTAssertEqual(cells, bands.count * 101)
    }

    /// Monotonicity sweep — the universal sensitivity invariant. For any
    /// fixed (sensMin, sensMax) band, increasing the raw intensity must
    /// produce a non-decreasing remapped output. A regression that flips
    /// the remap (e.g. swapping `(raw - low)` for `(low - raw)`) would
    /// trip this assertion at the first descending pair. 1000 random bands
    /// × 1001 raw steps cover the band parameter space densely without
    /// brittle exact-value assertions.
    func testApplySensitivity_monotonicAcrossSweep() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<1000 {
            // Pick a random band where sensMin ≤ sensMax in [0,1].
            let a = Float.random(in: 0...1, using: &rng)
            let b = Float.random(in: 0...1, using: &rng)
            let sMin = min(a, b)
            let sMax = max(a, b)
            var lastValue: Float = -.infinity
            var step: Int = 0
            while step <= 1000 {
                let raw = Float(step) / 1000.0
                if let v = FusedImpact.applySensitivity(rawIntensity: raw, sensitivityMin: sMin, sensitivityMax: sMax) {
                    XCTAssertGreaterThanOrEqual(v, lastValue,
                        "trial \(trial) band=(\(sMin),\(sMax)) raw=\(raw) → \(v) is below prev \(lastValue) — monotonicity violated")
                    lastValue = v
                }
                step += 1
            }
        }
    }

    /// `AudioPlayer.peekSound` MUST resolve to a non-nil URL for every
    /// reaction kind once sounds are loaded, otherwise certain kinds get
    /// silenced regardless of audio config. A regression once added
    /// `guard case .impact = reaction else { return nil }` to peekSound,
    /// silencing every event reaction. We catch that here by injecting a
    /// fake driver that fakes a loaded sound library and asserting every
    /// kind resolves.
    @MainActor
    func testEveryReactionKindResolvesClip() {
        let mock = MockAudioPlaybackDriver()
        mock.defaultDuration = 1.0
        let player = AudioPlayer(driver: mock)
        // SPM test bundle has no `sounds/` resources, so the production
        // preload returns an empty library and every `peekSound` would
        // trivially return nil. Use the test seam to inject a synthetic
        // library so the per-kind dispatch is observable.
        let urls = (0..<8).map { URL(fileURLWithPath: "/tmp/yamete-test-\($0).mp3") }
        player._testInjectSoundLibrary(urls)

        for kind in ReactionKind.allCases {
            let reaction = ReactionForKind.make(kind: kind)
            let result = player.peekSound(intensity: 0.5, reaction: reaction)
            XCTAssertNotNil(result, "[\(kind.rawValue)] peekSound must return a URL when library is loaded — a `guard case .impact` regression silenced every event reaction")
            XCTAssertGreaterThan(result?.duration ?? 0, 0,
                                 "[\(kind.rawValue)] returned clip must carry a positive duration")
        }
    }

    /// Degenerate band: sensMin == sensMax. The function uses `max(0.001, ...)`
    /// to avoid division-by-zero. Verify the function behaves predictably
    /// (no NaN, no crash) across this entire family.
    func testDegenerateBandDoesNotCrash() {
        let centers: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        for c in centers {
            for raw in stride(from: Float(0.0), through: 1.0, by: 0.1) {
                let result = FusedImpact.applySensitivity(rawIntensity: raw, sensitivityMin: c, sensitivityMax: c)
                if let r = result {
                    XCTAssertFalse(r.isNaN, "degenerate band c=\(c) raw=\(raw)")
                }
            }
        }
    }
}
