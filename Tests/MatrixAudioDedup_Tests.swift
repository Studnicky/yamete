import XCTest
@testable import YameteCore
@testable import ResponseKit

/// Audio dedup matrix:
///   library size × intensity × dedup history
///
/// `AudioPlayer.peekSound(intensity:reaction:)` picks a sound from
/// `soundFiles - recentlyPlayed`. After commit, `recordPlayed` slides a
/// window of size `historySize` so a clip can repeat once it scrolls out.
///
/// We can't change `historySize` from the test side (it's a stored constant),
/// but every other dimension is exercised. Determinism for "no consecutive
/// repeats" comes from the production-coded dedup contract — when only one
/// fresh clip exists in the available pool, peekSound is forced to pick it.
/// When all clips are recent, `pool` reverts to the full library; the matrix
/// asserts the recently-played eviction window evicts oldest first.
@MainActor
final class MatrixAudioDedup_Tests: XCTestCase {

    // MARK: - Fixture

    private func makeLibrary(count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/tmp/yamete-clip-\($0).mp3") }
    }

    private func makeBandedLibrary() -> [(url: URL, duration: Double)] {
        // 10 clips with strictly increasing durations so peekSound's
        // intensity-banded slicing is observable.
        (0..<10).map {
            (url: URL(fileURLWithPath: "/tmp/yamete-band-\($0).mp3"),
             duration: Double($0 + 1) * 0.5)  // 0.5s, 1.0s, 1.5s ... 5.0s
        }
    }

    // MARK: - Matrix A: small library, sequential plays, no consecutive repeats

    func testNoConsecutiveRepeatsWithSmallLibrary() {
        let player = AudioPlayer(driver: MockAudioPlaybackDriver())
        let library = makeLibrary(count: 3)
        player._testInjectSoundLibrary(library, duration: 1.0)

        var sequence: [URL] = []
        for _ in 0..<20 {
            guard let url = player._testPeekAndCommit(intensity: 0.5) else {
                XCTFail("[library=3] peek must return a clip")
                return
            }
            sequence.append(url)
        }
        for i in 1..<sequence.count {
            XCTAssertNotEqual(sequence[i], sequence[i - 1],
                "[library=3 historySize=2 i=\(i)] consecutive clips repeated: \(sequence[i].lastPathComponent) twice")
        }
    }

    /// Within the first `library.count` plays, every distinct clip must appear
    /// at least once (pool exhaustion before any repeat).
    func testFullCoverageBeforeRepeats() {
        let player = AudioPlayer(driver: MockAudioPlaybackDriver())
        let library = makeLibrary(count: 3)
        player._testInjectSoundLibrary(library, duration: 1.0)

        var firstThree: Set<URL> = []
        for _ in 0..<3 {
            guard let url = player._testPeekAndCommit(intensity: 0.5) else {
                XCTFail("[library=3] peek must return a clip")
                return
            }
            firstThree.insert(url)
        }
        XCTAssertEqual(firstThree.count, 3,
            "[library=3] first 3 plays must cover all 3 distinct clips, got \(firstThree.count) distinct")
    }

    // MARK: - Matrix B: large library × random intensity × no consecutive repeats

    func testLargeLibraryNoConsecutiveRepeats() {
        let player = AudioPlayer(driver: MockAudioPlaybackDriver())
        let library = makeLibrary(count: 10)
        player._testInjectSoundLibrary(library, duration: 1.0)

        // Vary intensity but keep it in the middle band so the eligible pool
        // is wide enough for dedup to matter.
        var sequence: [URL] = []
        for i in 0..<100 {
            let intensity: Float = Float((i * 17) % 100) / 100.0
            guard let url = player._testPeekAndCommit(intensity: intensity) else {
                XCTFail("[library=10 i=\(i)] peek must return a clip")
                return
            }
            sequence.append(url)
        }
        for i in 1..<sequence.count {
            XCTAssertNotEqual(sequence[i], sequence[i - 1],
                "[library=10 historySize=2 i=\(i) intensity-band] consecutive clips repeated: \(sequence[i].lastPathComponent)")
        }
        let distinct = Set(sequence)
        XCTAssertGreaterThan(distinct.count, 1,
            "[library=10] over 100 plays the player must use more than one clip, got \(distinct.count)")
    }

    // MARK: - Matrix C: intensity-band selection

