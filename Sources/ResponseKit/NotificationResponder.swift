#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
import os
@preconcurrency import UserNotifications

private let notificationLog = AppLog(category: "NotificationResponder")

/// Presents impact reactions as user notifications instead of full-screen overlays.
///
/// Hardware boundary: `SystemNotificationDriver`. Default initializer wires a
/// `RealSystemNotificationDriver` (UNUserNotificationCenter). Tests inject a
/// mock that records every post + lets a test stage authorization status.
@MainActor
public final class NotificationResponder: ReactiveOutput {
    private static let notificationID = "yamete-impact-response"
    private static let threadID = "yamete-impact-thread"

    private let driver: SystemNotificationDriver

    /// Resolves the locale identifier used for notification body strings on
    /// every post. A closure (not a stored string) so settings changes are
    /// reflected on the next impact without rebuilding the responder.
    private let localeProvider: @MainActor () -> String

    public convenience init(localeProvider: @escaping @MainActor () -> String = { Bundle.main.preferredLocalizations.first ?? "en" }) {
        self.init(driver: RealSystemNotificationDriver(), localeProvider: localeProvider)
    }

    public init(driver: SystemNotificationDriver,
                localeProvider: @escaping @MainActor () -> String = { Bundle.main.preferredLocalizations.first ?? "en" }) {
        self.driver = driver
        self.localeProvider = localeProvider
        super.init()
    }

    // MARK: - ReactiveOutput lifecycle

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        let c = provider.notificationConfig()
        return c.enabled && c.perReaction[fired.kind] != false
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        let config = provider.notificationConfig()
        await postReaction(fired.reaction, dismissAfter: config.dismissAfter)
        try? await Task.sleep(for: .seconds(max(0.1, config.dismissAfter)))
    }

    override public func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        driver.remove(identifier: Self.notificationID)
    }

    override public func reset() {
        driver.remove(identifier: Self.notificationID)
    }

    private func postReaction(_ reaction: Reaction, dismissAfter: Double) async {
        await requestAuthorizationIfNeeded()
        let auth = await driver.currentAuthorization()
        switch auth {
        case .authorized, .provisional, .ephemeral:
            await postNotification(reaction: reaction, dismissAfter: dismissAfter)
        case .denied:
            notificationLog.warning("activity:NotificationDelivery wasInvalidatedBy entity:NotificationPermission status=denied")
        case .notDetermined:
            notificationLog.info("activity:NotificationDelivery isPendingOn entity:NotificationPermission")
        case .unknown:
            notificationLog.warning("activity:NotificationDelivery wasInvalidatedBy entity:NotificationPermission status=unknown")
        }
    }

    private func postNotification(reaction: Reaction, dismissAfter: Double) async {
        let phrasing = NotificationPhrase.phrasing(for: reaction, preferredLocale: localeProvider())
        let content = NotificationContent(
            title: phrasing.title,
            body: phrasing.body,
            threadID: Self.threadID,
            categoryID: Self.threadID,
            // macOS suppresses passive notifications when the app is active or under Focus.
            // .active forces banner display regardless. relevanceScore biases sort order so
            // multiple rapid reactions don't get coalesced/hidden in Notification Center.
            interruptionLevel: .active,
            relevanceScore: 1.0
        )
        do {
            try await driver.post(content: content, identifier: Self.notificationID)
            notificationLog.info("activity:NotificationDelivery wasStartedBy entity:ReactionNotification kind=\(reaction.kind.rawValue)")
        } catch {
            notificationLog.error("activity:NotificationDelivery wasInvalidatedBy entity:ReactionNotification — \(error.localizedDescription)")
        }
    }

    private func requestAuthorizationIfNeeded() async {
        let auth = await driver.currentAuthorization()
        guard auth == .notDetermined else { return }
        let granted = await driver.requestAuthorization()
        notificationLog.info("activity:NotificationPermission wasGeneratedBy entity:AuthorizationRequest granted=\(granted)")
    }

    /// Convenience for non-test callers (`Yamete.bootstrap`) that just want to
    /// kick the system permission dialog at launch on a fresh install.
    /// Skips when running under `swift test` / `xctest` because
    /// `UNUserNotificationCenter.currentNotificationCenter` raises
    /// `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is
    /// nil") whenever `Bundle.main.bundleURL` resolves to the xctest
    /// runner instead of an app bundle. The exception cannot be caught
    /// from Swift and crashes the entire process — including any other
    /// test that happens to be running when the dispatched Task fires
    /// (the call is async fire-and-forget). Skipping under the runner
    /// is the production-safe fix; the integration surface is exercised
    /// via `xcodebuild test` against the YameteTests scheme bundled
    /// inside the host app.
    public static func requestAuthorizationIfNeeded() {
        let bundleURL = Bundle.main.bundleURL.path
        let isUnderXctestRunner = bundleURL.contains("/Xcode.app/")
            || bundleURL.contains("/usr/bin")
            || Bundle.main.bundleIdentifier == nil
        guard !isUnderXctestRunner else { return }
        Task { @MainActor in
            let driver = RealSystemNotificationDriver()
            let auth = await driver.currentAuthorization()
            guard auth == .notDetermined else { return }
            _ = await driver.requestAuthorization()
        }
    }

}

