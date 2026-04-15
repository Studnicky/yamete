#if canImport(YameteCore)
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
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        lastCheckDate = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: - Public API

    /// Check for updates only if the throttle interval has elapsed.
    func checkIfNeeded() {
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

    /// Semantic version comparison: true when remote is strictly newer.
    private static func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

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
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// No-op for App Store builds (updates come through the Store).
    func checkIfNeeded() {}
}

#endif
