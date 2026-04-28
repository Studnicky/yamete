#if canImport(YameteCore)
import YameteCore
#endif
import AppKit

/// Single shared face image cache and selection engine.
/// Images are loaded once, reloaded only on appearance change.
/// The enricher calls `selectIndices(count:)` before fan-out; all consumers
/// look up the same image via `image(at:)` from FiredReaction.faceIndices.
@MainActor
public final class FaceLibrary {
    public static let shared = FaceLibrary()

    private var images: [NSImage] = []
    private var loadedAppearance: NSAppearance.Name?
    /// Per-event recency history for dedup scoring. Maintained here so selection happens once in the enricher before fan-out.
    /// now centralised here so selection happens once in the enricher.
    private var history: [Int] = []

    private init() {}

    public var count: Int { current.count }

    /// Selects one face index per display, scored for dedup across monitors and events.
    /// Called by the bus enricher exactly once per reaction.
    public func selectIndices(count: Int) -> [Int] {
        let faces = current
        guard !faces.isEmpty, count > 0 else { return Array(repeating: 0, count: max(count, 1)) }
        let total = faces.count

        var usedThisEvent = Set<Int>()
        var picks: [Int] = []

        for _ in 0..<count {
            let recentSet = Set(history.suffix(min(total, 4)))
            let scores = (0..<total).map { idx -> (index: Int, score: Int) in
                let recency = history.lastIndex(of: idx).map { history.count - $0 } ?? (total + 1)
                let recentPenalty = recentSet.contains(idx) ? total : 0
                let eventPenalty = usedThisEvent.contains(idx) ? total * 2 : 0
                return (idx, -recency + recentPenalty + eventPenalty)
            }
            let best = scores.min(by: { $0.score < $1.score })?.index ?? 0
            picks.append(best)
            usedThisEvent.insert(best)
            history.append(best)
        }

        if history.count > total * 2 { history.removeFirst(history.count - total * 2) }
        return picks
    }

    public func image(at index: Int) -> NSImage? {
        let faces = current
        guard !faces.isEmpty else { return nil }
        return faces[index % faces.count]
    }

    private var current: [NSImage] {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if images.isEmpty || appearance != loadedAppearance {
            images = FaceRenderer.loadFaces()
            loadedAppearance = appearance
            if images.isEmpty {
                AppLog(category: "FaceLibrary").error("entity:FaceLibrary wasInvalidatedBy activity:Load — no faces found")
            }
        }
        return images
    }
}