// MARK: - Notification phrase variants

/// Random tier-specific phrase pools loaded from each locale's `Localizable.strings`.
///
/// Two independent prefixes per tier:
///   • `title_<tier>_<n>` — flirty observational label (notification title)
///   • `moan_<tier>_<n>`  — breathless reaction        (notification body)
///
/// At first use for a locale, the entire `.strings` file is parsed once and any
/// key matching `<prefix>_<tier>_<digit>` is grouped into a `[String]` array.
/// Variant counts can vary per locale; no hardcoded `variantsPerTier`.
/// Falls back to `en` arrays when a locale has no entries for a given pool.
///
/// `public` because `MenuHeaderRotator` in YameteApp consumes
/// `eventPhrasing(...)` to build its rotation pages from sample phrasings.
public enum NotificationPhrase {
    /// Cache: localeID → "title_tap" → ["Mm, again?", "Tease~", ...]
    private static let cache = OSAllocatedUnfairLock<[String: [String: [String]]]>(initialState: [:])
    /// Separate cache for `Events.strings` so impact-pool clears don't blow
    /// it away (and vice-versa).
    private static let eventCache = OSAllocatedUnfairLock<[String: [String: [String]]]>(initialState: [:])
    /// When true, `loadPools` and `loadEventPools` short-circuit to empty
    /// regardless of bundle content. Set via the `_testClearAndDisableLoad`
    /// seam so tests pinning the documented fallback shape (title=key,
    /// body="") run identically under SPM (no resources) and host-app (real
    /// `Events.strings` shipped). Without this seam, the host-app test
    /// bundle inherits `Yamete.app`'s `Events.strings` and the loader
    /// returns authored strings, so the fallback path never runs and any
    /// test asserting fallback output fails.
    ///
    /// The flag is unguarded by `#if DEBUG` for the same reason the
    /// existing `_testInject` / `_testClear` seams are: ResponseKit
    /// compiles under both SPM (which auto-defines `DEBUG`) and the
    /// xcodebuild package-product path used by `make test-host-app`
    /// (which does NOT define `DEBUG` at the package layer). Gating on
    /// `DEBUG` would orphan the seam under host-app and reintroduce the
    /// exact failure this seam exists to fix. The flag has no effect in
    /// release builds because no production code path flips it.
    private static let loadDisabled = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let fallbackLocaleID = "en"

    /// Returns the (title, body) pair for any reaction. Impacts route through
    /// the existing tier-based moan pools; events route through the
    /// `Events.strings` table keyed by reaction kind.
    static func phrasing(for reaction: Reaction, preferredLocale: String) -> (title: String, body: String) {
        if case .impact(let fused) = reaction {
            let tier = ImpactTier.from(intensity: fused.intensity)
            let localeID = resolveLocale(preferred: preferredLocale, for: tier)
            return (title: title(for: tier, localeID: localeID),
                    body:  moan(for: tier, localeID: localeID))
        }
        return eventPhrasing(kind: reaction.kind, preferredLocale: preferredLocale)
    }

    public static func eventPhrasing(kind: ReactionKind, preferredLocale: String) -> (title: String, body: String) {
        let key = kind.rawValue
        let preferredPools = eventPools(for: preferredLocale)
        let preferredTitle = preferredPools["title_\(key)"]?.randomElement()
        let preferredBody = preferredPools["body_\(key)"]?.randomElement()
        if let preferredTitle, let preferredBody {
            return (preferredTitle, preferredBody)
        }
        let fallbackPools = eventPools(for: fallbackLocaleID)
        return (
            title: preferredTitle ?? fallbackPools["title_\(key)"]?.randomElement() ?? key,
            body:  preferredBody  ?? fallbackPools["body_\(key)"]?.randomElement() ?? ""
        )
    }

    private static func eventPools(for localeID: String) -> [String: [String]] {
        eventCache.withLock { cache in
            if let cached = cache[localeID] { return cached }
            let loaded = loadEventPools(localeID: localeID)
            cache[localeID] = loaded
            return loaded
        }
    }

    /// Parses `Events.strings` for a locale into `title_<kind>` /
    /// `body_<kind>` arrays. Same numbered-suffix convention as `Moans.strings`.
    private static func loadEventPools(localeID: String) -> [String: [String]] {
        if loadDisabled.withLock({ $0 }) { return [:] }
        guard let lprojPath = Bundle.main.path(forResource: localeID, ofType: "lproj"),
              let stringsPath = Bundle(path: lprojPath)?.path(forResource: "Events", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: String]
        else { return [:] }
        var pools: [String: [String]] = [:]
        for (key, value) in dict {
            let parts = key.split(separator: "_")
            guard parts.count == 3,
                  parts[0] == "title" || parts[0] == "body",
                  Int(parts[2]) != nil
            else { continue }
            let group = "\(parts[0])_\(parts[1])"
            pools[group, default: []].append(value)
        }
        return pools
    }

