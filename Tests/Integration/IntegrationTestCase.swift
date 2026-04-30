import XCTest

/// Base class for integration tests. No hardware required, but exercises
/// boundaries between layers (SwiftUI bindings ↔ SettingsStore, layout
/// engine ↔ panel sizing, source ↔ bus ↔ output through real types).
@MainActor
class IntegrationTestCase: XCTestCase {
    /// Subclasses can override to skip individual tests by environment flag.
    var requiresEnvironmentFlag: String? { nil }

    override func setUp() async throws {
        // Skip the `try await super.setUp()` call — XCTest's default
        // `setUp() async throws` is empty and calling it sends `self`
        // across the actor boundary, which Swift 6.0 strict-concurrency
        // diagnoses as a `Sendable` violation. The default base-class
        // setUp runs implicitly in the framework anyway.
        if let flag = requiresEnvironmentFlag,
           ProcessInfo.processInfo.environment[flag] != "1" {
            throw XCTSkip("Set \(flag)=1 to run \(Self.self)")
        }
    }
}
