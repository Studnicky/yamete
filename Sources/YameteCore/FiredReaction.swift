import Foundation

/// A reaction enriched before fan-out. Sensors publish raw `Reaction`;
/// the bus enricher resolves all per-event selections exactly once so
/// every subscriber operates on identical, pre-computed values.
public struct FiredReaction: Sendable {
    public let reaction: Reaction
    /// Duration of the pre-selected audio clip (or event default). Identical across all outputs.
    public let clipDuration: Double
    /// URL of the pre-selected audio clip. AudioPlayer plays this directly without re-selecting.
    public let soundURL: URL?
    /// One face index per connected display, scored for dedup.
    /// faceIndices[i] maps to screen i in NSScreen.screens order.
    /// MenuBarFace uses faceIndices[0] (primary display).
    public let faceIndices: [Int]
    /// Timestamp when this reaction was published to the bus.
    /// Prefer this over `Reaction.timestamp` for non-impact cases — the latter
    /// returns a fresh `Date()` on every access.
    public let publishedAt: Date

    public init(reaction: Reaction, clipDuration: Double, soundURL: URL?, faceIndices: [Int], publishedAt: Date) {
        self.reaction = reaction
        self.clipDuration = clipDuration
        self.soundURL = soundURL
        self.faceIndices = faceIndices
        self.publishedAt = publishedAt
    }

    public var kind: ReactionKind { reaction.kind }
    public var intensity: Float { reaction.intensity }

    /// Returns the face index for the given screen position.
    /// Falls back to faceIndices[0] if the index is out of bounds
    /// (e.g., a display was disconnected between enrichment and rendering).
    public func faceIndex(for screenIndex: Int) -> Int {
        guard !faceIndices.isEmpty else { return 0 }
        guard screenIndex < faceIndices.count else { return faceIndices[0] }
        return faceIndices[screenIndex]
    }
}
