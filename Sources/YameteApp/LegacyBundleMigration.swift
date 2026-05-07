#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import Foundation

private let log = AppLog(category: "LegacyBundleMigration")

/// One-shot migration from the legacy "Yamete Direct" bundle to the
/// "Yamete+" bundle that ships in 2.4.0. The legacy auto-updater
/// downloads `Yamete.Direct.dmg` and overwrites `/Applications/Yamete
/// Direct.app` with whatever `.app` it finds inside; the 2.4.0 release
/// ships `Yamete+.app` inside that DMG, which lands at the legacy
/// path. This migration runs at app start, detects the legacy path,
/// relocates the bundle to its canonical Yamete+ path, and copies the
/// old `com.studnicky.yamete.direct` UserDefaults to the new
/// `com.studnicky.yamete.plus` identifier so settings carry over.
///
/// Both steps are idempotent — once the relocation has happened the
/// legacy path no longer exists and subsequent launches no-op.
@MainActor
internal enum LegacyBundleMigration {

    /// Legacy bundle path the 2.3.x auto-updater installs to.
    static let legacyAppPath = "/Applications/Yamete Direct.app"
    /// Canonical Yamete+ bundle path.
    static let canonicalAppPath = "/Applications/Yamete+.app"
    /// Pre-2.4.0 bundle identifier that owns the legacy UserDefaults
    /// plist at `~/Library/Preferences/com.studnicky.yamete.direct.plist`.
    static let legacyBundleIdentifier = "com.studnicky.yamete.direct"
    /// Sentinel key written into the new identifier's defaults after
    /// the prefs migration completes; subsequent launches skip the
    /// re-copy and avoid clobbering live settings with stale legacy
    /// values.
    static let prefsMigratedKey = "legacyPrefsMigrated_v2.4"

    /// Detect if the running bundle lives at the legacy path. When
    /// true, copy the bundle to the canonical Yamete+ path, remove
    /// the legacy bundle, launch the new one, and return `true` so the
    /// caller exits the current process. Returns `false` when the
    /// running bundle is already at the canonical path or anywhere
    /// outside `/Applications/` (developer build run from `dist/`).
    static func relocateIfNeeded() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath == legacyAppPath else { return false }

        log.info("activity:Relocate from=\(legacyAppPath) to=\(canonicalAppPath)")
        let fm = FileManager.default

        // Remove any pre-existing canonical bundle so the copy lands
        // cleanly. This handles the (rare) case where both paths
        // coexist after manual intervention.
        if fm.fileExists(atPath: canonicalAppPath) {
            do { try fm.removeItem(atPath: canonicalAppPath) }
            catch {
                log.error("entity:LegacyBundleMigration wasInvalidatedBy activity:RemoveCanonical error=\(error.localizedDescription)")
                return false
            }
        }

        do {
            try fm.copyItem(atPath: legacyAppPath, toPath: canonicalAppPath)
        } catch {
            log.error("entity:LegacyBundleMigration wasInvalidatedBy activity:Copy error=\(error.localizedDescription)")
            return false
        }

        // Drop the legacy bundle. If this fails the user ends up with
        // both bundles present; the next launch from the canonical
        // path no-ops the relocation, and the user can drag the
        // legacy bundle to the trash manually.
        try? fm.removeItem(atPath: legacyAppPath)

        // Launch the new bundle and exit. `open -n` forces a new
        // process rather than activating an existing one so the
        // running (legacy-pathed) instance is fully replaced.
        let openTask = Process()
        openTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openTask.arguments = ["-n", canonicalAppPath]
        do { try openTask.run() }
        catch {
            log.error("entity:LegacyBundleMigration wasInvalidatedBy activity:Relaunch error=\(error.localizedDescription)")
            return false
        }
        log.info("activity:Relocate complete — exiting legacy process")
        return true
    }

    /// Copy every UserDefaults key from the legacy
    /// `com.studnicky.yamete.direct` plist into the live
    /// `com.studnicky.yamete.plus` defaults. Idempotent via
    /// `prefsMigratedKey` sentinel; never overwrites a key that
    /// already exists in the new identifier's defaults.
    static func migrateUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: prefsMigratedKey) else { return }

        guard let legacy = UserDefaults(suiteName: legacyBundleIdentifier) else {
            // No legacy plist on disk (fresh install); record the
            // sentinel so subsequent launches skip the lookup.
            defaults.set(true, forKey: prefsMigratedKey)
            return
        }

        let legacyDict = legacy.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        guard !legacyDict.isEmpty else {
            defaults.set(true, forKey: prefsMigratedKey)
            return
        }

        var copied = 0
        for (key, value) in legacyDict {
            // Don't overwrite a key the new identifier already owns
            // (e.g. user may have launched the new bundle once with
            // settings before triggering migration on a later run).
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: prefsMigratedKey)
        log.info("activity:MigratePrefs copied=\(copied) keys from \(legacyBundleIdentifier)")
    }
}
