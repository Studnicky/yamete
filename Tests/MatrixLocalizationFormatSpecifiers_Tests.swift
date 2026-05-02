import XCTest

/// Localization format-specifier matrix:
///   Every `.strings` key with a format specifier × every locale.
///
/// Bug class: en's `unit_percent` is `"%lld%%"`; another locale's value drops
/// the `%lld` or substitutes `%@`. `String(format:)` then crashes (when the
/// locale uses `%@` but the call site passes an Int) or shows garbled output
/// (when specifiers are reordered or missing).
///
/// Strategy:
///   - Extract the set of format specifiers from each en value.
///   - For every other locale, assert the same set in the same order.
///   - For every `unit_*` key, exercise the formatter live with a
///     representative value across every locale and assert non-crash + non-empty.
final class MatrixLocalizationFormatSpecifiers_Tests: XCTestCase {

    // MARK: - Repo discovery

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var resourcesURL: URL {
        repoRoot.appendingPathComponent("App/Resources")
    }

    // MARK: - Helpers

    /// Captures every C-style format specifier in the value. Order preserved.
    /// Pattern intentionally permissive — it must match the same specifiers
    /// `String(format:)` honors so order/type comparison is meaningful.
    private static let formatSpecRegex: NSRegularExpression = {
        // %% literal escape, %d/%i/%u/%lld, %f/%.Nf/%g, %@, %s, %c, %p
        try! NSRegularExpression(
            pattern: #"%(?:[+\-#0 ]?\d*\.?\d*)(?:l{1,2}|h{1,2}|q|z|j|t)?[diouxXeEfgGsSpaA@%c]"#
        )
    }()

    private func specifiers(in value: String) -> [String] {
        var out: [String] = []
        let range = NSRange(value.startIndex..., in: value)
        Self.formatSpecRegex.enumerateMatches(in: value, range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range, in: value) else { return }
            let token = String(value[r])
            // Drop literal `%%` — they don't consume an argument.
            if token == "%%" { return }
            out.append(token)
        }
        return out
    }

    /// Normalize a specifier so cosmetically-different forms compare equal:
    /// `%lld` and `%d` both consume an Int — we treat the integer family as
    /// one. Same for floating types. `%@` is unambiguous.
    private func family(_ spec: String) -> String {
        // Trim any leading flags / width / precision so we get the type tail.
        // Pull the last char and any preceding length modifiers.
        let chars = Array(spec)
        guard let last = chars.last else { return spec }
        switch last {
        case "d", "i", "u", "x", "X", "o": return "int"
        case "f", "g", "G", "e", "E", "a", "A": return "float"
        case "@": return "obj"
        case "s", "S": return "str"
        case "c", "C": return "char"
        case "p": return "ptr"
        default: return spec
        }
    }

    private func parseStrings(at path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return dict
    }

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

    // MARK: - Cell A: every format-specifier key has parity across locales

    func testFormatSpecifierFamilyParityAcrossLocales() {
        let enLocalizable = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Localizable.strings").path
        )
        // Find every key whose en value contains at least one specifier.
        let keysWithSpecifiers = enLocalizable.compactMap { (key, value) -> (String, [String])? in
            let specs = specifiers(in: value)
            return specs.isEmpty ? nil : (key, specs.map { family($0) })
        }

        var violations: [String] = []
        for locale in allLocales() where locale != "en" {
            let path = Self.resourcesURL
                .appendingPathComponent("\(locale).lproj/Localizable.strings").path
            let dict = parseStrings(at: path)
            for (key, enFamilies) in keysWithSpecifiers {
                guard let value = dict[key] else { continue }   // covered by Cell C of Matrix 1
                let localeFamilies = specifiers(in: value).map { family($0) }
                if enFamilies != localeFamilies {
                    violations.append("[locale=\(locale) key=\(key)] " +
                        "format specifier mismatch with en — " +
                        "en families=\(enFamilies) local families=\(localeFamilies) " +
                        "(en value=\"\(enLocalizable[key] ?? "")\" local value=\"\(value)\")")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) format-specifier-parity violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell B: live String(format:) for every unit key × every locale

    /// Exercises `String(format: NSLocalizedString(key, ...), value)` for
    /// every `unit_*` key with a representative value matching its specifier
    /// family. Asserts no crash and non-empty output. Catches `%@`↔`%d` swaps
    /// and missing-specifier bugs that families parity would also catch — but
    /// this one detects them by actually running the formatter, which mirrors
    /// the production code path.
    func testUnitKeysFormatLiveAcrossEveryLocale() {
        struct UnitCell {
            let key: String
            let intValue: Int?
            let doubleValue: Double?
        }
        let cells: [UnitCell] = [
            .init(key: "unit_percent",      intValue: 50, doubleValue: nil),
            .init(key: "unit_hz",           intValue: 60, doubleValue: nil),
            .init(key: "unit_gforce",       intValue: nil, doubleValue: 1.5),
            .init(key: "unit_multiplier",   intValue: nil, doubleValue: 2.0),
            .init(key: "unit_seconds",      intValue: nil, doubleValue: 0.5),
            .init(key: "unit_milliseconds", intValue: nil, doubleValue: 250.0),
            .init(key: "unit_taps_per_sec", intValue: nil, doubleValue: 2.5),
            .init(key: "consensus_format",  intValue: 2, doubleValue: nil),
            .init(key: "confirmations_format", intValue: 3, doubleValue: nil),
            .init(key: "impacts_today",     intValue: 5, doubleValue: nil),
        ]

        var violations: [String] = []
        for locale in allLocales() {
            let path = Self.resourcesURL
                .appendingPathComponent("\(locale).lproj/Localizable.strings").path
            let dict = parseStrings(at: path)
            for cell in cells {
                guard let template = dict[cell.key] else { continue }
                let result: String
                if let i = cell.intValue {
                    result = String(format: template, i)
                } else if let d = cell.doubleValue {
                    result = String(format: template, d)
                } else {
                    continue
                }
                if result.isEmpty {
                    violations.append("[locale=\(locale) key=\(cell.key)] String(format:) returned empty")
                }
                // Detect raw-template-passed-through (no substitution happened).
                // If the template still contains the specifier verbatim and result
                // equals template, the formatter didn't substitute — broken.
                let producedSpecs = specifiers(in: result)
                if !producedSpecs.isEmpty && result == template {
                    violations.append("[locale=\(locale) key=\(cell.key)] " +
                        "String(format:) did not substitute — template returned verbatim")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) live-format violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell C: en sanity — every advertised unit key carries a specifier

    /// Defends against an en regression where someone overwrites `unit_percent`
    /// with a plain `"50%"` and forgets the `%lld`. This cell asserts on en
    /// alone — locale parity (Cell A) catches drift in other locales.
    func testEnUnitKeysAllCarryASpecifier() {
        let dict = parseStrings(
            at: Self.resourcesURL.appendingPathComponent("en.lproj/Localizable.strings").path
        )
        let unitKeys = ["unit_percent", "unit_hz", "unit_gforce", "unit_multiplier",
                        "unit_seconds", "unit_milliseconds", "unit_taps_per_sec",
                        "consensus_format", "confirmations_format", "impacts_today"]
        var violations: [String] = []
        for key in unitKeys {
            guard let value = dict[key] else {
                violations.append("[locale=en key=\(key)] missing entirely")
                continue
            }
            let specs = specifiers(in: value)
            if specs.isEmpty {
                violations.append("[locale=en key=\(key)] no format specifier in value '\(value)'")
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) en-specifier violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }
}
