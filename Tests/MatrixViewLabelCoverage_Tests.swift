import XCTest

/// View label localization coverage matrix:
///   Every `Text("...")` / `Button("...")` literal in `Sources/YameteApp/Views/`
///   × the localization whitelist.
///
/// Bug class: a UI element has hardcoded English text instead of a
/// `NSLocalizedString` lookup, so non-en users see English in the middle
/// of an otherwise-translated panel.
///
/// Strategy:
///   - Walk every `*.swift` under `Sources/YameteApp/Views/`.
///   - Grep `Text("STRING_LITERAL")` and `Button("STRING_LITERAL", ...)` lines.
///   - Filter out short/non-prose content via the whitelist.
///   - Filter out lines inside `#if DEBUG` blocks (debug-only labels are
///     allowed to be hardcoded — they're never shown in shipping builds).
///   - Each remaining literal is a violation.
final class MatrixViewLabelCoverage_Tests: XCTestCase {

    // MARK: - Whitelist

    /// Strings inside `Text(...)` or `Button(...)` that are intentionally
    /// hardcoded. Most are kaomoji, separators, version templates, or
    /// short symbols where localization is meaningless.
    private static let allowedLiterals: Set<String> = [
        "(≧▽≦)",   // MenuBarIcon happy face kaomoji
    ]

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

    /// Captures literal strings in:
    ///   `Text("...")`, `Button("...", ...)`, `Toggle("non-empty literal", ...)`.
    /// The pattern is intentionally simple — Swift string interpolation
    /// (`Text("\(foo)")`) starts with `\(` and is excluded. Computed bindings
    /// like `Text(viewModel.title)` don't start with `"` and won't match.
    private static let textLiteralRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(Text|Button|Toggle)\("([^"\\]*(?:\\.[^"\\]*)*)""#
        )
    }()

    /// A "user-facing prose literal" is one that contains a 3+ character
    /// alphanumeric run — too short for that and it's almost certainly a
    /// symbol, separator, or single-glyph indicator.
    private func isUserFacingProse(_ literal: String) -> Bool {
        // Empty literals (used for invisible labels on Toggle) are exempt.
        guard !literal.isEmpty else { return false }
        // 3+ alphanumeric run anywhere in the string.
        var run = 0
        for ch in literal where ch.isLetter || ch.isNumber {
            run += 1
            if run >= 3 { return true }
        }
        return false
    }

    // MARK: - Cell A: every literal in views is whitelisted or localized

    func testNoHardcodedUserFacingTextInViews() {
        var violations: [String] = []

        for url in allViewSwiftFiles() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = src.components(separatedBy: "\n")

            // Track #if DEBUG nesting depth to skip those lines.
            var debugDepth = 0
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { debugDepth += 1; continue }
                if trimmed.hasPrefix("#endif") && debugDepth > 0 { debugDepth -= 1; continue }
                if debugDepth > 0 { continue }

                let range = NSRange(line.startIndex..., in: line)
                Self.textLiteralRegex.enumerateMatches(in: line, range: range) { match, _, _ in
                    guard let m = match,
                          m.numberOfRanges >= 3,
                          let kindRange = Range(m.range(at: 1), in: line),
                          let strRange = Range(m.range(at: 2), in: line) else { return }
                    let constructorKind = String(line[kindRange])
                    let literal = String(line[strRange])
                    if !self.isUserFacingProse(literal) { return }
                    if Self.allowedLiterals.contains(literal) { return }
                    let relPath = url.path.replacingOccurrences(
                        of: Self.viewsRoot.deletingLastPathComponent()
                            .deletingLastPathComponent().path + "/", with: ""
                    )
                    violations.append("[file=\(relPath):\(i + 1) constructor=\(constructorKind)] " +
                        "hardcoded user-facing string '\(literal)'; wrap with NSLocalizedString " +
                        "or add to allowedLiterals if intentional")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) hardcoded-text violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell B: every NSLocalizedString reference resolves at lookup-time

    /// Every NSLocalizedString literal under Views/ must produce a non-empty
    /// translation in en.lproj. Catches typo'd keys (`buton_quit`) where the
    /// strings file would silently return the typo as the rendered text.
    func testEveryViewNSLocalizedStringResolvesInEn() {
        // Parse en strings once
        let enLocalizable = parseStrings(at: enLocalizablePath())
        let enEvents = parseStrings(at: enEventsPath())

        let nsLocalizedRegex = try! NSRegularExpression(pattern: #"NSLocalizedString\("([^"\\]*(?:\\.[^"\\]*)*)""#)

        var violations: [String] = []
        for url in allViewSwiftFiles() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = src.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                nsLocalizedRegex.enumerateMatches(in: line, range: range) { match, _, _ in
                    guard let m = match,
                          let r = Range(m.range(at: 1), in: line) else { return }
                    let key = String(line[r])
                    // Only check token-style keys (sentence-keys are exempt — they're their own default value).
                    if !isTokenStyleKey(key) { return }
                    if enLocalizable[key] == nil && enEvents[key] == nil {
                        let relPath = url.path
                        violations.append("[file=\(relPath):\(i + 1) key=\(key)] " +
                            "NSLocalizedString key has no en entry — would render the raw key")
                    }
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) view-key resolution violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Helpers

    private func parseStrings(at path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return dict
    }

    private func enLocalizablePath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/en.lproj/Localizable.strings").path
    }

    private func enEventsPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/en.lproj/Events.strings").path
    }

    private func isTokenStyleKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        guard let first = key.first, first.isLetter, first.isLowercase else { return false }
        return key.allSatisfy { ch in
            ch.isLetter && ch.isLowercase || ch.isNumber || ch == "_"
        }
    }
}
