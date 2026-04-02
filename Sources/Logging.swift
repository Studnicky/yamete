import Foundation
import os

// MARK: - AppLog

/// Dual-sink logger: writes to both `os.Logger` (unified log for Console.app)
/// and the app's own ``LogStore`` (file-based, 24-hour retention).
struct AppLog: Sendable {
    private let osLog: Logger
    private let category: String

    init(category: String) {
        osLog = Logger(subsystem: "com.yamete", category: category)
        self.category = category
    }

    func info(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        LogStore.shared.append("INFO", category, message)
    }

    func debug(_ message: String) {
        osLog.debug("\(message, privacy: .public)")
        LogStore.shared.append("DEBUG", category, message)
    }

    func warning(_ message: String) {
        osLog.warning("\(message, privacy: .public)")
        LogStore.shared.append("WARN", category, message)
    }

    func error(_ message: String) {
        osLog.error("\(message, privacy: .public)")
        LogStore.shared.append("ERROR", category, message)
    }
}

// MARK: - LogStore

/// File-based log store with automatic 24-hour retention.
///
/// Writes to `~/Library/Application Support/Yamete/logs/yamete-YYYY-MM-DD.log`.
/// On startup and at each day boundary, log files older than 24 hours are deleted.
///
/// Thread safety: all mutable state and formatter access is confined to `queue`.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let directory: URL
    private let maxAge: TimeInterval = 24 * 60 * 60
    private let queue = DispatchQueue(label: "com.yamete.logstore", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentDate = ""

    // Formatters are not thread-safe — only access on `queue`.
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let tsFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = support.appendingPathComponent("Yamete/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.sync {
            pruneStaleFiles()
            rotateIfNeeded()
        }
    }

    func append(_ level: String, _ category: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            rotateIfNeeded()
            let ts = tsFmt.string(from: now)
            let line = "\(ts) [\(level)] \(category): \(message)\n"
            fileHandle?.write(Data(line.utf8))
        }
    }

    // MARK: - Private (must be called on `queue`)

    private func pruneStaleFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files where file.pathExtension == "log" {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let modified = attrs[.modificationDate] as? Date,
               modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func rotateIfNeeded() {
        let today = dateFmt.string(from: Date())
        guard today != currentDate else { return }

        fileHandle?.closeFile()
        fileHandle = nil

        if !currentDate.isEmpty { pruneStaleFiles() }
        currentDate = today

        let url = directory.appendingPathComponent("yamete-\(today).log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        fileHandle?.closeFile()
    }
}
