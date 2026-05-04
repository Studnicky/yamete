#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import Foundation
import Observation

/// Drives the rotating title/body pair shown at the top of the menu bar
/// dropdown. Pages cycle on a fixed interval; the current page is observed
/// by the SwiftUI HeaderSection which cross-fades between pages on change.
///
/// Page #0 is always the app identity (`app_title` / `app_tagline`) so the
/// header reads "Yamete — your MacBook reacts when you smack it" before
/// any rotation happens. Subsequent pages are sample notification phrasings
/// for every enabled reaction kind, drawn from `NotificationPhrase` in the
/// user's selected locale.
///
/// The rotator is `@MainActor`-isolated and `Sendable` because every
/// observer is on the main actor — no cross-actor send is needed.
@MainActor
@Observable
public final class MenuHeaderRotator {
    public struct Page: Identifiable, Equatable, Sendable {
        public var id: String { title + "|" + body }
        public let title: String
        public let body: String
    }

    public private(set) var current: Page
    private var pages: [Page]
    private var index: Int = 0
    private var task: Task<Void, Never>?
    private let interval: TimeInterval

    /// `interval` clamped to `[1.5s, 30s]` so a misconfigured caller can't
    /// thrash the UI or stall the rotation entirely.
    public init(pages: [Page] = [], interval: TimeInterval = 5.0) {
        let safeInterval = max(1.5, min(30.0, interval))
        self.interval = safeInterval
        let safePages = pages.isEmpty
            ? [Page(title: "", body: "")]
            : pages
        self.pages = safePages
        self.current = safePages[0]
    }

    /// Replace the page set. Resets the cursor to page 0 and the visible
    /// page to the new first entry. Idempotent on equal pages.
    public func setPages(_ newPages: [Page]) {
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
    /// without instantiating the rotator. Mirrors what HeaderSection.onAppear
    /// computes at runtime: the app-identity page first, then one sample
    /// phrasing per enabled reaction kind.
    @MainActor
    internal static func buildPages(appTitle: String,
                                    appTagline: String,
                                    enabledKinds: [ReactionKind],
                                    locale: String) -> [Page] {
        var pages: [Page] = [Page(title: appTitle, body: appTagline)]
        for kind in enabledKinds {
            let pair = NotificationPhrase.eventPhrasing(kind: kind, preferredLocale: locale)
            // Skip kinds whose phrasing is missing (key fallback returns
            // the raw rawValue) so the rotator never lands on a broken page.
            guard !pair.title.isEmpty, pair.title != kind.rawValue else { continue }
            pages.append(Page(title: pair.title, body: pair.body))
        }
        return pages
    }
}
