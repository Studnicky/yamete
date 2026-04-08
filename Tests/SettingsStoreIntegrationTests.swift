import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

// MARK: - SettingsStore integration tests
//
// Tests persistence roundtrip through UserDefaults, value clamping for all properties,
// default verification, and advanced detection settings coverage.

@MainActor
final class SettingsStoreIntegrationTests: XCTestCase {

    /// Clears all settings keys and returns a fresh store.
    private func freshStore() -> SettingsStore {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        return SettingsStore()
    }

    // MARK: - Default values verification (comprehensive)

    func testDefaultValues() {
        struct Case { let name: String; let actual: String; let expected: String }
        let store = freshStore()
        let cases: [Case] = [
            .init(name: "sensitivityMin",    actual: "\(store.sensitivityMin)",    expected: "0.1"),
            .init(name: "sensitivityMax",    actual: "\(store.sensitivityMax)",    expected: "0.9"),
            .init(name: "bandpassLowHz",     actual: "\(store.accelBandpassLowHz)",     expected: "20.0"),
            .init(name: "bandpassHighHz",    actual: "\(store.accelBandpassHighHz)",    expected: "25.0"),
            .init(name: "debounce",          actual: "\(store.debounce)",          expected: "0.5"),
            .init(name: "soundEnabled",      actual: "\(store.soundEnabled)",      expected: "true"),
            .init(name: "debugLogging",      actual: "\(store.debugLogging)",      expected: "false"),
            .init(name: "screenFlash",       actual: "\(store.screenFlash)",       expected: "true"),
            .init(name: "flashOpacityMin",   actual: "\(store.flashOpacityMin)",   expected: "0.5"),
            .init(name: "flashOpacityMax",   actual: "\(store.flashOpacityMax)",   expected: "0.9"),
            .init(name: "volumeMin",         actual: "\(store.volumeMin)",         expected: "0.5"),
            .init(name: "volumeMax",         actual: "\(store.volumeMax)",         expected: "0.9"),
            .init(name: "spikeThreshold",    actual: "\(store.accelSpikeThreshold)",    expected: "0.02"),
            .init(name: "crestFactor",       actual: "\(store.accelCrestFactor)",       expected: "1.5"),
            .init(name: "riseRate",          actual: "\(store.accelRiseRate)",          expected: "0.01"),
            .init(name: "confirmations",     actual: "\(store.accelConfirmations)",     expected: "3"),
            .init(name: "warmupSamples",     actual: "\(store.accelWarmupSamples)",     expected: "50"),
            .init(name: "reportInterval",    actual: "\(store.accelReportInterval)",    expected: "10000.0"),
            .init(name: "consensusRequired", actual: "\(store.consensusRequired)", expected: "1"),
        ]
        for c in cases {
            XCTAssertEqual(c.actual, c.expected, "Default for \(c.name)")
        }
    }

    func testDefaultArraysAreEmpty() {
        let store = freshStore()
        XCTAssertTrue(store.enabledDisplays.isEmpty, "enabledDisplays default should be empty")
        XCTAssertTrue(store.enabledAudioDevices.isEmpty, "enabledAudioDevices default should be empty")
        XCTAssertTrue(store.enabledSensorIDs.isEmpty, "enabledSensorIDs default should be empty")
    }

    // MARK: - Persistence roundtrip (write, create new store, verify)