    /// peekSound's banded slicing centers on `idealIdx = intensity * (count-1)`
    /// with a half-window of `max(1, count/8)`. With 10 clips, half=1, so:
    ///   - intensity=0.0 → ideal=0 → window [0, 1]    (durations 0.5–1.0s)
    ///   - intensity=0.5 → ideal=4 → window [3, 5]    (durations 2.0–3.0s)
    ///   - intensity=1.0 → ideal=9 → window [8, 9]    (durations 4.5–5.0s)
    ///
    /// We assert (a) low-intensity peeks pick a duration ≤ medium duration,
    /// (b) high-intensity peeks pick a duration ≥ medium duration, with a
    /// broad band so dedup-driven shifts don't cause flakes.
    func testIntensityBandSelection() {
        struct Cell { let intensity: Float; let maxDurationAllowed: Double; let minDurationAllowed: Double }
        // Ten clips: durations 0.5, 1.0, 1.5, ..., 5.0
        let cells: [Cell] = [
            // low intensity → must pick from short clips (≤ 1.5s allowing slight band slack)
            .init(intensity: 0.0, maxDurationAllowed: 1.5, minDurationAllowed: 0.0),
            .init(intensity: 0.1, maxDurationAllowed: 1.5, minDurationAllowed: 0.0),
            // high intensity → must pick from long clips (≥ 4.0s)
            .init(intensity: 0.95, maxDurationAllowed: 5.0, minDurationAllowed: 4.0),
            .init(intensity: 1.0,  maxDurationAllowed: 5.0, minDurationAllowed: 4.0),
        ]
        for cell in cells {
            let player = AudioPlayer(driver: MockAudioPlaybackDriver())
            player._testInjectSoundLibrary(makeBandedLibrary())
            // Peek without committing so dedup doesn't shift the pool.
            for trial in 0..<10 {
                guard let pick = player.peekSound(
                    intensity: cell.intensity,
                    reaction: .impact(.init(timestamp: Date(), intensity: cell.intensity, confidence: 1, sources: []))
                ) else {
                    XCTFail("[intensity=\(cell.intensity) trial=\(trial)] peek must return a clip")
                    return
                }
                XCTAssertLessThanOrEqual(pick.duration, cell.maxDurationAllowed,
                    "[intensity=\(cell.intensity) trial=\(trial)] picked duration \(pick.duration) exceeds band max \(cell.maxDurationAllowed)")
                XCTAssertGreaterThanOrEqual(pick.duration, cell.minDurationAllowed,
                    "[intensity=\(cell.intensity) trial=\(trial)] picked duration \(pick.duration) below band min \(cell.minDurationAllowed)")
            }
        }
    }

    // MARK: - Matrix D: recently-played eviction

    /// historySize=2: after 3 commits, the oldest clip must be eligible again
    /// (its slot has been evicted from `recentlyPlayed`).
    func testRecentlyPlayedEviction() {
        let player = AudioPlayer(driver: MockAudioPlaybackDriver())
        let library = makeLibrary(count: 4)
        player._testInjectSoundLibrary(library, duration: 1.0)

        // Commit 3 plays. After play 3, recentlyPlayed = [play2, play3]
        // (window size 2, oldest evicted).
        let urls = (0..<3).compactMap { _ in player._testPeekAndCommit(intensity: 0.5) }
        XCTAssertEqual(urls.count, 3, "[library=4] 3 commits must succeed")
        XCTAssertEqual(player._testRecentlyPlayedCount, 2,
            "[library=4 commits=3 historySize=2] expected recentlyPlayed.count=2, got \(player._testRecentlyPlayedCount)")

        // The first-played URL should be eligible again — it's no longer in the
        // sliding window. Run several peeks to assert it can re-appear.
        let firstURL = urls[0]
        var sawFirstAgain = false
        for _ in 0..<60 {
            guard let pick = player.peekSound(
                intensity: 0.5,
                reaction: .impact(.init(timestamp: Date(), intensity: 0.5, confidence: 1, sources: []))
            ) else {
                XCTFail("peek must succeed")
                return
            }
            if pick.url == firstURL { sawFirstAgain = true; break }
        }
        XCTAssertTrue(sawFirstAgain,
            "[library=4 historySize=2] oldest committed URL must be re-eligible after eviction")
    }
}
