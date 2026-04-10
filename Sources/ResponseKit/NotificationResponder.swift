#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import os
@preconcurrency import UserNotifications

private let notificationLog = AppLog(category: "NotificationResponder")

/// Presents impact reactions as user notifications instead of full-screen overlays.
@MainActor
public final class NotificationResponder: VisualResponder {
    private static let notificationID = "yamete-impact-response"
    private static let threadID = "yamete-impact-thread"

    private var cleanupTask: Task<Void, Never>?

    /// Resolves the locale identifier used for notification body strings on
    /// every post. A closure (not a stored string) so settings changes are
    /// reflected on the next impact without rebuilding the responder.
    private let localeProvider: @MainActor () -> String

    public init(localeProvider: @escaping @MainActor () -> String = { Bundle.main.preferredLocalizations.first ?? "en" }) {
        self.localeProvider = localeProvider
    }

    public static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    notificationLog.error("activity:NotificationPermission wasInvalidatedBy entity:AuthorizationRequest — \(error.localizedDescription)")
                    return
                }
                notificationLog.info("activity:NotificationPermission wasGeneratedBy entity:AuthorizationRequest granted=\(granted)")
            }
        }
    }

    public func flash(intensity: Float, opacityMin _: Float, opacityMax _: Float, clipDuration _: Double, dismissAfter: Double, enabledDisplayIDs _: [Int]) {
        Self.requestAuthorizationIfNeeded()

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    await self.postNotification(intensity: intensity, dismissAfter: dismissAfter)
                }
            case .denied:
                notificationLog.warning("activity:NotificationDelivery wasInvalidatedBy entity:NotificationPermission status=denied")
            case .notDetermined:
                notificationLog.info("activity:NotificationDelivery isPendingOn entity:NotificationPermission")
            @unknown default:
                notificationLog.warning("activity:NotificationDelivery wasInvalidatedBy entity:NotificationPermission status=unknown")
            }
        }
    }

    private func postNotification(intensity: Float, dismissAfter: Double) async {
        let center = UNUserNotificationCenter.current()
        let identifier = Self.notificationID
        let tier = ImpactTier.from(intensity: intensity)

        // Single source of truth for the whole notification: resolve once to
        // a locale that has BOTH title and moan pools, then pass that same
        // localeID to both phrase lookups. Prevents the "English title +
        // French body" mismatch when a locale has moans but not yet titles.
        let localeID = NotificationPhrase.resolveLocale(preferred: localeProvider(), for: tier)

        let content = UNMutableNotificationContent()
        content.title = NotificationPhrase.title(for: tier, localeID: localeID)
        content.body = NotificationPhrase.moan(for: tier, localeID: localeID)
        content.threadIdentifier = Self.threadID
        content.categoryIdentifier = Self.threadID
        content.sound = nil

        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            notificationLog.info("activity:NotificationDelivery wasStartedBy entity:ImpactNotification tier=\(tier)")
        } catch {
            notificationLog.error("activity:NotificationDelivery wasInvalidatedBy entity:ImpactNotification — \(error.localizedDescription)")
            return
        }

        cleanupTask?.cancel()
        cleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0.1, dismissAfter)))
            guard !Task.isCancelled else { return }
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            notificationLog.info("activity:NotificationDelivery wasEndedBy entity:ImpactNotification")
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
/// Internal (not private) so `@testable import ResponseKit` can cover it.
enum NotificationPhrase {
    /// Cache: localeID → "title_tap" → ["Mm, again?", "Tease~", ...]
    private static let cache = OSAllocatedUnfairLock<[String: [String: [String]]]>(initialState: [:])
    private static let fallbackLocaleID = "en"

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

    /// Clears the pool cache so tests don't leak state across runs.
    static func _testClear() {
        cache.withLock { cache in cache.removeAll() }
    }
}
