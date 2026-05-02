import XCTest

/// Localization key coverage matrix:
///   Source files × Localizable.strings × Events.strings × all locales.
///
/// Bug class: `NSLocalizedString("foo", comment: ...)` is called in source
/// but the `.strings` file has no entry for `foo`. macOS shows the raw key
/// in the UI. Or the reverse: a key sits in `.strings` with no consumer —
/// dead string that drifts with feature edits.
///
/// Strategy:
///   - Parse every `.strings` file under `App/Resources/*.lproj/`.
///   - Grep every `Sources/**/*.swift` for `NSLocalizedString("...")`.
///   - Run four parity checks per cell, accumulating violations:
///     A) Source→strings: every token-style key in source has an en entry.
///     B) Strings→source: every key in en is referenced from source
///        (excluding dynamic-pool keys looked up via interpolation).
///     C) Locale parity: every en key exists in every other locale.
///     D) No empty / placeholder values: each value is non-empty.
final class MatrixLocalizationKeyCoverage_Tests: XCTestCase {

    // MARK: - Repo discovery

    /// Repo root from `#filePath` (Tests/MatrixLocalizationKeyCoverage_Tests.swift
    /// → repo root). Matches the convention used by `LocalizationE2ETests`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }

    private static var resourcesURL: URL {
        repoRoot.appendingPathComponent("App/Resources")
    }

    private static var sourcesURL: URL {
        repoRoot.appendingPathComponent("Sources")
    }

    // MARK: - .strings file parsing

    /// Parses a `.strings` file via `NSDictionary(contentsOfFile:)` (handles
    /// both legacy `key=value;` and modern xml plist formats macOS supports).
    /// Returns empty dict if the file is missing or malformed.
    private func parseStrings(at path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return dict
    }

    /// Lists every locale directory under `App/Resources/*.lproj/`.
    private func allLocales() -> [String] {
        let url = Self.resourcesURL
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        return contents
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    // MARK: - Source scanning

    /// Recursively enumerates every `*.swift` file under `Sources/`.
    private func allSwiftSources() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.sourcesURL,
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

    /// Extracts every `NSLocalizedString("KEY", ...)` literal key from a file.
    /// Skips dynamically-built keys (string interpolation / concatenation).
    private static let nsLocalizedStringRegex: NSRegularExpression = {
        // Captures the literal key inside the first arg.
        try! NSRegularExpression(pattern: #"NSLocalizedString\("([^"\\]*(?:\\.[^"\\]*)*)""#)
    }()

    private func keysReferencedIn(_ source: String) -> Set<String> {
        var keys: Set<String> = []
        let range = NSRange(source.startIndex..., in: source)
        Self.nsLocalizedStringRegex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: source) else { return }
            keys.insert(String(source[r]))
        }
        return keys
    }

    // MARK: - Token-style key classification

