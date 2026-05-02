import XCTest
@testable import YameteCore
@testable import YameteApp

/// Integration tests that lock the binding-keyPath inventories on each menu
/// section to the SettingsStore. These catch the bug class "binding goes to
/// wrong keyPath" where SwiftUI rendering points two unrelated controls at
/// the same property — the original 1.x bug had three trackpad sliders all
/// bound to `trackpadScrollMin/Max`. Each section exposes a pure
/// `*KeyPaths` static so rendering and assertions share one source of truth.
final class BindingIntegrityTests: IntegrationTestCase {

    // MARK: - StimuliSection per-kind range tuning

    /// For every kind that has a (low, high) tuning binding, assert the pair
    /// is unique across kinds. Catches "two kinds bound to the same setting".
    func testEventsKindTuningBindings_arePerKindUnique() {
        var seenLow: Set<AnyKeyPath> = []
        var seenHigh: Set<AnyKeyPath> = []
        for kind in ReactionKind.allCases {
            guard let pair = StimuliSection.kindTuningBindings(kind) else { continue }
            XCTAssertFalse(seenLow.contains(pair.low),
                           "[\(kind)] duplicate low keyPath \(pair.low)")
            XCTAssertFalse(seenHigh.contains(pair.high),
                           "[\(kind)] duplicate high keyPath \(pair.high)")
            XCTAssertNotEqual(pair.low as AnyKeyPath, pair.high as AnyKeyPath,
                              "[\(kind)] low and high keyPath must differ")
            seenLow.insert(pair.low)
            seenHigh.insert(pair.high)
        }
    }

    /// Mutation matrix: for each kind with bindings, set its low to a sentinel
    /// and assert ONLY that kind's low keyPath changed. Catches the regression
    /// where multiple kind sliders aliased the same keyPath pair.
    func testWritingOneKindBinding_doesNotMutateOtherKinds() {
        let kinds = ReactionKind.allCases.compactMap { kind -> ReactionKind? in
            StimuliSection.kindTuningBindings(kind) == nil ? nil : kind
        }
        for targetKind in kinds {
            let store = SettingsStore()
            store.resetToDefaults()
            guard let target = StimuliSection.kindTuningBindings(targetKind) else { continue }

            var snapshot: [(ReactionKind, Double, Double)] = []
            for kind in kinds where kind != targetKind {
                guard let p = StimuliSection.kindTuningBindings(kind) else { continue }
                snapshot.append((kind, store[keyPath: p.low], store[keyPath: p.high]))
            }
            // Pick a sentinel inside every kind's clamp range.
            let sentinel: Double
            switch targetKind {
            case .trackpadContact: sentinel = 0.42        // 0.1...5.0
            case .trackpadTapping: sentinel = 1.234       // 0.5...10.0
            default:               sentinel = 0.123456   // 0...1
            }
            store[keyPath: target.low] = sentinel
            for (kind, prevLow, prevHigh) in snapshot {
                guard let p = StimuliSection.kindTuningBindings(kind) else { continue }
                XCTAssertEqual(store[keyPath: p.low], prevLow, accuracy: 0.0001,
                               "[\(targetKind).low → \(kind).low] write must not bleed")
                XCTAssertEqual(store[keyPath: p.high], prevHigh, accuracy: 0.0001,
                               "[\(targetKind).low → \(kind).high] write must not bleed")
            }
        }
    }

    /// Mouse scroll uses a single-value slider, not a range slider. Confirms
    /// the single-value keyPath does NOT collide with any range-slider keyPath.
    func testMouseScrollKeyPath_isDistinctFromAllRangeBindings() {
        guard let single = StimuliSection.kindSingleTuningKeyPath(.mouseScrolled) else {
            XCTFail("mouseScrolled must have a single-value keyPath registered")
            return
        }
        for kind in ReactionKind.allCases {
            guard let pair = StimuliSection.kindTuningBindings(kind) else { continue }
            XCTAssertNotEqual(single as AnyKeyPath, pair.low as AnyKeyPath,
                              "mouseScroll keyPath must not alias \(kind).low")
            XCTAssertNotEqual(single as AnyKeyPath, pair.high as AnyKeyPath,
                              "mouseScroll keyPath must not alias \(kind).high")
        }
    }

    // MARK: - SensorSection per-sensor independence

