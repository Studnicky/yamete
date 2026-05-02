import XCTest
@testable import YameteCore
@testable import ResponseKit
@testable import YameteApp

/// ReactionKind exhaustiveness matrix:
///   `ReactionKind.allCases` × surface (label / phrasing / intensity).
///
/// Bug class: a new `ReactionKind` is added but a `switch kind` somewhere
/// falls through to `default`, returning empty / raw / nil for the new case.
/// The matrix walks every kind and asserts each surface is reachable.
@MainActor
final class MatrixReactionKindExhaustiveness_Tests: XCTestCase {

    /// Kinds with on-disk Events.strings pools (per `App/Resources/en.lproj/Events.strings`).
    /// `NotificationPhrase.eventPhrasing` resolves these via the on-disk file
    /// when `Bundle.main` is the app bundle. SPM tests don't have that bundle,
    /// so the matrix injects placeholder pools per kind first, then asserts
    /// the production code path picks them up.
    private static let kindsWithEventPools: [ReactionKind] = [
        .usbAttached, .usbDetached,
        .acConnected, .acDisconnected,
        .audioPeripheralAttached, .audioPeripheralDetached,
        .bluetoothConnected, .bluetoothDisconnected,
        .thunderboltAttached, .thunderboltDetached,
        .displayConfigured, .willSleep, .didWake,
    ]

    override func setUp() {
        super.setUp()
        NotificationPhrase._testClear()
    }

    override func tearDown() {
        NotificationPhrase._testClear()
        super.tearDown()
    }

    // MARK: - Cell A: every kind has an EventsSection.label

    /// Every `ReactionKind` (except `.impact`) must produce a non-empty
    /// localized label. `.impact` is excluded because it has no per-event
    /// row in the matrix UI — its label is rendered via the impact
    /// counter, not the event matrix.
    func testEveryKindHasANonEmptyLabel() {
        var violations: [String] = []
        for kind in ReactionKind.allCases {
            let label = StimuliSection.label(for: kind)
            if kind == .impact {
                // Documented: impacts have no event-row label.
                XCTAssertEqual(label, "",
                    "[kind=impact] expected empty label; got '\(label)' — drift in label fallthrough")
                continue
            }
            if label.isEmpty {
                violations.append("[kind=\(kind)] EventsSection.label returned empty — likely missing case in switch")
                continue
            }
            if label == kind.rawValue {
                violations.append("[kind=\(kind)] EventsSection.label returned the raw key '\(kind.rawValue)' — " +
                    "switch likely fell through to default, or NSLocalizedString missing")
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) label-exhaustiveness violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell B: every event-pooled kind has phrasing

    /// For each kind that has on-disk `Events.strings` pools, inject test
    /// pools and assert `eventPhrasing` picks them up. This catches a regression
    /// where someone adds a kind to Events.strings but forgets to update the
    /// eventPhrasing key formula or makes a typo in the prefix.
    func testEveryEventPooledKindHasPhrasing() {
        var pools: [String: [String]] = [:]
        for kind in Self.kindsWithEventPools {
            pools["title_\(kind.rawValue)"] = ["t-\(kind.rawValue)"]
            pools["body_\(kind.rawValue)"]  = ["b-\(kind.rawValue)"]
        }
        NotificationPhrase._testInjectEvents(pools: pools, for: "en")

        var violations: [String] = []
        for kind in Self.kindsWithEventPools {
            let phrase = NotificationPhrase.eventPhrasing(kind: kind, preferredLocale: "en")
            if phrase.title.isEmpty {
                violations.append("[kind=\(kind)] eventPhrasing returned empty title")
            }
            if phrase.body.isEmpty {
                violations.append("[kind=\(kind)] eventPhrasing returned empty body")
            }
            if phrase.title == kind.rawValue {
                violations.append("[kind=\(kind)] eventPhrasing title is raw key — pool lookup miss")
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) event-phrasing exhaustiveness violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell C: every kind has a synthesized intensity

    /// `ReactionsConfig.eventIntensity[kind]` must return non-nil for every
    /// `ReactionKind`. A new case missing from the dictionary literal would
    /// otherwise route through the `?? 0.5` default in `Reaction.intensity`,
    /// silently drowning out per-class tuning.
    func testEveryKindHasASynthesizedIntensity() {
        var violations: [String] = []
        for kind in ReactionKind.allCases {
            if ReactionsConfig.eventIntensity[kind] == nil {
                violations.append("[kind=\(kind)] missing entry in ReactionsConfig.eventIntensity " +
                    "— Reaction.intensity will silently fall back to 0.5")
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "Found \(violations.count) intensity-exhaustiveness violations:\n  • " +
            violations.joined(separator: "\n  • "))
    }

    // MARK: - Cell D: rawValue stability

    /// `ReactionKind.rawValue` doubles as the persisted key in
    /// `Codable` output and the `Events.strings` lookup prefix. Renaming a
    /// case silently invalidates user settings AND breaks all locales' event
    /// pools. Pin the canonical raw values to catch unintended renames.
    func testReactionKindRawValuesPinned() {
        let expected: [(ReactionKind, String)] = [
            (.impact, "impact"),
            (.usbAttached, "usbAttached"), (.usbDetached, "usbDetached"),
            (.acConnected, "acConnected"), (.acDisconnected, "acDisconnected"),
            (.audioPeripheralAttached, "audioPeripheralAttached"),
            (.audioPeripheralDetached, "audioPeripheralDetached"),
            (.bluetoothConnected, "bluetoothConnected"),
            (.bluetoothDisconnected, "bluetoothDisconnected"),
            (.thunderboltAttached, "thunderboltAttached"),
            (.thunderboltDetached, "thunderboltDetached"),
            (.displayConfigured, "displayConfigured"),
            (.willSleep, "willSleep"), (.didWake, "didWake"),
            (.trackpadTouching, "trackpadTouching"),
            (.trackpadSliding, "trackpadSliding"),
            (.trackpadContact, "trackpadContact"),
            (.trackpadTapping, "trackpadTapping"),
            (.trackpadCircling, "trackpadCircling"),
            (.mouseClicked, "mouseClicked"),
            (.mouseScrolled, "mouseScrolled"),
            (.keyboardTyped, "keyboardTyped"),
        ]
        // Drift detection: every allCases must appear in the pinned list.
        let pinnedKinds = Set(expected.map { $0.0 })
        let allKinds = Set(ReactionKind.allCases)
        XCTAssertEqual(pinnedKinds, allKinds,
            "[reaction-kind=allCases] kind set drift — pinned list out of sync with enum. " +
            "Missing from pinned: \(allKinds.subtracting(pinnedKinds))   " +
            "Stale in pinned: \(pinnedKinds.subtracting(allKinds))")
        for (kind, raw) in expected {
            XCTAssertEqual(kind.rawValue, raw,
                "[kind=\(kind) raw=\(kind.rawValue)] raw value drifted from pinned '\(raw)' — " +
                "this breaks Events.strings lookups and persisted user settings")
        }
    }
}
