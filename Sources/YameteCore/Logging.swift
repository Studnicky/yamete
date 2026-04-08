import Foundation
import os

// MARK: - AppLog

/// Dual-sink logger: writes to both `os.Logger` (unified log for Console.app)
/// and the app's own ``LogStore`` (file-based, 24-hour retention).
public struct AppLog: Sendable {
    private let osLog: Logger
    private let category: String

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.studnicky.yamete"

    /// Controls whether debug-level messages are written to the file log.
    /// Info, warning, and error always log. Set from the UI debug logging toggle.
    /// Atomic: read from background sensor threads, written from @MainActor.
    private static let _debugEnabled = OSAllocatedUnfairLock(initialState: false)
    public static var debugEnabled: Bool {
        get { _debugEnabled.withLock { $0 } }
        set { _debugEnabled.withLock { $0 = newValue } }
    }

    public init(category: String) {
        osLog = Logger(subsystem: Self.subsystem, category: category)
        self.category = category
    }

    public func info(_ message: String) {
        osLog.info("\(message, privacy: .private)")
        LogStore.shared.append("INFO", category, message)
    }

    public func debug(_ message: String) {
        osLog.debug("\(message, privacy: .private)")
        guard Self.debugEnabled else { return }
        LogStore.shared.append("DEBUG", category, message)
    }

    public func warning(_ message: String) {
        osLog.warning("\(message, privacy: .private)")
        LogStore.shared.append("WARN", category, message)
    }

    public func error(_ message: String) {
        osLog.error("\(message, privacy: .private)")
        LogStore.shared.append("ERROR", category, message)
    }
}

// MARK: - LogStore

/// File-based log store with automatic 24-hour retention.
///
/// Writes to `Application Support/Yamete/logs/yamete-YYYY-MM-DD.log`
/// (sandbox-redirected to the app container when running under App Sandbox).
/// On startup and at each day boundary, log files older than 24 hours are deleted.
///
/// Thread safety: all mutable state lives in a lock-protected `State` struct.
/// Formatters are created inside the lock closure (they are not thread-safe).
public final class LogStore: Sendable {
    public static let shared = LogStore()

    private let directory: URL
    private let maxAge: TimeInterval = 24 * 60 * 60

    private struct State {
        var fileHandle: FileHandle?
        var currentDate = ""
        let dateFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let tsFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    }

    private let state: OSAllocatedUnfairLock<State>

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        directory = support.appendingPathComponent("Yamete/logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        state = OSAllocatedUnfairLock(initialState: State())
        state.withLock { s in
            pruneStaleFiles()
            rotateIfNeeded(&s)
        }
    }

    public func append(_ level: String, _ category: String, _ message: String) {
        let now = Date()
        state.withLock { s in
            rotateIfNeeded(&s)
            let ts = s.tsFmt.string(from: now)
            let line = "\(ts) [\(level)] \(category): \(message)\n"
            s.fileHandle?.write(Data(line.utf8))
        }
    }

    // MARK: - Private (called inside state.withLock)

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

    private func rotateIfNeeded(_ s: inout State) {
        let today = s.dateFmt.string(from: Date())
        guard today != s.currentDate else { return }

        s.fileHandle?.closeFile()
        s.fileHandle = nil

        if !s.currentDate.isEmpty { pruneStaleFiles() }
        s.currentDate = today

        let url = directory.appendingPathComponent("yamete-\(today).log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        s.fileHandle = try? FileHandle(forWritingTo: url)
        s.fileHandle?.seekToEndOfFile()
    }
}
