#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import Foundation
import Observation

#if DIRECT_BUILD

/// Checks GitHub Releases for new versions of Yamete Direct, downloads the
/// DMG, replaces the installed app, and relaunches. Auto-checks on launch
/// (throttled to once per 4 hours) and exposes manual check/install actions
/// to the UI.
@MainActor @Observable
public final class Updater {
    // MARK: - Public observable state

    let currentVersion: String
    private(set) var state: UpdateState = .idle

    enum UpdateState {
        case idle
        case checking
        case upToDate
        case available(version: String, downloadURL: URL)
        case downloading
        case installing
        case failed(String)
    }

    // MARK: - Constants

    private static let log = AppLog(category: "Updater")
    private static let repo = "Studnicky/yamete"
    private static let checkInterval: TimeInterval = 4 * 60 * 60
    private static let lastCheckKey = "updaterLastCheckDate"
    private static let dmgAssetName = "Yamete.Direct.dmg"
    private static let appName = "Yamete Direct"

    // MARK: - Private state

    private var lastCheckDate: Date?

    // MARK: - Init

    public init() {
        currentVersion = Self.currentVersion(bundle: .main)
        lastCheckDate = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Resolve `CFBundleShortVersionString` from the supplied bundle,
    /// falling back to `"1.0.0"` when the key is missing. Pulled out as
    /// an internal static so unit tests can inject a stub `Bundle`
    /// (whose `infoDictionary` returns nil) to drive the fallback path
    /// — the SPM `xctest` runner's own `Bundle.main` always supplies
    /// a non-nil version, so without the seam the `?? "1.0.0"` branch
    /// is unreachable from tests.
    internal static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - Public API

    /// Check for updates only if the throttle interval has elapsed.
    public func checkIfNeeded() {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < Self.checkInterval {
            Self.log.debug("Update check skipped — last check \(Int(Date().timeIntervalSince(last)))s ago")
            return
        }
        checkForUpdates()
    }

    /// Manually trigger an update check against the GitHub Releases API.
    func checkForUpdates() {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        Task { await performCheck() }
    }

    /// Download the available update, replace the installed app, and relaunch.
    func installUpdate() {
        guard case .available(_, let url) = state else { return }
        state = .downloading
        Task { await performInstall(from: url) }
    }

    // MARK: - Check

    private func performCheck() async {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            state = .failed("Invalid API URL")
            return
        }

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                Self.log.error("Update check HTTP \(code)")
                state = .failed("GitHub API HTTP \(code)")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remote = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            lastCheckDate = Date()
            UserDefaults.standard.set(lastCheckDate, forKey: Self.lastCheckKey)

            if Self.isNewer(remote: remote, local: currentVersion),
               let asset = release.assets.first(where: { $0.name == Self.dmgAssetName }),
               let downloadURL = URL(string: asset.browserDownloadURL) {
                state = .available(version: remote, downloadURL: downloadURL)
                Self.log.info("Update available: v\(remote)")
            } else {
                state = .upToDate
                Self.log.info("Up to date: v\(currentVersion)")
                scheduleIdleReset()
            }
        } catch {
            Self.log.error("Update check failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// After showing "Up to date" for a few seconds, revert to idle.
    private func scheduleIdleReset() {
        Task {
            try? await Task.sleep(for: .seconds(8))
            if case .upToDate = state { state = .idle }
        }
    }

    // MARK: - Install

    private func performInstall(from downloadURL: URL) async {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("yamete-update-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            // Download DMG
            Self.log.info("Downloading \(downloadURL.lastPathComponent)")
            let (tempFile, dlResponse) = try await URLSession.shared.download(for: URLRequest(url: downloadURL))
            guard let http = dlResponse as? HTTPURLResponse, http.statusCode == 200 else {
                state = .failed("Download failed")
                try? fm.removeItem(at: staging)
                return
            }

            let dmgPath = staging.appendingPathComponent("update.dmg")
            try fm.moveItem(at: tempFile, to: dmgPath)

            // Mount DMG
            state = .installing
            Self.log.info("Mounting DMG")
            let mountPoint = staging.appendingPathComponent("vol")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            let mountResult = await Self.runProcess(
                "/usr/bin/hdiutil", "attach", dmgPath.path,
                "-mountpoint", mountPoint.path, "-nobrowse", "-quiet"
            )
            guard mountResult.status == 0 else {
                Self.log.error("hdiutil attach failed: \(mountResult.output)")
                state = .failed("Could not mount update DMG")
                try? fm.removeItem(at: staging)
                return
            }

            // Find .app inside mounted volume
            let volumeContents = (try? fm.contentsOfDirectory(atPath: mountPoint.path)) ?? []
            guard let appBundle = volumeContents.first(where: { $0.hasSuffix(".app") }) else {
                _ = await Self.runProcess("/usr/bin/hdiutil", "detach", mountPoint.path, "-quiet")
                state = .failed("No app found in DMG")
                try? fm.removeItem(at: staging)
                return
            }

            let sourceApp = mountPoint.appendingPathComponent(appBundle)
            let stagedApp = staging.appendingPathComponent(appBundle)

            // Copy to staging (so we don't partially overwrite on failure)
            Self.log.info("Staging \(appBundle)")
            try fm.copyItem(at: sourceApp, to: stagedApp)

            // Unmount DMG (no longer needed)
            _ = await Self.runProcess("/usr/bin/hdiutil", "detach", mountPoint.path, "-quiet")

            // Replace installed app
            let installPath = "/Applications/\(Self.appName).app"
            Self.log.info("Installing to \(installPath)")

            if fm.fileExists(atPath: installPath) {
                try fm.removeItem(atPath: installPath)
            }
            try fm.moveItem(at: stagedApp, to: URL(fileURLWithPath: installPath))

            // Clean up staging directory
            try? fm.removeItem(at: staging)

            // Relaunch
            Self.log.info("Relaunching")
            Self.relaunch(appPath: installPath)

        } catch {
            Self.log.error("Install failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            try? fm.removeItem(at: staging)
        }
    }

    // MARK: - Helpers

    /// Run a process asynchronously without blocking the main actor.
    nonisolated private static func runProcess(_ args: String...) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = Array(args.dropFirst())
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    /// Spawn a watcher script that reopens the app after this process exits,
    /// then terminate the current process.
    private static func relaunch(appPath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(appPath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - GitHub API types

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }
}

#else

/// App Store stub — version display only. Updates delivered through the Store.
@MainActor @Observable
public final class Updater {
    let currentVersion: String

    public init() {
        currentVersion = Self.currentVersion(bundle: .main)
    }

    /// Resolve `CFBundleShortVersionString` from the supplied bundle,
    /// falling back to `"1.0.0"` when the key is missing. Pulled out as
    /// an internal static so unit tests can inject a stub `Bundle`
    /// whose `infoDictionary` returns nil — the SPM `xctest` runner's
    /// own `Bundle.main` always supplies a non-nil version, so without
    /// the seam the `?? "1.0.0"` branch would be unreachable.
    internal static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// No-op for App Store builds (updates come through the Store).
    public func checkIfNeeded() {}
}

#endif

// MARK: - SemVer 2.0 ordering
//
// Defined OUTSIDE the `#if DIRECT_BUILD` block so the helper is compiled
// (and unit-testable) under both build variants. The Direct branch uses
// `Self.isNewer(...)` from `performCheck`; the App Store branch never
// calls it but the static remains attached so the catalog's mutation
// cells link under bare `swift test`. See <https://semver.org/spec/v2.0.0.html>
// section 11 for the canonical ordering rules implemented below.
extension Updater {
    /// Strict-newer comparator following SemVer 2.0.0 §11 ordering.
    ///
    /// Algorithm:
    ///  1. Strip the first `-` (pre-release) or `+` (build metadata)
    ///     and everything after it to obtain the version core.
    ///  2. Parse the core as up to three dot-separated integers
    ///     (major, minor, patch); missing components default to 0.
    ///  3. Compare cores in (major, minor, patch) order.
    ///  4. If cores compare equal, a release version (no pre-release
    ///     suffix) is strictly NEWER than any pre-release version with
    ///     the same core.
    ///  5. If both have pre-release suffixes, compare per dot-separated
    ///     identifier: numeric vs numeric by integer value; numeric is
    ///     LOWER than alphanumeric; alphanumeric vs alphanumeric by
    ///     ASCII lexicographic order. The longer suffix wins as a
    ///     tiebreaker when all leading identifiers are equal.
    ///  6. Build metadata (`+...`) is ignored for ordering, per §10.
    internal static func isNewer(remote: String, local: String) -> Bool {
        let rParts = versionParts(remote)
        let lParts = versionParts(local)

        // Compare cores first.
        for i in 0..<3 {
            if rParts.core[i] > lParts.core[i] { return true }
            if rParts.core[i] < lParts.core[i] { return false }
        }

        // Cores equal. Apply pre-release ordering rules.
        switch (rParts.preRelease, lParts.preRelease) {
        case (nil, nil):
            return false                  // identical releases
        case (nil, _?):
            return true                   // release > pre-release
        case (_?, nil):
            return false                  // pre-release < release
        case (let r?, let l?):
            return comparePreRelease(r, l) == .orderedDescending
        }
    }

    /// Decompose a SemVer string into its (core, pre-release) parts.
    /// `core` is always exactly three integers (missing components → 0).
    /// `preRelease` is the dot-split identifier list, or `nil` when no
    /// `-` suffix is present. Build metadata (`+...`) is stripped.
    private static func versionParts(_ version: String) -> (core: [Int], preRelease: [String]?) {
        // Strip build metadata first (per §10, ignored for ordering).
        let withoutBuild: Substring
        if let plusIdx = version.firstIndex(of: "+") {
            withoutBuild = version[..<plusIdx]
        } else {
            withoutBuild = Substring(version)
        }

        let coreString: Substring
        let preReleaseString: Substring?
        if let dashIdx = withoutBuild.firstIndex(of: "-") {
            coreString = withoutBuild[..<dashIdx]
            preReleaseString = withoutBuild[withoutBuild.index(after: dashIdx)...]
        } else {
            coreString = withoutBuild
            preReleaseString = nil
        }

        // Parse up to 3 dot-separated integers; missing → 0; non-numeric → 0
        // (defensive — malformed tags don't crash the updater).
        let coreInts = coreString.split(separator: ".").map { Int($0) ?? 0 }
        var core = [0, 0, 0]
        for i in 0..<min(coreInts.count, 3) {
            core[i] = coreInts[i]
        }

        let preRelease = preReleaseString.map { suffix -> [String] in
            suffix.split(separator: ".").map(String.init)
        }
        return (core, preRelease)
    }

    /// Per-identifier pre-release comparison per SemVer 2.0.0 §11.4.
    /// Returns `.orderedAscending` when `lhs < rhs`, `.orderedDescending`
    /// when `lhs > rhs`, `.orderedSame` when equal.
    private static func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for i in 0..<min(lhs.count, rhs.count) {
            let a = lhs[i]
            let b = rhs[i]
            let aNum = Int(a)
            let bNum = Int(b)
            switch (aNum, bNum) {
            case (let x?, let y?):
                if x < y { return .orderedAscending }
                if x > y { return .orderedDescending }
            case (_?, nil):
                // numeric identifiers always have lower precedence than alphanumeric
                return .orderedAscending
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                if a < b { return .orderedAscending }
                if a > b { return .orderedDescending }
            }
        }
        // All compared identifiers equal: the LONGER suffix wins (§11.4.4).
        if lhs.count < rhs.count { return .orderedAscending }
        if lhs.count > rhs.count { return .orderedDescending }
        return .orderedSame
    }
}