    /// Mutation matrix: writing to one sensor's tuning parameter must not
    /// alter any other sensor's tuning parameter. The sensitivities of one
    /// sensor (accelerometer) bleeding into another (microphone) was a real
    /// 1.x bug class — hold the line at the binding inventory.
    func testWritingOneSensorTuning_doesNotMutateOtherSensors() {
        let sensors: [SensorID] = [.accelerometer, .microphone, .headphoneMotion]
        for targetSensor in sensors {
            let store = SettingsStore()
            store.resetToDefaults()
            let targets = SensorSection.sensorTuningKeyPaths(targetSensor)
            XCTAssertFalse(targets.isEmpty, "[\(targetSensor)] must declare ≥1 tuning keyPath")

            // Snapshot every other sensor's tuning values
            var snapshot: [(SensorID, [PartialKeyPath<SettingsStore>: Double])] = []
            for sensor in sensors where sensor != targetSensor {
                var captured: [PartialKeyPath<SettingsStore>: Double] = [:]
                for kp in SensorSection.sensorTuningKeyPaths(sensor) {
                    if let dkp = kp as? KeyPath<SettingsStore, Double> {
                        captured[kp] = store[keyPath: dkp]
                    } else if let ikp = kp as? KeyPath<SettingsStore, Int> {
                        captured[kp] = Double(store[keyPath: ikp])
                    }
                }
                snapshot.append((sensor, captured))
            }

            // Mutate every keyPath on the target sensor
            for kp in targets {
                if let dkp = kp as? ReferenceWritableKeyPath<SettingsStore, Double> {
                    let original = store[keyPath: dkp]
                    store[keyPath: dkp] = original * 0.5 + 0.0001  // safe under most clamps
                } else if let ikp = kp as? ReferenceWritableKeyPath<SettingsStore, Int> {
                    let original = store[keyPath: ikp]
                    store[keyPath: ikp] = max(1, original)  // no-op-safe nudge
                }
            }

            // Assert no other sensor's parameters drifted
            for (sensor, captured) in snapshot {
                for (kp, prev) in captured {
                    let now: Double
                    if let dkp = kp as? KeyPath<SettingsStore, Double> {
                        now = store[keyPath: dkp]
                    } else if let ikp = kp as? KeyPath<SettingsStore, Int> {
                        now = Double(store[keyPath: ikp])
                    } else {
                        continue
                    }
                    XCTAssertEqual(now, prev, accuracy: 0.0001,
                                   "[\(targetSensor) write → \(sensor)/\(kp)] cross-sensor bleed")
                }
            }
        }
    }

    /// Sensor keyPath inventories must not overlap between sensors.
    func testSensorTuningKeyPaths_areDisjoint() {
        let sensors: [SensorID] = [.accelerometer, .microphone, .headphoneMotion]
        var seen: [PartialKeyPath<SettingsStore>: SensorID] = [:]
        for sensor in sensors {
            for kp in SensorSection.sensorTuningKeyPaths(sensor) {
                if let owner = seen[kp] {
                    XCTFail("[\(sensor)] keyPath \(kp) already claimed by \(owner)")
                }
                seen[kp] = sensor
            }
        }
    }

    // MARK: - ResponseSection per-output independence

    /// Mutation matrix: writing to one output's parameter must not alter
    /// any other output's parameter. Catches "tint slider drives haptic intensity".
    func testWritingOneOutputParam_doesNotMutateOtherOutputs() {
        let outputs = ResponseSection.OutputID.allCases
        for targetOutput in outputs {
            let store = SettingsStore()
            store.resetToDefaults()
            let targets = ResponseSection.outputTuningKeyPaths(targetOutput)

            // Snapshot every other output's values
            var snapshot: [(ResponseSection.OutputID, [PartialKeyPath<SettingsStore>: AnyHashable])] = []
            for output in outputs where output != targetOutput {
                var captured: [PartialKeyPath<SettingsStore>: AnyHashable] = [:]
                for kp in ResponseSection.outputTuningKeyPaths(output) {
                    captured[kp] = readScalar(store: store, kp: kp)
                }
                snapshot.append((output, captured))
            }

            // Mutate every keyPath on the target output
            for kp in targets {
                writeNudge(store: store, kp: kp)
            }

            // Assert disjointness
            for (output, captured) in snapshot {
                for (kp, prev) in captured {
                    let now = readScalar(store: store, kp: kp)
                    XCTAssertEqual(now, prev,
                                   "[\(targetOutput) write → \(output)/\(kp)] cross-output bleed")
                }
            }
        }
    }

    /// Output keyPath inventories must not overlap between output cards.
    func testOutputTuningKeyPaths_areDisjoint() {
        var seen: [PartialKeyPath<SettingsStore>: ResponseSection.OutputID] = [:]
        for output in ResponseSection.OutputID.allCases {
            for kp in ResponseSection.outputTuningKeyPaths(output) {
                if let owner = seen[kp] {
                    XCTFail("[\(output)] keyPath \(kp) already claimed by \(owner)")
                }
                seen[kp] = output
            }
        }
    }

