#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import Foundation
import Observation

/// Drives the rotating subtext shown beneath the static "Yamete" title in
/// the menu bar dropdown header. The pool of pages is the spicy
/// reaction copy (impact-tier moans from the locale's Moans.strings) —
/// NOT the bland system-event bodies. The current page is observed by
/// `HeaderSection`, which slow-pulses between pages with a ~3.5s
/// ease-in-out cross-fade.
///
/// Selection is randomised but non-repeating: a freshly-shuffled order
/// is consumed page-by-page; once exhausted the pool reshuffles with
/// the constraint that the new first page is not the same as the
/// previous last page. Mirrors the `FaceLibrary` "shuffle-without-
/// adjacent-repeats" pattern so the same body never appears twice in a
/// row even across cycle boundaries.
///
/// Page 0 of the very first cycle is the app tagline so the header
/// reads the brand descriptor on launch; the tagline is included in
/// the shuffle pool thereafter alongside the moans.
///
/// `@MainActor`-isolated; every observer lives on the main actor.
@MainActor
@Observable
public final class MenuHeaderRotator {
    public private(set) var current: String
    private var pool: [String]
    private var queue: [String]
    private var lastShown: String?
    private var task: Task<Void, Never>?
    private let interval: TimeInterval
    /// Injected randomness; tests substitute a deterministic shuffle to
    /// lock the order without exercising `SystemRandomNumberGenerator`.
    private let shuffle: ([String]) -> [String]

    /// `interval` clamped to `[3.5s, 30s]` — a value below the cross-fade
    /// duration would queue transitions before the previous one finished.
    public init(pages: [String] = [],
                interval: TimeInterval = 8.0,
                shuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) {
        let safeInterval = max(3.5, min(30.0, interval))
        self.interval = safeInterval
        self.shuffle = shuffle
        let safePool = pages.isEmpty ? [""] : pages
        self.pool = safePool
        self.queue = Array(safePool.dropFirst())
        self.current = safePool[0]
        self.lastShown = safePool[0]
    }

    /// Replace the page pool. Resets the visible page to the new first
    /// entry and reseeds the queue. Idempotent on equal pools — equal
    /// re-sets are a no-op so the cross-fade doesn't restart whenever
    /// the caller re-emits the same list.
    public func setPages(_ newPages: [String]) {
        guard !newPages.isEmpty else { return }
        if newPages == pool { return }
        pool = newPages
        queue = Array(newPages.dropFirst())
        current = newPages[0]
        lastShown = newPages[0]
    }

    /// Begin advancing every `interval` seconds. Idempotent.
    public func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.interval))
                if Task.isCancelled { return }
                self.advance()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Pure advance — exposed `internal` for unit tests so they don't
    /// need to wait wall-clock time to drive the cursor. Pulls the next
    /// page from `queue`; when `queue` empties, reshuffles `pool` with
    /// the constraint that the new first page is not equal to
    /// `lastShown` (so the same body never repeats across cycle
    /// boundaries — the FaceLibrary shuffle-without-adjacent-repeats
    /// pattern).
    internal func advance() {
        guard pool.count > 1 else { return }
        if queue.isEmpty {
            queue = reshuffledQueue()
        }
        let next = queue.removeFirst()
        current = next
        lastShown = next
    }

    /// Reshuffles `pool` using the injected RNG and rotates the result
    /// once if the head equals `lastShown`, guaranteeing no two-in-a-row
    /// repeats. With `pool.count >= 2` the rotation always succeeds.
    private func reshuffledQueue() -> [String] {
        var shuffled = shuffle(pool)
        if shuffled.first == lastShown && shuffled.count >= 2 {
            shuffled.append(shuffled.removeFirst())
        }
        return shuffled
    }

    /// Builds the rotator's body pool: `[appTagline]` followed by every
    /// impact-tier moan in the given locale (deduped across tiers,
    /// empty entries skipped, en fallback per tier). Event-body
    /// strings are intentionally not included — the rotator surfaces
    /// reaction copy, not system-event descriptions. Exposed
    /// `internal static` so tests can build the pool without
    /// instantiating the rotator.
    @MainActor
    internal static func buildBodies(appTagline: String, locale: String) -> [String] {
        var bodies: [String] = [appTagline]
        bodies.append(contentsOf: NotificationPhrase.allMoans(preferredLocale: locale))
        var seen = Set<String>()
        var deduped: [String] = []
        for body in bodies where !body.isEmpty && !seen.contains(body) {
            seen.insert(body)
            deduped.append(body)
        }
        return deduped
    }
}
