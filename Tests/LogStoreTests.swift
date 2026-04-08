import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

final class LogStoreTests: XCTestCase {

    func testLogLevels() {
        struct Case { let name: String; let level: String; let write: (AppLog) -> Void }
        let cases: [Case] = [
            .init(name: "info",    level: "INFO")  { $0.info("test-info") },
            .init(name: "warning", level: "WARN")  { $0.warning("test-warn") },
            .init(name: "error",   level: "ERROR") { $0.error("test-error") },
        ]
        let log = AppLog(category: "LogTest")
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

        // Verify all levels were written.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let logFile = support
            .appendingPathComponent("\(LogStore.supportDirectoryName)/logs/yamete-\(fmt.string(from: Date())).log")
        let content = (try? String(contentsOf: logFile)) ?? ""

        for c in cases {
            XCTAssertTrue(content.contains("[\(c.level)] LogTest:"), "\(c.name): expected [\(c.level)] in log file")
        }

        if AppLog.supportsDebugLogging {
            XCTAssertTrue(content.contains("[DEBUG] LogTest:"), "debug: expected [DEBUG] in direct-build log file")
        } else {
            XCTAssertFalse(content.contains("[DEBUG] LogTest:"), "debug: App Store builds should not persist debug logs")
        }
    }
}
