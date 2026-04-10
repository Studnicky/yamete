import Foundation
import os

// MARK: - AppLog

/// Dual-sink logger: writes to both `os.Logger` (unified log for Console.app)
/// and the app's own ``LogStore`` (file-based, 24-hour retention).
public struct AppLog: Sendable {
    private let osLog: Logger
    private let category: String

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.studnicky.yamete"
    #if DIRECT_BUILD
    public static let supportsDebugLogging = true
    #else
    public static let supportsDebugLogging = false
    #endif

    /// Controls whether debug-level messages are emitted.
    /// Direct builds wire this to the UI debug logging toggle; App Store builds force it off.
    /// Atomic: read from background sensor threads, written from @MainActor.
    private static let _debugEnabled = OSAllocatedUnfairLock(initialState: false)
    public static var debugEnabled: Bool {
        get { supportsDebugLogging && _debugEnabled.withLock { $0 } }
        set { _debugEnabled.withLock { $0 = supportsDebugLogging && newValue } }
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
        guard Self.debugEnabled else { return }
        osLog.debug("\(message, privacy: .private)")
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
/// Writes to `Application Support/<Product>/logs/yamete-YYYY-MM-DD.log`.
/// The direct build uses `Yamete Direct/logs`; the App Store build is
/// sandbox-redirected to its app container and keeps `Yamete/logs`.
/// On startup and at each day boundary, log files older than 24 hours are deleted.
///
/// Thread safety: all mutable state lives in a lock-protected `State` struct.
/// Formatters are created inside the lock closure (they are not thread-safe).
public final class LogStore: Sendable {
    public static let shared = LogStore()
    public static let supportDirectoryName: String = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return "Yamete"
        }

        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Yamete"
    }()

    private let directory: URL
    private let maxAge: TimeInterval = 24 * 60 * 60

    /// Mutable per-day rotation state. Always accessed under `state` lock,
    /// so marking `@unchecked Sendable` is safe — the lock provides the
    /// serialization the Sendable contract requires. The fields hold a
    /// `FileHandle` (not Sendable) plus two formatters that are stable
    /// after construction.
    private struct State: @unchecked Sendable {
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
        directory = support
            .appendingPathComponent(Self.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
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
