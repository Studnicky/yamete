import XCTest
@testable import YameteCore

final class FiredReactionTests: XCTestCase {
    private func makeReaction() -> Reaction {
        .impact(FusedImpact(timestamp: Date(), intensity: 0.5, confidence: 1.0, sources: []))
    }

    func testFaceIndexBoundsGuard() {
        let r = FiredReaction(reaction: makeReaction(), clipDuration: 1.0, soundURL: nil, faceIndices: [3, 7], publishedAt: Date())
        XCTAssertEqual(r.faceIndex(for: 0), 3)
        XCTAssertEqual(r.faceIndex(for: 1), 7)
        // Out-of-bounds falls back to first
        XCTAssertEqual(r.faceIndex(for: 5), 3)
        XCTAssertEqual(r.faceIndex(for: 99), 3)
    }

    func testFaceIndexEmptyFallback() {
        let r = FiredReaction(reaction: makeReaction(), clipDuration: 1.0, soundURL: nil, faceIndices: [], publishedAt: Date())
        XCTAssertEqual(r.faceIndex(for: 0), 0)
    }

    func testKindAndIntensityForwarding() {
        let r = FiredReaction(reaction: makeReaction(), clipDuration: 1.0, soundURL: nil, faceIndices: [0], publishedAt: Date())
        XCTAssertEqual(r.kind, .impact)
        XCTAssertEqual(r.intensity, 0.5, accuracy: 0.001)
    }

    func testPublishedAtIsStored() {
        let now = Date()
        let r = FiredReaction(reaction: makeReaction(), clipDuration: 1.0, soundURL: nil, faceIndices: [0], publishedAt: now)
        XCTAssertEqual(r.publishedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }
}
