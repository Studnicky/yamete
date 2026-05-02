import XCTest
import Foundation
@testable import YameteCore
@testable import ResponseKit

/// Combinatorial coverage of the intensity → volume mapping for both audio
/// playback and the volume-spike responder.
///
/// AudioPlayer formula: `volume = volumeMin + intensity * (volumeMax - volumeMin)`
/// VolumeSpike formula:   `target = min(1.0, audioConfig.volumeMax * multiplier)`
///
/// Cartesian products are small (≤ 135 cells for audio, 20 for volume spike)
/// so we enumerate every cell; pairwise reduction would not materially help.
@MainActor
final class CombinatorialIntensityTests: IntegrationTestCase {

    /// Cartesian: intensity × volumeMin × volumeMax (min ≤ max) × multiplier.
    /// The multiplier dimension is "noise" w.r.t. the audio play formula
    /// (which does not consult any multiplier) — its inclusion proves the
    /// formula is independent of multiplier values.
    func testVolumeFormulaCombinatorial() {
        let intensities: [Float] = [0.0, 0.1, 0.5, 0.9, 1.0]
        let volMins:     [Float] = [0.0, 0.5, 1.0]
        let volMaxs:     [Float] = [0.0, 0.5, 1.0]
        let multipliers: [Float] = [0.5, 1.0, 2.0]

        var assertedCells = 0
        for intensity in intensities {
            for vMin in volMins {
                for vMax in volMaxs where vMax >= vMin {  // valid range only
                    for multiplier in multipliers {
                        _ = multiplier  // noise dim — keep it bound

                        let mockDriver = MockAudioPlaybackDriver()
                        mockDriver.defaultDuration = 1.0
                        let player = AudioPlayer(driver: mockDriver)
                        // Inject a synthetic sound library so peekSound returns
                        // a URL and the driver actually receives a play call.
                        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/yamete-vol-test-\($0).mp3") }
                        player._testInjectSoundLibrary(urls)

                        _ = player.play(
                            intensity: intensity,
                            volumeMin: vMin,
                            volumeMax: vMax,
                            deviceUIDs: ["test-device"]
                        )

                        let coords = "[intensity=\(intensity) min=\(vMin) max=\(vMax) mult=\(multiplier)]"
                        guard let lastCall = mockDriver.playHistory.last else {
                            XCTFail("\(coords) driver.play not called")
                            continue
                        }
                        let expected = vMin + intensity * (vMax - vMin)
                        XCTAssertEqual(lastCall.volume, expected, accuracy: 0.001,
                            "\(coords) expected volume=\(expected), got \(lastCall.volume)")
                        assertedCells += 1
                    }
                }
            }
        }
        // Sanity: must have asserted on every valid (min ≤ max) cell.
        // intensities × multipliers × valid(min,max) pairs = 5 × 3 × 6 = 90.
        XCTAssertEqual(assertedCells, 5 * 3 * 6,
                       "every Cartesian cell with min ≤ max must drive one assertion")
    }

#if DIRECT_BUILD
    /// VolumeSpike target = `min(1.0, audioConfig.volumeMax * multiplier)`.
    /// Cartesian: volumeMax × multiplier.
    func testVolumeSpikeTargetCombinatorial() async {
        let volMaxs: [Double]   = [0.0, 0.3, 0.5, 0.8, 1.0]
        let multipliers: [Float] = [0.5, 1.0, 1.5, 2.0]
        var assertedCells = 0
        for vMax in volMaxs {
            for mult in multipliers {
                let mockVol = MockSystemVolumeDriver()
                mockVol.setCannedVolume(0.3)
                let responder = VolumeSpikeResponder(driver: mockVol)
                let cfg = MockConfigProvider()
                cfg.audio.volumeMax = Float(vMax)
                cfg.volumeSpike.enabled = true

                let fired = FiredReaction(
                    reaction: .impact(FusedImpact(timestamp: Date(), intensity: 1.0,
                                                  confidence: 1.0, sources: [])),
                    clipDuration: 0.0,
                    soundURL: nil,
                    faceIndices: [0],
                    publishedAt: Date()
                )
                await responder.preAction(fired, multiplier: mult, provider: cfg)
                await responder.action(fired, multiplier: mult, provider: cfg)

                let coords = "[vMax=\(vMax) mult=\(mult)]"
                let expected = min(Float(1.0), Float(vMax) * mult)
                guard let firstSet = mockVol.setHistory.first else {
                    XCTFail("\(coords) driver.setVolume not called")
                    continue
                }
                XCTAssertEqual(firstSet, expected, accuracy: 0.001,
                    "\(coords) expected target=\(expected), got \(firstSet)")
                assertedCells += 1

                await responder.postAction(fired, multiplier: mult, provider: cfg)
            }
        }
        XCTAssertEqual(assertedCells, volMaxs.count * multipliers.count,
                       "every (vMax, mult) cell must drive one assertion")
    }
#endif
}
