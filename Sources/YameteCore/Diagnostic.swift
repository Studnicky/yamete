import Foundation

/// Single user-facing diagnostic surfaced in the menu's diagnostics row
/// directly below the header. Yamete builds the live list as a computed
/// property; the row renders nothing when the list is empty.
///
/// Diagnostics are intentionally a flat, ordered array of value types
/// rather than a structured enum: the row's sort/dedup/limit logic is
/// expressed as ordinary array operations on `Diagnostic`, and adding a
/// new diagnostic kind is a single insertion site in
/// `Yamete.diagnostics` without ceremony.
public struct Diagnostic: Sendable, Identifiable, Hashable {

    /// Severity drives the colour, icon, and ordering. `.error` sorts
    /// above `.warning`, `.warning` above `.info`. Within a severity,
    /// items keep the order Yamete inserted them.
    public enum Severity: Sendable, Hashable, Comparable {
        case info       // Informational state — paused indicator, neutral status
        case warning    // Recoverable problem — missing permission, cold sensor
        case error      // Hard failure — pipeline crash, watchdog stall
    }

    /// Optional call-to-action attached to a diagnostic. Currently only
    /// the URL form is wired; reserved for future "run this in-process"
    /// actions if any are needed.
    public struct CallToAction: Sendable, Hashable {
        public let label: String
        public let url: URL

        public init(label: String, url: URL) {
            self.label = label
            self.url = url
        }
    }

    /// Stable identifier — the row uses this for SwiftUI diffing and
    /// for de-duplication in `Yamete.diagnostics`. Use a domain prefix
    /// (e.g. `"input-monitoring"`, `"sensor-error"`) so identifiers
    /// don't collide as new diagnostics get added.
    public let id: String
    public let severity: Severity
    public let title: String
    public let cta: CallToAction?

    public init(id: String, severity: Severity, title: String, cta: CallToAction? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.cta = cta
    }
}
