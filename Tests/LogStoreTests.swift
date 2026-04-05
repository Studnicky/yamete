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
            .init(name: "debug",   level: "DEBUG") { $0.debug("test-debug") },
            .init(name: "warning", level: "WARN")  { $0.warning("test-warn") },
            .init(name: "error",   level: "ERROR") { $0.error("test-error") },
        ]
        let log = AppLog(category: "LogTest")
        for c in cases {
            c.write(log)
        }

        // Wait for async log writes.
        let e = expectation(description: "flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.fulfill() }
        wait(for: [e], timeout: 2.0)

        // Verify all levels were written.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let logFile = support
            .appendingPathComponent("Yamete/logs/yamete-\(fmt.string(from: Date())).log")
        let content = (try? String(contentsOf: logFile)) ?? ""

        for c in cases {
            XCTAssertTrue(content.contains("[\(c.level)] LogTest:"), "\(c.name): expected [\(c.level)] in log file")
        }
    }
}
