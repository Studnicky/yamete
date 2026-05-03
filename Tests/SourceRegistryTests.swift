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
        // `enabledStimulusSourceIDs` defaults are a SUPERSET of `SourceContract.all`
        // because GyroscopeSource is direct-publish (off-MainActor) and cannot
        // conform to the `@MainActor` StimulusSource protocol — but its enable
        // toggle still flows through the same persisted ID list. The contract
        // IDs must be a strict subset of the default ID set.
        let contractIDs = Set(SourceContract.all.map(\.id.rawValue))
        let defaults    = Set(StimulusSourceDefaults.allStimulusSourceIDs)
        XCTAssertTrue(contractIDs.isSubset(of: defaults),
                      "SourceContract.all IDs must be a subset of StimulusSourceDefaults — missing in defaults: \(contractIDs.subtracting(defaults))")
        let extras = defaults.subtracting(contractIDs)
        // Legal extras are sources that subscribe to the SPU HID
        // broker — gyroscope, lidAngle, ambientLight. All have
        // off-MainActor HID-callback handlers and cannot conform to
        // the `@MainActor`-isolated `StimulusSource` protocol. See the
        // `SourceContract.nonContractKinds` doc for the rationale.
        XCTAssertEqual(extras, [SensorID.gyroscope.rawValue, SensorID.lidAngle.rawValue, SensorID.ambientLight.rawValue],
                       "StimulusSourceDefaults entries with no SourceContract must be {gyroscope, lidAngle, ambientLight}, got \(extras)")
    }

    func testEveryEmittedKindIsAccountedForAcrossContracts() {
        // Aggregate every kind every stimulus source can produce. `.impact`
        // is the only kind not produced by a stimulus source (it comes from
        // the impact-fusion pipeline). `SourceContract.nonContractKinds` adds
        // kinds emitted by direct-publish off-MainActor sources (currently
        // .gyroSpike from GyroscopeSource) that the @MainActor StimulusSource
        // protocol cannot host.
        let union = Set(SourceContract.all.flatMap(\.emittedKinds))
            .union(SourceContract.nonContractKinds)
        let nonImpact = Set(ReactionKind.allCases).subtracting([.impact])
        XCTAssertEqual(union, nonImpact,
                       "Every non-impact ReactionKind must be emitted by at least one stimulus source (contract or non-contract)")
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