    /// Resolves a preferred locale to one that has BOTH `title_<tier>` and
    /// `moan_<tier>` pools populated. Falls back to `en` if either pool is
    /// missing or empty in the preferred locale. The whole notification is
    /// then guaranteed to come from the same language.
    static func resolveLocale(preferred: String, for tier: ImpactTier) -> String {
        let titleKey = "title_\(slug(for: tier))"
        let moanKey = "moan_\(slug(for: tier))"
        let preferredPools = pools(for: preferred)
        let hasTitle = !(preferredPools[titleKey]?.isEmpty ?? true)
        let hasMoan = !(preferredPools[moanKey]?.isEmpty ?? true)
        if hasTitle && hasMoan { return preferred }
        return fallbackLocaleID
    }

    static func title(for tier: ImpactTier, localeID: String) -> String {
        pick(prefix: "title", tier: tier, localeID: localeID)
    }

    static func moan(for tier: ImpactTier, localeID: String) -> String {
        pick(prefix: "moan", tier: tier, localeID: localeID)
    }

    private static func pick(prefix: String, tier: ImpactTier, localeID: String) -> String {
        let groupKey = "\(prefix)_\(slug(for: tier))"
        return pools(for: localeID)[groupKey]?.randomElement() ?? ""
    }

    /// Returns the cached phrase pools for a locale, loading on first access.
    private static func pools(for localeID: String) -> [String: [String]] {
        cache.withLock { cache in
            if let cached = cache[localeID] { return cached }
            let loaded = loadPools(localeID: localeID)
            cache[localeID] = loaded
            return loaded
        }
    }

    /// Parses `Moans.strings` for a locale into prefix-grouped arrays.
    /// Lives in its own table (not `Localizable.strings`) so the App Store
    /// build ships tame content while the Direct build overlays spicy content
    /// from `App/Resources-Direct/{locale}.lproj/Moans.strings` at bundle time.
    /// `NSDictionary(contentsOfFile:)` auto-handles both text and binary plist
    /// formats — the same loader Foundation uses internally for `.strings`.
    private static func loadPools(localeID: String) -> [String: [String]] {
        if loadDisabled.withLock({ $0 }) { return [:] }
        guard let lprojPath = Bundle.main.path(forResource: localeID, ofType: "lproj"),
              let stringsPath = Bundle(path: lprojPath)?.path(forResource: "Moans", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: String]
        else { return [:] }

        var pools: [String: [String]] = [:]
        for (key, value) in dict {
            // Match `title_tap_1`, `moan_hard_4`, etc.
            let parts = key.split(separator: "_")
            guard parts.count == 3,
                  parts[0] == "title" || parts[0] == "moan",
                  Int(parts[2]) != nil
            else { continue }
            let group = "\(parts[0])_\(parts[1])"
            pools[group, default: []].append(value)
        }
        return pools
    }

    private static func slug(for tier: ImpactTier) -> String {
        switch tier {
        case .tap:    "tap"
        case .light:  "light"
        case .medium: "medium"
        case .firm:   "firm"
        case .hard:   "hard"
        }
    }

    // MARK: - Test seam

    /// Injects a pre-built pool dictionary for a locale, bypassing the
    /// `Localizable.strings` loader. The `.lproj` resources live in
    /// `App/Resources/` and are bundled into the `.app` by the Makefile —
    /// not the SPM test runner — so tests cannot exercise the real loader.
    /// This seam lets tests verify the resolution/selection logic with
    /// controlled inputs.
    static func _testInject(pools: [String: [String]], for localeID: String) {
        cache.withLock { cache in cache[localeID] = pools }
    }

    /// Injects a pre-built event-pool dictionary for a locale, bypassing the
    /// `Events.strings` loader. Mirrors `_testInject` but for the separate
    /// event cache used by non-impact reactions.
    static func _testInjectEvents(pools: [String: [String]], for localeID: String) {
        eventCache.withLock { cache in cache[localeID] = pools }
    }

    /// Clears the pool cache so tests don't leak state across runs. Also
    /// re-enables the bundle-driven loader in case a prior cell flipped
    /// `loadDisabled` via `_testClearAndDisableLoad`.
    static func _testClear() {
        cache.withLock { cache in cache.removeAll() }
        eventCache.withLock { cache in cache.removeAll() }
        loadDisabled.withLock { $0 = false }
    }

    /// Clears every cached pool AND disables the bundle-driven loader for
    /// the remainder of the test process or until `_testClear` is called.
    /// With load disabled, `eventPhrasing` and `phrasing` always traverse
    /// the documented fallback path (title=key, body=""). Required under
    /// host-app where `Bundle.main` is a real `Yamete.app` and ships
    /// `Events.strings`/`Moans.strings`; without the seam, the loader
    /// hands back authored strings and the fallback contract can never be
    /// observed. Mirrors the always-available shape of `_testInject` /
    /// `_testClear` (no `#if DEBUG`) because the host-app package-product
    /// build of ResponseKit does not inherit the test target's DEBUG flag.
    static func _testClearAndDisableLoad() {
        cache.withLock { cache in cache.removeAll() }
        eventCache.withLock { cache in cache.removeAll() }
        loadDisabled.withLock { $0 = true }
    }
}
