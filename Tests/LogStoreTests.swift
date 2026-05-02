import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

final class LogStoreTests: XCTestCase {

    func testLogLevels() {
        struct Case { let name: String; let level: String; let write: (AppLog) -> Void }
        // Unique per-run category so prior test sessions' entries in the shared
        // Application Support log file don't pollute this assertion.
        let category = "LogTest-\(UUID().uuidString.prefix(8))"
        let cases: [Case] = [
            .init(name: "info",    level: "INFO")  { $0.info("test-info") },
            .init(name: "warning", level: "WARN")  { $0.warning("test-warn") },
            .init(name: "error",   level: "ERROR") { $0.error("test-error") },
        ]
        let log = AppLog(category: category)

        // Snapshot the file size BEFORE we write so we only inspect bytes added
        // by THIS test run. The log file is shared across test sessions and
        // builds — without this scoping, a prior `-DDIRECT_BUILD` run's
        // `[DEBUG]` entries leak into the App Store build's assertion.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let logFile = support
            .appendingPathComponent("\(LogStore.supportDirectoryName)/logs/yamete-\(fmt.string(from: Date())).log")
        let preLen = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? UInt64) ?? 0

        let previousDebug = AppLog.debugEnabled
        AppLog.debugEnabled = true
        for c in cases {
            c.write(log)
        }
        log.debug("test-debug")
        AppLog.debugEnabled = previousDebug

        // Wait for async log writes.
        let e = expectation(description: "flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.fulfill() }
        wait(for: [e], timeout: 2.0)

        // Read only the bytes appended during this test run.
        let fullContent = (try? Data(contentsOf: logFile)) ?? Data()
        let appended = fullContent.count > Int(preLen) ? fullContent.suffix(from: Int(preLen)) : Data()
        let content = String(data: appended, encoding: .utf8) ?? ""

        for c in cases {
            XCTAssertTrue(content.contains("[\(c.level)] \(category):"), "\(c.name): expected [\(c.level)] in log file")
        }

        if AppLog.supportsDebugLogging {
            XCTAssertTrue(content.contains("[DEBUG] \(category):"), "debug: expected [DEBUG] in direct-build log file")
        } else {
            XCTAssertFalse(content.contains("[DEBUG] \(category):"), "debug: App Store builds should not persist debug logs")
        }
    }
}
