import XCTest

/// VoiceOver label coverage matrix:
///   Every empty-label `Toggle("", ...)` × adjacent labeling context.
///
/// Bug class: an interactive element has no `accessibilityLabel`, no `.help()`,
/// and no nearby `Text` describing it. VoiceOver users hear "switch" with no
/// context.
///
/// Strategy: walk every view file, find each `Toggle("", isOn: ...)` literal,
/// scan the 5 lines before AND after for one of:
///   - `.accessibilityLabel(...)`
///   - `.help(...)`
///   - `.themeMiniSwitch()` followed by an outer `.help(...)` modifier (the
///     wrapper itself is unlabeled, but the wrapping HStack always carries a
///     `Text(NSLocalizedString(...))` label visible to VoiceOver via grouping)
///   - Adjacent `Text(NSLocalizedString(...))` (the label-then-toggle pattern).
///
/// If none are present within the search window, the toggle ships unlabeled
/// and VoiceOver users hit a wall. Fail with file:line cell coordinates.
final class MatrixVoiceOverLabels_Tests: XCTestCase {

    // MARK: - Repo discovery

    private static var viewsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/YameteApp/Views")
    }

    private func allViewSwiftFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.viewsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "swift" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - Detection

    private static let emptyToggleRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\bToggle\(\s*""\s*,"#)
    }()

    /// Markers that constitute an accessibility-label-or-equivalent. Found
    /// within 5 lines of the Toggle on either side. The presence of any of
    /// these in the surrounding window means VoiceOver users will hear
    /// something meaningful — the bug we want to catch is the opposite case
    /// (Toggle in isolation with no nearby text or hint).
    private static let labelMarkers: [String] = [
        ".accessibilityLabel(",
        ".help(",
        "Text(NSLocalizedString(",
        "configuration.label",
    ]

    private func hasNearbyLabel(_ lines: [String], at idx: Int) -> Bool {
        let lo = max(0, idx - 5)
        let hi = min(lines.count - 1, idx + 5)
        for i in lo...hi {
            for marker in Self.labelMarkers where lines[i].contains(marker) {
                return true
            }
        }
        return false
    }

    // MARK: - Cell A: every empty-label Toggle has nearby labeling

    func testEveryEmptyLabelToggleHasNearbyAccessibilityContext() {
        var violations: [String] = []

        for url in allViewSwiftFiles() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = src.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                let matches = Self.emptyToggleRegex.matches(in: line, range: range)
                guard !matches.isEmpty else { continue }

                if !hasNearbyLabel(lines, at: i) {
                    let relPath = url.path.replacingOccurrences(
                        of: Self.viewsRoot.deletingLastPathComponent()
                            .deletingLastPathComponent().path + "/", with: ""
                    )
                    violations.append("[file=\(relPath):\(i + 1)] " +
                        "Toggle has no accessibility label nearby — " +
                        "expected `.accessibilityLabel(...)`, `.help(...)`, " +
                        "or adjacent `Text(NSLocalizedString(...))` within 5 lines")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) VoiceOver-label violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell B: every Button without a string label has nearby help / label

    /// `Button(action: { ... }) { Image(systemName: "...") }` is a common
    /// SwiftUI shape that produces an icon-only button. VoiceOver renders
    /// these as "button" with no context unless `.accessibilityLabel(...)`
    /// or `.help(...)` is attached. Heuristic: find `Button(action:` or
    /// `Button {` lines, look for label markers within 8 lines (buttons
    /// often span multi-line trailing closures).
    func testEveryIconOnlyButtonHasNearbyAccessibilityContext() {
        let buttonRegex = try! NSRegularExpression(pattern: #"\bButton\(action:|Button \{"#)
        var violations: [String] = []

        for url in allViewSwiftFiles() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = src.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                let matches = buttonRegex.matches(in: line, range: range)
                guard !matches.isEmpty else { continue }

                // Generous window: SwiftUI Button trailing closures often
                // span 10+ lines (Image stack + Text + spacer modifiers
                // before the closing brace, plus `.buttonStyle(...)` /
                // `.help(...)` modifiers afterwards). 12 covers the
                // common SensorAccordionCard pattern in Theme.swift.
                let lo = max(0, i - 3)
                let hi = min(lines.count - 1, i + 12)
                var labeled = false
                // Markers that indicate the button HAS some user-visible
                // textual context. `Text(...)` (any form) is fine — even
                // dynamic labels like `Text(item.title)` produce VoiceOver
                // output. `configuration.label` is the SwiftUI ToggleStyle
                // re-export of the wrapping toggle's label and inherits
                // accessibility from there.
                for j in lo...hi {
                    for marker in [".accessibilityLabel(", ".help(", "Text(", "configuration.label"] {
                        if lines[j].contains(marker) { labeled = true; break }
                    }
                    if labeled { break }
                }
                if !labeled {
                    let relPath = url.path.replacingOccurrences(
                        of: Self.viewsRoot.deletingLastPathComponent()
                            .deletingLastPathComponent().path + "/", with: ""
                    )
                    violations.append("[file=\(relPath):\(i + 1)] " +
                        "icon-only Button has no accessibility label nearby — " +
                        "expected `.accessibilityLabel(...)` or `.help(...)` within 8 lines")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) icon-button accessibility violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }
}