    /// A "token-style" key is a snake_case identifier with no spaces or
    /// punctuation. Sentence-style keys (`"Microphone access denied. ..."`)
    /// follow the Apple "key IS the default value" pattern and are exempt
    /// from the strings-file parity check.
    private func isTokenStyleKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        guard let first = key.first, first.isLetter, first.isLowercase else { return false }
        return key.allSatisfy { ch in
            ch.isLetter && ch.isLowercase || ch.isNumber || ch == "_"
        }
    }

    /// Dynamic-pool keys looked up via string interpolation in
    /// `NotificationPhrase`. Pattern: `title_<kind|tier>_<n>` and
    /// `body_<kind>_<n>` and `moan_<tier>_<n>`. These never appear as
    /// literals in source, so the strings→source pass would otherwise
    /// flag every numbered-suffix entry.
    private func isDynamicPoolKey(_ key: String) -> Bool {
        let parts = key.split(separator: "_")
        guard parts.count >= 3 else { return false }
        guard parts[0] == "title" || parts[0] == "body" || parts[0] == "moan" else { return false }
        return Int(parts.last!) != nil
    }

    // MARK: - Aggregated violations

    /// Helper to accumulate violations and emit one message per category.
    private struct Violations {
        var lines: [String] = []
        mutating func add(_ line: String) { lines.append(line) }
        var rendered: String { lines.joined(separator: "\n  • ") }
        var isEmpty: Bool { lines.isEmpty }
    }

    // MARK: - Cell A: Source → en strings

    /// Every token-style `NSLocalizedString` key referenced from source must
    /// have an entry in `en.lproj/Localizable.strings` OR `en.lproj/Events.strings`.
    func testEveryTokenKeyReferencedInSourceExistsInEnStrings() {
        let enLocalizable = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Localizable.strings").path
        )
        let enEvents = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Events.strings").path
        )
        XCTAssertFalse(enLocalizable.isEmpty,
            "[file=en.lproj/Localizable.strings] failed to parse — fix the file before this matrix can run")

        var violations = Violations()
        for url in allSwiftSources() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let keys = keysReferencedIn(src)
            for key in keys where isTokenStyleKey(key) {
                if enLocalizable[key] == nil && enEvents[key] == nil {
                    let relPath = url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
                    violations.add("[file=\(relPath) key=\(key)] " +
                        "source uses `NSLocalizedString(\"\(key)\", ...)` " +
                        "but no entry in en.lproj/Localizable.strings or en.lproj/Events.strings")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.lines.count) source→strings drift violations:\n  • \(violations.rendered)")
    }

    // MARK: - Cell B: en strings → source (dead-key detection)

    /// Every key in `en.lproj/Localizable.strings` must be referenced from
    /// at least one source file (excluding sentence-keys and dynamic pools).
    func testEveryEnKeyHasASourceReference() {
        let enLocalizable = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Localizable.strings").path
        )

        // Aggregate all source files into one corpus to scan once.
        var allReferencedKeys: Set<String> = []
        for url in allSwiftSources() {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            allReferencedKeys.formUnion(keysReferencedIn(src))
        }

        var violations = Violations()
        for key in enLocalizable.keys.sorted() {
            // Skip sentence keys (the key IS the default value — Apple pattern).
            if !isTokenStyleKey(key) { continue }
            // Skip dynamic-pool keys looked up via interpolation.
            if isDynamicPoolKey(key) { continue }
            if !allReferencedKeys.contains(key) {
                violations.add("[file=en.lproj/Localizable.strings key=\(key)] " +
                    "key in strings but no `NSLocalizedString(\"\(key)\", ...)` in any source — dead key")
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.lines.count) dead-key (strings→source) violations:\n  • \(violations.rendered)")
    }

    // MARK: - Cell C: Locale parity

    /// Every non-en locale must contain every key present in `en.lproj/Localizable.strings`
    /// AND every key in `en.lproj/Events.strings`. Aggregates per locale and
    /// emits one violation line per (locale, key) pair.
    func testEveryLocaleContainsEveryEnKey() {
        let enLocalizable = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Localizable.strings").path
        )
        let enEvents = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Events.strings").path
        )

        var violations = Violations()
        for locale in allLocales() where locale != "en" {
            let lproj = Self.resourcesURL.appendingPathComponent("\(locale).lproj")
            // Localizable.strings parity
            let localized = parseStrings(at: lproj.appendingPathComponent("Localizable.strings").path)
            for key in enLocalizable.keys.sorted() where localized[key] == nil {
                violations.add("[locale=\(locale) file=Localizable.strings key=\(key)] missing translation")
            }
            // Events.strings parity is tolerant: a missing file entirely is
            // fine — `NotificationPhrase` falls back to en when the locale
            // has no event pools (documented contract). But if the file
            // exists, it must contain every key en has, otherwise users on
            // that locale see partial translations mixed with English.
            let eventsPath = lproj.appendingPathComponent("Events.strings").path
            if !enEvents.isEmpty && FileManager.default.fileExists(atPath: eventsPath) {
                let events = parseStrings(at: eventsPath)
                for key in enEvents.keys.sorted() where events[key] == nil {
                    violations.add("[locale=\(locale) file=Events.strings key=\(key)] missing translation")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.lines.count) locale-parity violations:\n  • \(violations.rendered)")
    }

    // MARK: - Cell D: No empty values

    /// Every value across every locale × every strings file must be non-empty.
    /// Empty values render as the raw key in macOS.
    func testNoLocaleHasEmptyStringValues() {
        var violations = Violations()
        for locale in allLocales() {
            let lproj = Self.resourcesURL.appendingPathComponent("\(locale).lproj")
            let files = ["Localizable.strings", "Events.strings", "Moans.strings"]
            for fileName in files {
                let path = lproj.appendingPathComponent(fileName).path
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let dict = parseStrings(at: path)
                for (key, value) in dict where value.isEmpty {
                    violations.add("[locale=\(locale) file=\(fileName) key=\(key)] empty value")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.lines.count) empty-value violations:\n  • \(violations.rendered)")
    }
}
