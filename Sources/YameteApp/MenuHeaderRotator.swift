#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import Foundation
import Observation

/// Drives the rotating subtext shown beneath the static "Yamete" title in
/// the menu bar dropdown header. Pages cycle on a fixed interval; each
/// page is a localised notification body string. The current page is
/// observed by `HeaderSection`, which slow-pulses between pages with a
/// ~3.5s ease-in-out cross-fade.
///
/// Page 0 is always the app tagline (`app_tagline`) so the header reads
/// the brand descriptor first; subsequent pages are body strings drawn
/// from the enabled reaction kinds' Events.strings body pools in the
/// user's selected locale. Titles do NOT rotate — the static "Yamete"
/// stays put above the rotating body line.
///
/// `@MainActor`-isolated; every observer lives on the main actor.
@MainActor
@Observable
public final class MenuHeaderRotator {
    public private(set) var current: String
    private var pages: [String]
    private var index: Int = 0
    private var task: Task<Void, Never>?
    private let interval: TimeInterval

    /// `interval` clamped to `[3.5s, 30s]` — a value below the cross-fade
    /// duration would queue transitions before the previous one finished.
    public init(pages: [String] = [], interval: TimeInterval = 8.0) {
        let safeInterval = max(3.5, min(30.0, interval))
        self.interval = safeInterval
        let safePages = pages.isEmpty ? [""] : pages
        self.pages = safePages
        self.current = safePages[0]
    }

    /// Replace the page set. Resets the cursor to page 0 and the visible
    /// page to the new first entry. Idempotent on equal pages — equal
    /// re-sets are a no-op so the cross-fade doesn't restart whenever the
    /// caller re-emits the same list.
    public func setPages(_ newPages: [String]) {
        guard !newPages.isEmpty else { return }
        if newPages == pages { return }
        pages = newPages
        index = 0
        current = newPages[0]
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

    /// Pure advance — exposed `internal` for unit tests so they don't need
    /// to wait wall-clock time to drive the cursor.
    internal func advance() {
        guard pages.count > 1 else { return }
        index = (index + 1) % pages.count
        current = pages[index]
    }

    /// Pure helper — exposed `internal static` so tests can build pages
    /// without instantiating the rotator. Mirrors what
    /// `HeaderSection.onAppear` computes at runtime: the tagline first,
    /// then every body variant for each enabled reaction kind in the
    /// user's locale, deduped, sorted for stable ordering.
    @MainActor
    internal static func buildBodies(appTagline: String,
                                     enabledKinds: [ReactionKind],
                                     locale: String) -> [String] {
        var bodies: [String] = [appTagline]
        for kind in enabledKinds {
            let pool = NotificationPhrase.eventBodies(kind: kind, preferredLocale: locale)
            bodies.append(contentsOf: pool)
        }
        // Dedup while preserving the tagline's lead position so the header
        // always reads the brand descriptor first on launch.
        var seen = Set<String>()
        var deduped: [String] = []
        for body in bodies where !body.isEmpty && !seen.contains(body) {
            seen.insert(body)
            deduped.append(body)
        }
        return deduped
    }
}