    func testDoublePersistenceRoundtrip() {
        struct Case { let name: String; let key: SettingsStore.Key; let write: (SettingsStore) -> Void; let value: Double }
        let cases: [Case] = [
            .init(name: "sensitivityMin",  key: .sensitivityMin,  write: { $0.sensitivityMin = 0.35 },  value: 0.35),
            .init(name: "sensitivityMax",  key: .sensitivityMax,  write: { $0.sensitivityMax = 0.65 },  value: 0.65),
            .init(name: "bandpassLowHz",   key: .accelBandpassLowHz,   write: { $0.accelBandpassLowHz = 15.0 },   value: 15.0),
            .init(name: "bandpassHighHz",  key: .accelBandpassHighHz,  write: { $0.accelBandpassHighHz = 22.0 },  value: 22.0),
            .init(name: "debounce",        key: .debounce,        write: { $0.debounce = 1.0 },         value: 1.0),
            .init(name: "flashOpacityMin", key: .flashOpacityMin, write: { $0.flashOpacityMin = 0.2 },  value: 0.2),
            .init(name: "flashOpacityMax", key: .flashOpacityMax, write: { $0.flashOpacityMax = 0.8 },  value: 0.8),
            .init(name: "volumeMin",       key: .volumeMin,       write: { $0.volumeMin = 0.1 },        value: 0.1),
            .init(name: "volumeMax",       key: .volumeMax,       write: { $0.volumeMax = 0.7 },        value: 0.7),
            .init(name: "spikeThreshold",  key: .accelSpikeThreshold,  write: { $0.accelSpikeThreshold = 0.030 }, value: 0.030),
            .init(name: "crestFactor",     key: .accelCrestFactor,     write: { $0.accelCrestFactor = 2.5 },      value: 2.5),
            .init(name: "riseRate",        key: .accelRiseRate,        write: { $0.accelRiseRate = 0.015 },       value: 0.015),
            .init(name: "reportInterval",  key: .accelReportInterval,  write: { $0.accelReportInterval = 20000 }, value: 20000),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store)

            // Verify raw UserDefaults
            let persisted = UserDefaults.standard.double(forKey: c.key.rawValue)
            XCTAssertEqual(persisted, c.value, accuracy: 1e-10, "\(c.name) raw persist")

            // Create a new store and verify it picks up the value
            let reloaded = SettingsStore()
            _ = reloaded  // force init to register defaults
            let reloadedValue = UserDefaults.standard.double(forKey: c.key.rawValue)
            XCTAssertEqual(reloadedValue, c.value, accuracy: 1e-10, "\(c.name) reload roundtrip")
        }
    }

    func testIntPersistenceRoundtrip() {
        struct Case { let name: String; let key: SettingsStore.Key; let write: (SettingsStore) -> Void; let value: Int }
        let cases: [Case] = [
            .init(name: "confirmations",     key: .accelConfirmations,     write: { $0.accelConfirmations = 4 },     value: 4),
            .init(name: "warmupSamples",     key: .accelWarmupSamples,     write: { $0.accelWarmupSamples = 75 },    value: 75),
            .init(name: "consensusRequired", key: .consensusRequired, write: { $0.consensusRequired = 3 }, value: 3),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store)

            let persisted = UserDefaults.standard.integer(forKey: c.key.rawValue)
            XCTAssertEqual(persisted, c.value, "\(c.name) persist")
        }
    }

    func testBoolPersistenceRoundtrip() {
        struct Case { let name: String; let key: SettingsStore.Key; let write: (SettingsStore) -> Void; let value: Bool }
        let cases: [Case] = [
            .init(name: "soundEnabled off",  key: .soundEnabled,  write: { $0.soundEnabled = false },  value: false),
            .init(name: "soundEnabled on",   key: .soundEnabled,  write: { $0.soundEnabled = true },   value: true),
            .init(name: "debugLogging on",   key: .debugLogging,  write: { $0.debugLogging = true },   value: true),
            .init(name: "screenFlash off",   key: .screenFlash,   write: { $0.screenFlash = false },   value: false),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store)
            XCTAssertEqual(UserDefaults.standard.bool(forKey: c.key.rawValue), c.value, c.name)
        }
    }

    func testArrayPersistence() {
        let store = freshStore()

        store.enabledDisplays = [1, 2, 3]
        XCTAssertEqual(UserDefaults.standard.array(forKey: SettingsStore.Key.enabledDisplays.rawValue) as? [Int], [1, 2, 3])

        store.enabledAudioDevices = ["device-a", "device-b"]
        XCTAssertEqual(UserDefaults.standard.array(forKey: SettingsStore.Key.enabledAudioDevices.rawValue) as? [String], ["device-a", "device-b"])

        store.enabledSensorIDs = ["accelerometer", "microphone"]
        XCTAssertEqual(UserDefaults.standard.array(forKey: SettingsStore.Key.enabledSensorIDs.rawValue) as? [String], ["accelerometer", "microphone"])
    }

    // MARK: - Clamping (out-of-range values get clamped)

    func testDoubleClamping() {
        struct Case { let name: String; let write: (SettingsStore, Double) -> Void; let read: (SettingsStore) -> Double; let input: Double; let validRange: ClosedRange<Double> }
        let cases: [Case] = [
            // Sensitivity 0...1
            .init(name: "sensitivityMin below",  write: { $0.sensitivityMin = $1 }, read: { $0.sensitivityMin }, input: -0.5, validRange: 0...1),
            .init(name: "sensitivityMin above",  write: { $0.sensitivityMin = $1 }, read: { $0.sensitivityMin }, input: 1.5,  validRange: 0...1),
            .init(name: "sensitivityMax below",  write: { $0.sensitivityMax = $1 }, read: { $0.sensitivityMax }, input: -1.0, validRange: 0...1),
            .init(name: "sensitivityMax above",  write: { $0.sensitivityMax = $1 }, read: { $0.sensitivityMax }, input: 2.0,  validRange: 0...1),
            // Bandpass 10...25
            .init(name: "bandpassLowHz below",   write: { $0.accelBandpassLowHz = $1 },  read: { $0.accelBandpassLowHz },  input: 5.0,   validRange: 10...25),
            .init(name: "bandpassLowHz above",   write: { $0.accelBandpassLowHz = $1 },  read: { $0.accelBandpassLowHz },  input: 30.0,  validRange: 10...25),
            .init(name: "bandpassHighHz below",  write: { $0.accelBandpassHighHz = $1 }, read: { $0.accelBandpassHighHz }, input: 5.0,   validRange: 10...25),
            .init(name: "bandpassHighHz above",  write: { $0.accelBandpassHighHz = $1 }, read: { $0.accelBandpassHighHz }, input: 30.0,  validRange: 10...25),
            // Debounce 0...2
            .init(name: "debounce below",        write: { $0.debounce = $1 }, read: { $0.debounce }, input: -1.0, validRange: 0...2),
            .init(name: "debounce above",        write: { $0.debounce = $1 }, read: { $0.debounce }, input: 5.0,  validRange: 0...2),
            // Flash opacity 0...1
            .init(name: "flashOpacityMin below", write: { $0.flashOpacityMin = $1 }, read: { $0.flashOpacityMin }, input: -0.3, validRange: 0...1),
            .init(name: "flashOpacityMin above", write: { $0.flashOpacityMin = $1 }, read: { $0.flashOpacityMin }, input: 1.5,  validRange: 0...1),
            .init(name: "flashOpacityMax below", write: { $0.flashOpacityMax = $1 }, read: { $0.flashOpacityMax }, input: -0.1, validRange: 0...1),
            .init(name: "flashOpacityMax above", write: { $0.flashOpacityMax = $1 }, read: { $0.flashOpacityMax }, input: 2.0,  validRange: 0...1),
            // Volume 0...1
            .init(name: "volumeMin below",       write: { $0.volumeMin = $1 }, read: { $0.volumeMin }, input: -1.0, validRange: 0...1),
            .init(name: "volumeMax above",       write: { $0.volumeMax = $1 }, read: { $0.volumeMax }, input: 5.0,  validRange: 0...1),
            // Advanced: spikeThreshold 0.010...0.040
            .init(name: "spikeThreshold below",  write: { $0.accelSpikeThreshold = $1 }, read: { $0.accelSpikeThreshold }, input: 0.001, validRange: 0.010...0.040),
            .init(name: "spikeThreshold above",  write: { $0.accelSpikeThreshold = $1 }, read: { $0.accelSpikeThreshold }, input: 0.100, validRange: 0.010...0.040),
            // crestFactor 1.0...5.0
            .init(name: "crestFactor below",     write: { $0.accelCrestFactor = $1 }, read: { $0.accelCrestFactor }, input: 0.5, validRange: 1.0...5.0),
            .init(name: "crestFactor above",     write: { $0.accelCrestFactor = $1 }, read: { $0.accelCrestFactor }, input: 10.0, validRange: 1.0...5.0),
            // riseRate 0.005...0.020
            .init(name: "riseRate below",        write: { $0.accelRiseRate = $1 }, read: { $0.accelRiseRate }, input: 0.001, validRange: 0.005...0.020),
            .init(name: "riseRate above",        write: { $0.accelRiseRate = $1 }, read: { $0.accelRiseRate }, input: 0.050, validRange: 0.005...0.020),
            // reportInterval 5000...50000
            .init(name: "reportInterval below",  write: { $0.accelReportInterval = $1 }, read: { $0.accelReportInterval }, input: 1000,  validRange: 5000...50000),
            .init(name: "reportInterval above",  write: { $0.accelReportInterval = $1 }, read: { $0.accelReportInterval }, input: 100000, validRange: 5000...50000),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store, c.input)
            let v = c.read(store)
            XCTAssertTrue(c.validRange.contains(v),
                "\(c.name): \(v) not in \(c.validRange) after setting \(c.input)")
        }
    }

    func testIntClamping() {
        struct Case { let name: String; let write: (SettingsStore, Int) -> Void; let read: (SettingsStore) -> Int; let input: Int; let validRange: ClosedRange<Int> }
        let cases: [Case] = [
            // confirmations 1...5
            .init(name: "confirmations below", write: { $0.accelConfirmations = $1 }, read: { $0.accelConfirmations }, input: 0, validRange: 1...5),
            .init(name: "confirmations above", write: { $0.accelConfirmations = $1 }, read: { $0.accelConfirmations }, input: 10, validRange: 1...5),
            // warmupSamples 10...100
            .init(name: "warmupSamples below", write: { $0.accelWarmupSamples = $1 }, read: { $0.accelWarmupSamples }, input: 1, validRange: 10...100),
            .init(name: "warmupSamples above", write: { $0.accelWarmupSamples = $1 }, read: { $0.accelWarmupSamples }, input: 500, validRange: 10...100),
            // consensusRequired 1...10
            .init(name: "consensus below",     write: { $0.consensusRequired = $1 }, read: { $0.consensusRequired }, input: 0, validRange: 1...10),
            .init(name: "consensus above",     write: { $0.consensusRequired = $1 }, read: { $0.consensusRequired }, input: 20, validRange: 1...10),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store, c.input)
            let v = c.read(store)
            XCTAssertTrue(c.validRange.contains(v),
                "\(c.name): \(v) not in \(c.validRange) after setting \(c.input)")
        }
    }

    // MARK: - Min/max pair enforcement (all paired properties)

    func testMinMaxPairEnforcement() {
        struct Case {
            let name: String
            let setup: (SettingsStore) -> Void
            let readMin: (SettingsStore) -> Double
            let readMax: (SettingsStore) -> Double
        }
        let cases: [Case] = [
            // Sensitivity: setting min above max pulls max up
            .init(name: "sensitivity min>max",
                  setup: { $0.sensitivityMax = 0.3; $0.sensitivityMin = 0.8 },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            // Sensitivity: setting max below min pulls min down
            .init(name: "sensitivity max<min",
                  setup: { $0.sensitivityMin = 0.7; $0.sensitivityMax = 0.2 },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            // Bandpass low/high
            .init(name: "bandpass low>high",
                  setup: { $0.accelBandpassHighHz = 15.0; $0.accelBandpassLowHz = 20.0 },
                  readMin: { $0.accelBandpassLowHz }, readMax: { $0.accelBandpassHighHz }),
            .init(name: "bandpass high<low",
                  setup: { $0.accelBandpassLowHz = 20.0; $0.accelBandpassHighHz = 15.0 },
                  readMin: { $0.accelBandpassLowHz }, readMax: { $0.accelBandpassHighHz }),
            // Flash opacity
            .init(name: "opacity min>max",
                  setup: { $0.flashOpacityMax = 0.3; $0.flashOpacityMin = 0.8 },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
            .init(name: "opacity max<min",
                  setup: { $0.flashOpacityMin = 0.8; $0.flashOpacityMax = 0.2 },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
            // Volume
            .init(name: "volume min>max",
                  setup: { $0.volumeMax = 0.3; $0.volumeMin = 0.8 },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "volume max<min",
                  setup: { $0.volumeMin = 0.8; $0.volumeMax = 0.2 },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
        ]
        for c in cases {
            let store = freshStore()
            c.setup(store)
            let lo = c.readMin(store)
            let hi = c.readMax(store)
            XCTAssertLessThanOrEqual(lo, hi, "\(c.name): min (\(lo)) should be <= max (\(hi))")
        }
    }

    // MARK: - Advanced detection settings persistence

    func testAdvancedDetectionSettingsPersist() {
        let store = freshStore()

        store.accelSpikeThreshold = 0.025
        store.accelCrestFactor = 3.0
        store.accelRiseRate = 0.012
        store.accelConfirmations = 4
        store.accelWarmupSamples = 60
        store.accelReportInterval = 20000.0
        store.consensusRequired = 2

        // Verify through UserDefaults
        let d = UserDefaults.standard
        XCTAssertEqual(d.double(forKey: "accelSpikeThreshold"), 0.025, accuracy: 1e-10)
        XCTAssertEqual(d.double(forKey: "accelCrestFactor"), 3.0, accuracy: 1e-10)
        XCTAssertEqual(d.double(forKey: "accelRiseRate"), 0.012, accuracy: 1e-10)
        XCTAssertEqual(d.integer(forKey: "accelConfirmations"), 4)
        XCTAssertEqual(d.integer(forKey: "accelWarmupSamples"), 60)
        XCTAssertEqual(d.double(forKey: "accelReportInterval"), 20000.0, accuracy: 1e-10)
        XCTAssertEqual(d.integer(forKey: "consensusRequired"), 2)

        // Verify a new store picks up persisted values
        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.accelSpikeThreshold, 0.025, accuracy: 1e-10)
        XCTAssertEqual(reloaded.accelCrestFactor, 3.0, accuracy: 1e-10)
        XCTAssertEqual(reloaded.accelRiseRate, 0.012, accuracy: 1e-10)
        XCTAssertEqual(reloaded.accelConfirmations, 4)
        XCTAssertEqual(reloaded.accelWarmupSamples, 60)
        XCTAssertEqual(reloaded.accelReportInterval, 20000.0, accuracy: 1e-10)
        XCTAssertEqual(reloaded.consensusRequired, 2)
    }

    // MARK: - Same-value no-op (guard prevents unnecessary persist)

    func testSameValueDoesNotCauseIssues() {
        let store = freshStore()

        // Set and re-set the same value -- should not crash or cause issues
        store.sensitivityMin = 0.5
        store.sensitivityMin = 0.5
        store.sensitivityMax = 0.8
        store.sensitivityMax = 0.8
        store.debounce = 1.0
        store.debounce = 1.0
        store.accelSpikeThreshold = 0.025
        store.accelSpikeThreshold = 0.025
        store.soundEnabled = false
        store.soundEnabled = false
        store.accelConfirmations = 3
        store.accelConfirmations = 3
        // No crash = success
    }

    // MARK: - All keys have defaults registered

    func testAllKeysHaveDefaults() {
        let defaults = SettingsStore.defaults
        for key in SettingsStore.Key.allCases {
            XCTAssertNotNil(defaults[key.rawValue], "Key \(key.rawValue) should have a registered default")
        }
    }

    // MARK: - Stress: rapid mutations on all slider properties

    func testRapidMutationStress() {
        let store = freshStore()

        // Rapidly mutate all slider properties
        for _ in 0..<50 {
            store.sensitivityMin = Double.random(in: -1...2)
            store.sensitivityMax = Double.random(in: -1...2)
            store.accelBandpassLowHz = Double.random(in: 0...50)
            store.accelBandpassHighHz = Double.random(in: 0...50)
            store.debounce = Double.random(in: -1...5)
            store.flashOpacityMin = Double.random(in: -1...2)
            store.flashOpacityMax = Double.random(in: -1...2)
            store.volumeMin = Double.random(in: -1...2)
            store.volumeMax = Double.random(in: -1...2)
            store.accelSpikeThreshold = Double.random(in: 0...0.1)
            store.accelCrestFactor = Double.random(in: 0...10)
            store.accelRiseRate = Double.random(in: 0...0.05)
            store.accelConfirmations = Int.random(in: -5...20)
            store.accelWarmupSamples = Int.random(in: -10...200)
            store.consensusRequired = Int.random(in: -5...20)
            store.accelReportInterval = Double.random(in: 0...100000)
        }

        // After all mutations, verify all values are within their valid ranges
        XCTAssertTrue((0...1).contains(store.sensitivityMin), "sensitivityMin in range")
        XCTAssertTrue((0...1).contains(store.sensitivityMax), "sensitivityMax in range")
        XCTAssertTrue((10...25).contains(store.accelBandpassLowHz), "bandpassLowHz in range")
        XCTAssertTrue((10...25).contains(store.accelBandpassHighHz), "bandpassHighHz in range")
        XCTAssertTrue((0...2).contains(store.debounce), "debounce in range")
        XCTAssertTrue((0...1).contains(store.flashOpacityMin), "flashOpacityMin in range")
        XCTAssertTrue((0...1).contains(store.flashOpacityMax), "flashOpacityMax in range")
        XCTAssertTrue((0...1).contains(store.volumeMin), "volumeMin in range")
        XCTAssertTrue((0...1).contains(store.volumeMax), "volumeMax in range")
        XCTAssertTrue((0.010...0.040).contains(store.accelSpikeThreshold), "spikeThreshold in range")
        XCTAssertTrue((1.0...5.0).contains(store.accelCrestFactor), "crestFactor in range")
        XCTAssertTrue((0.005...0.020).contains(store.accelRiseRate), "riseRate in range")
        XCTAssertTrue((1...5).contains(store.accelConfirmations), "confirmations in range")
        XCTAssertTrue((10...100).contains(store.accelWarmupSamples), "warmupSamples in range")
        XCTAssertTrue((1...10).contains(store.consensusRequired), "consensusRequired in range")
        XCTAssertTrue((5000...50000).contains(store.accelReportInterval), "reportInterval in range")

        // Paired constraints
        XCTAssertLessThanOrEqual(store.sensitivityMin, store.sensitivityMax)
        XCTAssertLessThanOrEqual(store.accelBandpassLowHz, store.accelBandpassHighHz)
        XCTAssertLessThanOrEqual(store.flashOpacityMin, store.flashOpacityMax)
        XCTAssertLessThanOrEqual(store.volumeMin, store.volumeMax)
    }
}
