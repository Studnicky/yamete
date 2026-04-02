import AppKit
import CommonCrypto
import Foundation

private let log = AppLog(category: "Updater")

/// Self-updater that checks GitHub Releases for newer versions.
///
/// Security: after downloading, the update is verified before installation:
/// 1. SHA256 checksum of the DMG is compared against the release manifest
/// 2. Extracted .app must pass `codesign --verify --deep`
/// 3. Bundle identifier must match `com.yamete`
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case available(String)
        case downloading(String)
        case readyToRestart
        case upToDate
        case failed(String)
    }

    @Published var state: State = .idle

    private let repo = "Studnicky/yamete"
    private let expectedBundleID = "com.yamete"
    private let currentVersion: String
    private let checkInterval: TimeInterval = 24 * 60 * 60

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Public API

    func autoCheckIfNeeded(settings: SettingsStore) {
        guard settings.autoCheckForUpdates else { return }
        let elapsed = Date.now.timeIntervalSince1970 - settings.lastUpdateCheck
        guard elapsed >= checkInterval else { return }
        settings.lastUpdateCheck = Date.now.timeIntervalSince1970

        log.info("activity:AutoUpdateCheck wasStartedBy agent:Updater interval=\(String(format: "%.0f", elapsed))s")
        state = .checking

        Task {
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

        Task {
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

        Task {
            do {
                let release = try await fetchLatestRelease()
                let dmgURL = try await downloadDMG(version: version)

                // Security: verify SHA256 checksum if manifest provides one
                if let expectedHash = release.sha256 {
                    let actualHash = try sha256(of: dmgURL)
                    guard actualHash == expectedHash.lowercased() else {
                        try? FileManager.default.removeItem(at: dmgURL)
                        log.error("activity:Install wasInvalidatedBy entity:ChecksumMismatch expected=\(expectedHash) actual=\(actualHash)")
                        throw UpdateError.checksumMismatch
                    }
                    log.info("entity:DMG wasVerifiedBy activity:ChecksumVerify sha256=\(actualHash)")
                }

                try await installFromDMG(dmgURL)
                state = .readyToRestart
                promptUserToRestart(version: version)
            } catch {
                state = .failed(error.localizedDescription)
                log.error("activity:Install wasInvalidatedBy entity:Error — \(error.localizedDescription)")
            }
        }
    }

    func relaunch() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func promptUserForUpdate(version: String) {
        let alert = NSAlert()
        alert.messageText = "Yamete v\(version) Available"
        alert.informativeText = "A new version is available. Would you like to install it now?\n\nYou're currently running v\(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall()
        } else {
            state = .available(version)
        }
    }

    private func promptUserToRestart(version: String) {
        let alert = NSAlert()
        alert.messageText = "Yamete v\(version) Installed"
        alert.informativeText = "The update has been installed and verified. Restart Yamete to use the new version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    // MARK: - Release metadata

    private struct Release {
        let version: String
        let sha256: String?
    }

    private func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.networkError
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw UpdateError.parseError
        }
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        // Parse SHA256 from release body: look for "sha256: <hex>" or "SHA256: <hex>"
        var sha256: String? = nil
        if let body = json["body"] as? String {
            let pattern = #"(?i)sha256:\s*([0-9a-f]{64})"#
            if let match = body.range(of: pattern, options: .regularExpression) {
                let hashStart = body[match].dropFirst(body[match].contains(":") ? body[match].distance(from: match.lowerBound, to: body[match].firstIndex(of: ":")!) + 1 : 7)
                let trimmed = hashStart.trimmingCharacters(in: .whitespaces)
                if trimmed.count == 64 { sha256 = trimmed.lowercased() }
            }
            // Simpler fallback: find any 64-char hex string after "sha256"
            if sha256 == nil, let range = body.range(of: #"(?i)sha256[:\s]+([0-9a-f]{64})"#, options: .regularExpression) {
                let sub = body[range]
                if let hexRange = sub.range(of: #"[0-9a-f]{64}"#, options: .regularExpression) {
                    sha256 = String(sub[hexRange]).lowercased()
                }
            }
        }

        return Release(version: version, sha256: sha256)
    }

    // MARK: - Download + install

    private func downloadDMG(version: String) async throws -> URL {
        let dmgURL = URL(string: "https://github.com/\(repo)/releases/download/v\(version)/Yamete.dmg")!
        let (tempURL, response) = try await URLSession.shared.download(from: dmgURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Yamete-\(version).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func installFromDMG(_ dmgPath: URL) async throws {
        let mountPoint = "/Volumes/Yamete-Update"

        let mount = Process()
        mount.launchPath = "/usr/bin/hdiutil"
        mount.arguments = ["attach", dmgPath.path, "-mountpoint", mountPoint, "-quiet", "-nobrowse"]
        try mount.run()
        mount.waitUntilExit()
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

        // Security: verify bundle identifier
        let plistPath = sourceApp + "/Contents/Info.plist"
        guard let plist = NSDictionary(contentsOfFile: plistPath),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleID else {
            log.error("activity:Install wasInvalidatedBy entity:BundleIDMismatch")
            throw UpdateError.bundleIDMismatch
        }
        log.info("entity:AppBundle wasVerifiedBy activity:BundleIDCheck id=\(bundleID)")

        // Replace current app
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
        case checksumMismatch, signatureInvalid, bundleIDMismatch

        var errorDescription: String? {
            switch self {
            case .networkError:     "Could not reach GitHub"
            case .parseError:       "Could not parse release info"
            case .downloadFailed:   "DMG download failed"
            case .mountFailed:      "Could not mount DMG"
            case .appNotFound:      "No app found in DMG"
            case .installFailed:    "Could not replace app bundle"
            case .checksumMismatch: "Download corrupted — SHA256 mismatch"
            case .signatureInvalid: "Code signature verification failed"
            case .bundleIDMismatch: "App bundle identifier mismatch"
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
