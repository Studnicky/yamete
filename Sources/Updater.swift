import AppKit
import CommonCrypto
import Foundation

private let log = AppLog(category: "Updater")

/// Checks GitHub releases and installs verified app updates.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case available(String)
        case downloading(String)
        case readyToRestart
        case upToDate
        case failed(String)
    }

    var state: State = .idle

    private let repo = "Studnicky/yamete"
    private let expectedBundleID = "com.yamete"
    private let expectedTeamID: String?
    private let currentVersion: String
    private let checkInterval: TimeInterval = 24 * 60 * 60

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        expectedTeamID = Self.teamIdentifier(appPath: Bundle.main.bundlePath)
    }

    // MARK: - Public API

    func autoCheckIfNeeded(settings: SettingsStore) {
        guard settings.autoCheckForUpdates else { return }
        let elapsed = Date.now.timeIntervalSince1970 - settings.lastUpdateCheck
        guard elapsed >= checkInterval else { return }
        settings.lastUpdateCheck = Date.now.timeIntervalSince1970

        log.info("activity:AutoUpdateCheck wasStartedBy agent:Updater interval=\(String(format: "%.0f", elapsed))s")
        state = .checking

        Task { @MainActor in
            do {
                let release = try await fetchLatestRelease()
                if isNewer(release.version, than: currentVersion) {
                    state = .available(release.version)
                    promptUserForUpdate(version: release.version)
                } else {
                    state = .idle
                }
            } catch {
                state = .idle
                log.debug("activity:AutoUpdateCheck wasInvalidatedBy entity:Error — \(error.localizedDescription)")
            }
        }
    }

    func checkForUpdate() {
        guard state == .idle || state == .upToDate || state.isFailed else { return }
        state = .checking
        log.info("activity:UpdateCheck wasStartedBy agent:Updater current=\(currentVersion)")

        Task { @MainActor in
            do {
                let release = try await fetchLatestRelease()
                if isNewer(release.version, than: currentVersion) {
                    state = .available(release.version)
                } else {
                    state = .upToDate
                    try? await Task.sleep(for: .seconds(3))
                    if state == .upToDate { state = .idle }
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func downloadAndInstall() {
        guard case .available(let version) = state else { return }
        state = .downloading(version)

        Task { @MainActor in
            do {
                let tag = version.hasPrefix("v") ? version : "v\(version)"
                let release = try await fetchRelease(tag: tag)
                let dmgURL = try await downloadDMG(release: release)

                guard let expectedHash = release.sha256 else {
                    try? FileManager.default.removeItem(at: dmgURL)
                    throw UpdateError.missingChecksum
                }

                let actualHash = try sha256(of: dmgURL)
                guard actualHash == expectedHash.lowercased() else {
                    try? FileManager.default.removeItem(at: dmgURL)
                    log.error("activity:Install wasInvalidatedBy entity:ChecksumMismatch expected=\(expectedHash) actual=\(actualHash)")
                    throw UpdateError.checksumMismatch
                }
                log.info("entity:DMG wasVerifiedBy activity:ChecksumVerify sha256=\(actualHash)")

                try await installFromDMG(dmgURL)
                state = .readyToRestart
                promptUserToRestart(version: release.version)
            } catch {
                state = .failed(error.localizedDescription)
                log.error("activity:Install wasInvalidatedBy entity:Error — \(error.localizedDescription)")
            }
        }
    }

    func relaunch() {
        let appPath = Bundle.main.bundlePath
        // Spawn a helper process that reopens the app after termination.
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-W", "-n", "-a", appPath, "--args", "--relaunched"]
        // Use GCD so relaunch scheduling survives app termination.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            try? task.run()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func promptUserForUpdate(version: String) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Yamete v%@ Available", comment: "Update available title"), version)
        alert.informativeText = String(format: NSLocalizedString("A new version is available. Would you like to install it now?\n\nYou're currently running v%@.", comment: "Update available body"), currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Install Update", comment: "Update button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Dismiss button"))
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall()
        } else {
            state = .available(version)
        }
    }

    private func promptUserToRestart(version: String) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Yamete v%@ Installed", comment: "Update installed title"), version)
        alert.informativeText = NSLocalizedString("The update has been installed and verified. Restart Yamete to use the new version.", comment: "Update installed body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: "Restart button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Dismiss button"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    // MARK: - Release metadata

    private struct Release {
        let tag: String
        let version: String
        let sha256: String?
    }

    private func fetchLatestRelease() async throws -> Release {
        try await fetchRelease(tag: nil)
    }

    private func fetchRelease(tag: String?) async throws -> Release {
        let endpoint = tag.map { "releases/tags/\($0)" } ?? "releases/latest"
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/\(endpoint)") else {
            throw UpdateError.parseError
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.networkError
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateError.parseError
        }
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        var sha256: String? = nil
        if let body = json["body"] as? String {
            let pattern = #"(?i)sha-?256[:\s`]+([0-9a-f]{64})"#
            if let range = body.range(of: pattern, options: .regularExpression),
               let hexRange = body[range].range(of: #"[0-9a-f]{64}"#, options: .regularExpression) {
                sha256 = String(body[hexRange]).lowercased()
            }
        }

        return Release(tag: tagName, version: version, sha256: sha256)
    }

    // MARK: - Download + install

    private func downloadDMG(release: Release) async throws -> URL {
        guard let dmgURL = URL(string: "https://github.com/\(repo)/releases/download/\(release.tag)/Yamete.dmg") else {
            throw UpdateError.parseError
        }
        let (tempURL, response) = try await URLSession.shared.download(from: dmgURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Yamete-\(release.version).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static let mountTimeout: TimeInterval = 30

    private func installFromDMG(_ dmgPath: URL) async throws {
        let mountPoint = "/Volumes/Yamete-Update"

        let mount = Process()
        mount.launchPath = "/usr/bin/hdiutil"
        mount.arguments = ["attach", dmgPath.path, "-mountpoint", mountPoint, "-quiet", "-nobrowse"]
        try mount.run()

        let deadline = Date().addingTimeInterval(Self.mountTimeout)
        while mount.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if mount.isRunning {
            mount.terminate()
            log.error("activity:Install wasInvalidatedBy entity:MountTimeout after=\(Self.mountTimeout)s")
            throw UpdateError.mountFailed
        }
        guard mount.terminationStatus == 0 else { throw UpdateError.mountFailed }

        defer {
            let unmount = Process()
            unmount.launchPath = "/usr/bin/hdiutil"
            unmount.arguments = ["detach", mountPoint, "-quiet"]
            try? unmount.run()
            unmount.waitUntilExit()
            try? FileManager.default.removeItem(at: dmgPath)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.appNotFound
        }
        let sourceApp = mountPoint + "/" + appName

        // Security: verify code signature
        let codesign = Process()
        codesign.launchPath = "/usr/bin/codesign"
        codesign.arguments = ["--verify", "--deep", "--strict", sourceApp]
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            log.error("activity:Install wasInvalidatedBy entity:InvalidSignature path=\(sourceApp)")
            throw UpdateError.signatureInvalid
        }
        log.info("entity:AppBundle wasVerifiedBy activity:CodesignVerify")

        // Verify bundle identifier.
        let plistPath = sourceApp + "/Contents/Info.plist"
        guard let plist = NSDictionary(contentsOfFile: plistPath),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleID else {
            log.error("activity:Install wasInvalidatedBy entity:BundleIDMismatch")
            throw UpdateError.bundleIDMismatch
        }
        log.info("entity:AppBundle wasVerifiedBy activity:BundleIDCheck id=\(bundleID)")

        if let expectedTeamID,
           let actualTeamID = Self.teamIdentifier(appPath: sourceApp),
           actualTeamID != expectedTeamID {
            log.error("activity:Install wasInvalidatedBy entity:TeamIDMismatch expected=\(expectedTeamID) actual=\(actualTeamID)")
            throw UpdateError.teamIDMismatch
        }

        // Replace current app bundle.
        let destApp = Bundle.main.bundlePath
        let fm = FileManager.default
        let backup = destApp + ".bak"
        try? fm.removeItem(atPath: backup)
        try fm.moveItem(atPath: destApp, toPath: backup)
        do {
            try fm.copyItem(atPath: sourceApp, toPath: destApp)
            try? fm.removeItem(atPath: backup)
        } catch {
            try? fm.moveItem(atPath: backup, toPath: destApp)
            throw UpdateError.installFailed
        }
    }

    private static func teamIdentifier(appPath: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["-dv", "--verbose=4", appPath]

        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0,
              let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                return String(line.dropFirst("TeamIdentifier=".count))
            }
        }
        return nil
    }

    // MARK: - Crypto

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Version comparison

    private func isNewer(_ remote: String, than local: String) -> Bool {
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

    private enum UpdateError: LocalizedError {
        case networkError, parseError, downloadFailed, mountFailed
        case appNotFound, installFailed
        case missingChecksum, checksumMismatch, signatureInvalid, bundleIDMismatch, teamIDMismatch

        var errorDescription: String? {
            switch self {
            case .networkError:      NSLocalizedString("Could not reach GitHub", comment: "Update error")
            case .parseError:        NSLocalizedString("Could not parse release info", comment: "Update error")
            case .downloadFailed:    NSLocalizedString("DMG download failed", comment: "Update error")
            case .mountFailed:       NSLocalizedString("Could not mount DMG", comment: "Update error")
            case .appNotFound:       NSLocalizedString("No app found in DMG", comment: "Update error")
            case .installFailed:     NSLocalizedString("Could not replace app bundle", comment: "Update error")
            case .missingChecksum:   NSLocalizedString("Release is missing SHA256 checksum", comment: "Update error")
            case .checksumMismatch:  NSLocalizedString("Download corrupted — SHA256 mismatch", comment: "Update error")
            case .signatureInvalid:  NSLocalizedString("Code signature verification failed", comment: "Update error")
            case .bundleIDMismatch:  NSLocalizedString("App bundle identifier mismatch", comment: "Update error")
            case .teamIDMismatch:    NSLocalizedString("Code signing team mismatch", comment: "Update error")
            }
        }
    }
}

extension Updater.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
