import XCTest
@testable import YameteCore

/// Behavioural cells for `Diagnostic` — the value type Yamete uses to
/// surface live warnings/errors to the menu's diagnostics row. These
/// pin the contract that `DiagnosticsRow` relies on: severity
/// comparability (so callers can sort errors above warnings above
/// info), Identifiable conformance for SwiftUI ForEach diffing, and
/// CTA construction.
final class Diagnostic_Tests: XCTestCase {

    /// Severity is `Comparable` and orders `.info < .warning < .error`.
    /// Yamete relies on this so it can build a list sorted by severity
    /// without per-call switch statements.
    func testSeverity_orderingIsInfoWarningError() {
        XCTAssertLessThan(Diagnostic.Severity.info, Diagnostic.Severity.warning,
            "[diagnostic=severity-order-info-warning] info severity must sort below warning")
        XCTAssertLessThan(Diagnostic.Severity.warning, Diagnostic.Severity.error,
            "[diagnostic=severity-order-warning-error] warning severity must sort below error")
        XCTAssertLessThan(Diagnostic.Severity.info, Diagnostic.Severity.error,
            "[diagnostic=severity-order-info-error] info severity must sort below error (transitive)")
    }

    /// `id` is exposed via `Identifiable` so SwiftUI's `ForEach(items)`
    /// works without the caller supplying an id key path. Two
    /// diagnostics with the same id must hash identically — needed
    /// because Yamete uses ids to dedup if a domain becomes
    /// double-active.
    func testIdentifiableAndHashable_idDrivesEquality() {
        let a = Diagnostic(id: "input-monitoring-denied", severity: .warning, title: "Permission missing")
        let b = Diagnostic(id: "input-monitoring-denied", severity: .warning, title: "Permission missing")
        let c = Diagnostic(id: "sensor-error", severity: .error, title: "Watchdog stalled")
        XCTAssertEqual(a, b,
            "[diagnostic=hashable-equal-ids] two diagnostics with identical ids must compare equal")
        XCTAssertNotEqual(a, c,
            "[diagnostic=hashable-different-ids] diagnostics with different ids must not compare equal")
        XCTAssertEqual(a.id, "input-monitoring-denied",
            "[diagnostic=identifiable-id-exposed] Identifiable must expose the supplied id")
    }

    /// `CallToAction` is a Sendable value type usable from the SwiftUI
    /// view layer. The button label and url round-trip through the
    /// initialiser without transformation.
    func testCallToAction_roundTripsLabelAndURL() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        let cta = Diagnostic.CallToAction(label: "Open System Settings…", url: url)
        XCTAssertEqual(cta.label, "Open System Settings…",
            "[diagnostic=cta-label-roundtrip] CTA label must round-trip through init")
        XCTAssertEqual(cta.url, url,
            "[diagnostic=cta-url-roundtrip] CTA url must round-trip through init")
    }
}
