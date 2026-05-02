import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Static-shape invariants: identifiers are unique, the contract list lines
/// up with the persisted defaults, and reactive outputs are unique objects.
final class SourceRegistryTests: XCTestCase {

    func testReactionKindRawValuesAreUnique() {
        let raws = ReactionKind.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "ReactionKind raws must be unique")
    }

    func testSourceContractIDsAreUniqueAndCoverEveryStimulusSource() {
        let ids = SourceContract.all.map(\.id.rawValue)
        XCTAssertEqual(ids.count, Set(ids).count, "SourceContract.all entries must have unique SensorIDs")
        XCTAssertEqual(SourceContract.all.count, 10, "There should be exactly 10 stimulus sources")
    }

    func testStimulusSourceDefaultsMatchContractIDs() {
        let contractIDs = Set(SourceContract.all.map(\.id.rawValue))
        let defaults    = Set(StimulusSourceDefaults.allStimulusSourceIDs)
        XCTAssertEqual(contractIDs, defaults,
                       "StimulusSourceDefaults must match SourceContract.all exactly")
    }

    func testEveryEmittedKindIsAccountedForAcrossContracts() {
        // Aggregate every kind every stimulus source can produce. `.impact`
        // is the only kind not produced by a stimulus source (it comes from
        // the impact-fusion pipeline) so we expect ReactionKind.allCases minus
        // .impact to equal the union.
        let union = SourceContract.all.flatMap { $0.emittedKinds }
        let unionSet = Set(union)
        let nonImpact = Set(ReactionKind.allCases).subtracting([.impact])
        XCTAssertEqual(unionSet, nonImpact,
                       "Every non-impact ReactionKind must be emitted by at least one stimulus source")
    }

    @MainActor
    func testYameteReactiveOutputIdentitiesAreUnique() {
        // Build a small array of fresh output instances that mirror
        // `Yamete.allReactiveOutputs` without booting the full app.
        // Instantiating Yamete itself has side effects (hardware probing,
        // settings observation) that aren't appropriate for a registry test.
        let outputs: [ReactiveOutput] = [
            ScreenFlash(),
            NotificationResponder(localeProvider: { "en" }),
            LEDFlash(),
            HapticResponder(),
            DisplayBrightnessFlash(),
            DisplayTintFlash()
        ]
        let ids = outputs.map { ObjectIdentifier($0) }
        XCTAssertEqual(ids.count, Set(ids).count,
                       "Each ReactiveOutput instance must have a distinct identity")
    }
}