    // MARK: - DeviceSection collection independence

    /// Toggling one display must not mutate the audio-device list, and vice versa.
    func testToggleOneCollection_doesNotMutateOther() {
        let store = SettingsStore()
        store.resetToDefaults()

        // Seed both collections with disjoint sentinels
        store.enabledDisplays = [42]
        store.enabledAudioDevices = ["uid-A"]

        // Mutate displays only — audio must hold
        store.enabledDisplays = [42, 99]
        XCTAssertEqual(store.enabledAudioDevices, ["uid-A"],
                       "displays mutation bled into audio devices")

        // Mutate audio only — displays must hold
        store.enabledAudioDevices = ["uid-A", "uid-B"]
        XCTAssertEqual(store.enabledDisplays, [42, 99],
                       "audio devices mutation bled into displays")
    }

    /// DeviceSection keyPath inventory must use distinct keyPaths.
    func testDeviceCollectionKeyPaths_areDistinct() {
        let dKP = DeviceSection.collectionKeyPath(.displays)
        let aKP = DeviceSection.collectionKeyPath(.audioDevices)
        XCTAssertNotEqual(dKP, aKP, "displays and audioDevices must use distinct keyPaths")
    }

    // MARK: - SensitivitySection independence

    /// Sensitivity writes must not touch any output- or sensor-tuning keyPaths.
    func testSensitivityWrite_doesNotMutateOtherDomains() {
        let store = SettingsStore()
        store.resetToDefaults()

        // Snapshot a curated set of unrelated keyPaths
        let unrelated: [PartialKeyPath<SettingsStore>] = [
            \SettingsStore.volumeMin, \SettingsStore.volumeMax,
            \SettingsStore.flashOpacityMin, \SettingsStore.ledBrightnessMin,
            \SettingsStore.accelSpikeThreshold, \SettingsStore.micSpikeThreshold,
            \SettingsStore.hpSpikeThreshold, \SettingsStore.debounce,
            \SettingsStore.hapticIntensity, \SettingsStore.displayTintIntensity,
        ]
        let before = unrelated.map { readScalar(store: store, kp: $0) }

        let kp = SensitivitySection.sensitivityKeyPaths
        store[keyPath: kp.low] = 0.4321
        store[keyPath: kp.high] = 0.7654

        let after = unrelated.map { readScalar(store: store, kp: $0) }
        for (i, (b, a)) in zip(before, after).enumerated() {
            XCTAssertEqual(a, b, "[sensitivity write → \(unrelated[i])] cross-domain bleed")
        }
    }

    // MARK: - Helpers

    /// Reads a scalar (Double / Int / Bool / String / [Int] / [String]) from the
    /// store via PartialKeyPath, boxing into AnyHashable for equality compare.
    private func readScalar(store: SettingsStore, kp: PartialKeyPath<SettingsStore>) -> AnyHashable {
        if let dkp = kp as? KeyPath<SettingsStore, Double> { return AnyHashable(store[keyPath: dkp]) }
        if let ikp = kp as? KeyPath<SettingsStore, Int>    { return AnyHashable(store[keyPath: ikp]) }
        if let bkp = kp as? KeyPath<SettingsStore, Bool>   { return AnyHashable(store[keyPath: bkp]) }
        if let skp = kp as? KeyPath<SettingsStore, String> { return AnyHashable(store[keyPath: skp]) }
        if let akp = kp as? KeyPath<SettingsStore, [Int]>    { return AnyHashable(store[keyPath: akp]) }
        if let akp = kp as? KeyPath<SettingsStore, [String]> { return AnyHashable(store[keyPath: akp]) }
        return AnyHashable(0)
    }

    /// Writes a small in-range nudge to a settings property via PartialKeyPath.
    /// Each branch picks a value that the store's clamp accepts.
    private func writeNudge(store: SettingsStore, kp: PartialKeyPath<SettingsStore>) {
        if let dkp = kp as? ReferenceWritableKeyPath<SettingsStore, Double> {
            let v = store[keyPath: dkp]
            // Move slightly toward 0.5 — most ranges include 0.5 and clamps don't reject it.
            store[keyPath: dkp] = (v + 0.5) * 0.5
        } else if let ikp = kp as? ReferenceWritableKeyPath<SettingsStore, Int> {
            let v = store[keyPath: ikp]
            store[keyPath: ikp] = max(1, v)
        } else if let bkp = kp as? ReferenceWritableKeyPath<SettingsStore, Bool> {
            store[keyPath: bkp].toggle()
        } else if let skp = kp as? ReferenceWritableKeyPath<SettingsStore, String> {
            store[keyPath: skp] = "test-locale"
        }
    }
}
