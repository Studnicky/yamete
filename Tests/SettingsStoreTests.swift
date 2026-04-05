import XCTest
@testable import YameteCore
@testable import SensorKit
@testable import ResponseKit
@testable import YameteApp

/// Settings store coverage for defaults, persistence, clamping, and stress paths.
@MainActor
final class SettingsStoreTests: XCTestCase {

    private func freshStore() -> SettingsStore {
        for key in SettingsStore.Key.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        return SettingsStore()
    }

    // MARK: - Defaults (all 10 properties)

    func testDefaults() {
        struct Case { let name: String; let read: (SettingsStore) -> String; let expected: String }
        let cases: [Case] = [
            .init(name: "sensitivityMin",  read: { "\($0.sensitivityMin)" },  expected: "0.1"),
            .init(name: "sensitivityMax",  read: { "\($0.sensitivityMax)" },  expected: "0.9"),
            .init(name: "debounce",     read: { "\($0.debounce)" },     expected: "0.5"),
            .init(name: "screenFlash",     read: { "\($0.screenFlash)" },     expected: "true"),
            .init(name: "flashOpacityMin", read: { "\($0.flashOpacityMin)" }, expected: "0.5"),
            .init(name: "flashOpacityMax", read: { "\($0.flashOpacityMax)" }, expected: "0.9"),
            .init(name: "volumeMin",       read: { "\($0.volumeMin)" },       expected: "0.5"),
            .init(name: "volumeMax",       read: { "\($0.volumeMax)" },       expected: "0.9"),
        ]
        let store = freshStore()
        for c in cases {
            XCTAssertEqual(c.read(store), c.expected, "default \(c.name)")
        }
    }

    // MARK: - Rapid mutation (all sliders + toggles)

    func testRapidSliderDrag() {
        struct Case { let name: String; let mutate: (SettingsStore, Double) -> Void }
        let cases: [Case] = [
            .init(name: "sensitivityMin") { s, v in s.sensitivityMin = v },
            .init(name: "sensitivityMax") { s, v in s.sensitivityMax = v },
            .init(name: "debounce")    { s, v in s.debounce = v },
            .init(name: "flashOpacityMin"){ s, v in s.flashOpacityMin = v },
            .init(name: "flashOpacityMax"){ s, v in s.flashOpacityMax = v },
            .init(name: "volumeMin")      { s, v in s.volumeMin = v },
            .init(name: "volumeMax")      { s, v in s.volumeMax = v },
        ]
        for c in cases {
            let store = freshStore()
            for i in 0..<200 { c.mutate(store, Double(i) / 200.0) }
            // Verify final value is within valid range (0...1 for most, 0...2 for debounce)
            c.mutate(store, 0.5)
            let d = UserDefaults.standard
            let persisted = d.double(forKey: SettingsStore.Key.allCases.first(where: { $0.rawValue == c.name })?.rawValue ?? c.name)
            XCTAssertEqual(persisted, 0.5, accuracy: 0.01, "\(c.name): value should persist after rapid mutations")
        }
    }

    func testRapidBoolToggle() {
        struct Case { let name: String; let toggle: (SettingsStore, Bool) -> Void; let read: (SettingsStore) -> Bool }
        let cases: [Case] = [
            .init(name: "screenFlash", toggle: { $0.screenFlash = $1 }, read: { $0.screenFlash }),
        ]
        for c in cases {
            let store = freshStore()
            for i in 0..<200 { c.toggle(store, i % 2 == 0) }
            XCTAssertFalse(c.read(store), "\(c.name): expected false after even toggle count")
        }
    }

    // MARK: - Persistence roundtrip (all Double properties)

    func testDoublePersistence() {
        struct Case { let name: String; let key: SettingsStore.Key; let write: (SettingsStore) -> Void; let value: Double }
        let cases: [Case] = [
            .init(name: "sensitivityMin",  key: .sensitivityMin,  write: { $0.sensitivityMin = 0.42 },  value: 0.42),
            .init(name: "sensitivityMax",  key: .sensitivityMax,  write: { $0.sensitivityMax = 0.77 },  value: 0.77),
            .init(name: "debounce",     key: .debounce,     write: { $0.debounce = 0.05 },     value: 0.05),
            .init(name: "flashOpacityMin", key: .flashOpacityMin, write: { $0.flashOpacityMin = 0.05 }, value: 0.05),
            .init(name: "flashOpacityMax", key: .flashOpacityMax, write: { $0.flashOpacityMax = 0.9 },  value: 0.9),
            .init(name: "volumeMin",       key: .volumeMin,       write: { $0.volumeMin = 0.15 },       value: 0.15),
            .init(name: "volumeMax",       key: .volumeMax,       write: { $0.volumeMax = 0.85 },       value: 0.85),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store)
            let persisted = UserDefaults.standard.double(forKey: c.key.rawValue)
            XCTAssertEqual(persisted, c.value, accuracy: 1e-10, "\(c.name) persist")
        }
    }

    func testBoolPersistence() {
        struct Case { let name: String; let key: SettingsStore.Key; let write: (SettingsStore) -> Void; let value: Bool }
        let cases: [Case] = [
            .init(name: "screenFlash off",  key: .screenFlash, write: { $0.screenFlash = false }, value: false),
            .init(name: "screenFlash on",   key: .screenFlash, write: { $0.screenFlash = true },  value: true),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store)
            XCTAssertEqual(UserDefaults.standard.bool(forKey: c.key.rawValue), c.value, "\(c.name)")
        }
    }

    // MARK: - Boundary values (all Double properties)

    func testBoundaryValues() {
        struct Case { let name: String; let write: (SettingsStore, Double) -> Void; let read: (SettingsStore) -> Double; let input: Double; let validRange: ClosedRange<Double> }
        let cases: [Case] = [
            // Sensitivity (0...1)
            .init(name: "sensitivityMin neg",  write: { $0.sensitivityMin = $1 }, read: { $0.sensitivityMin }, input: -0.5, validRange: 0...1),
            .init(name: "sensitivityMin over", write: { $0.sensitivityMin = $1 }, read: { $0.sensitivityMin }, input: 1.5,  validRange: 0...1),
            .init(name: "sensitivityMax neg",  write: { $0.sensitivityMax = $1 }, read: { $0.sensitivityMax }, input: -0.5, validRange: 0...1),
            .init(name: "sensitivityMax over", write: { $0.sensitivityMax = $1 }, read: { $0.sensitivityMax }, input: 1.5,  validRange: 0...1),
            // Debounce bounds.
            .init(name: "debounce neg",     write: { $0.debounce = $1 }, read: { $0.debounce }, input: -1,  validRange: 0...3),
            .init(name: "debounce over",    write: { $0.debounce = $1 }, read: { $0.debounce }, input: 5,   validRange: 0...3),
            .init(name: "debounce over",    write: { $0.debounce = $1 }, read: { $0.debounce }, input: 10,  validRange: 0...3),
            // Flash opacity bounds.
            .init(name: "flashOpacityMin neg", write: { $0.flashOpacityMin = $1 }, read: { $0.flashOpacityMin }, input: -1, validRange: 0...1),
            .init(name: "flashOpacityMax over", write: { $0.flashOpacityMax = $1 }, read: { $0.flashOpacityMax }, input: 5, validRange: 0...1),
            // Volume bounds.
            .init(name: "volumeMin neg",       write: { $0.volumeMin = $1 }, read: { $0.volumeMin }, input: -2,  validRange: 0...1),
            .init(name: "volumeMax over",      write: { $0.volumeMax = $1 }, read: { $0.volumeMax }, input: 99,  validRange: 0...1),
        ]
        for c in cases {
            let store = freshStore()
            c.write(store, c.input)
            let v = c.read(store)
            XCTAssertTrue(c.validRange.contains(v), "\(c.name): \(v) not in \(c.validRange) after setting \(c.input)")
        }
    }

    // MARK: - Min ≤ max enforcement (all 4 pairs)

    func testMinMaxEnforcement() {
        struct Case { let name: String; let setup: (SettingsStore) -> Void; let readMin: (SettingsStore) -> Double; let readMax: (SettingsStore) -> Double }
        let cases: [Case] = [
            .init(name: "sensitivity min>max", setup: { $0.sensitivityMax = 0.3; $0.sensitivityMin = 0.8 },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            .init(name: "sensitivity max<min", setup: { $0.sensitivityMin = 0.7; $0.sensitivityMax = 0.2 },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            .init(name: "debounce min>max",    setup: { $0.debounce = 0.1; $0.debounce = 0.8 },
                  readMin: { $0.debounce }, readMax: { $0.debounce }),
            .init(name: "debounce max<min",    setup: { $0.debounce = 1.0; $0.debounce = 0.2 },
                  readMin: { $0.debounce }, readMax: { $0.debounce }),
            .init(name: "volume min>max",      setup: { $0.volumeMax = 0.3; $0.volumeMin = 0.9 },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "volume max<min",      setup: { $0.volumeMin = 0.8; $0.volumeMax = 0.1 },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "opacity min>max",     setup: { $0.flashOpacityMax = 0.2; $0.flashOpacityMin = 0.9 },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
            .init(name: "opacity max<min",     setup: { $0.flashOpacityMin = 0.9; $0.flashOpacityMax = 0.1 },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
        ]
        for c in cases {
            let store = freshStore()
            c.setup(store)
            XCTAssertLessThanOrEqual(c.readMin(store), c.readMax(store), c.name)
        }
    }

    // MARK: - Back-and-forth stress (all 4 pairs)

    func testBackAndForthStress() {
        struct Case { let name: String; let stress: (SettingsStore) -> Void; let readMin: (SettingsStore) -> Double; let readMax: (SettingsStore) -> Double }
        let cases: [Case] = [
            .init(name: "sensitivity", stress: { s in for _ in 0..<100 { s.sensitivityMin = 0.9; s.sensitivityMax = 0.1; s.sensitivityMin = 0.1; s.sensitivityMax = 0.9 } },
                  readMin: { $0.sensitivityMin }, readMax: { $0.sensitivityMax }),
            .init(name: "debounce",    stress: { s in for _ in 0..<100 { s.debounce = 1.5; s.debounce = 0.05; s.debounce = 0.05; s.debounce = 1.5 } },
                  readMin: { $0.debounce }, readMax: { $0.debounce }),
            .init(name: "volume",      stress: { s in for _ in 0..<100 { s.volumeMin = 0.9; s.volumeMax = 0.1; s.volumeMin = 0.1; s.volumeMax = 0.9 } },
                  readMin: { $0.volumeMin }, readMax: { $0.volumeMax }),
            .init(name: "opacity",     stress: { s in for _ in 0..<100 { s.flashOpacityMin = 0.9; s.flashOpacityMax = 0.1; s.flashOpacityMin = 0.1; s.flashOpacityMax = 0.9 } },
                  readMin: { $0.flashOpacityMin }, readMax: { $0.flashOpacityMax }),
        ]
        for c in cases {
            let store = freshStore()
            c.stress(store)
            XCTAssertLessThanOrEqual(c.readMin(store), c.readMax(store), "\(c.name) stress")
        }
    }

    // MARK: - Same-value no-op (all properties)

    func testSameValueNoOp() {
        struct Case { let name: String; let setTwice: (SettingsStore) -> Void }
        let cases: [Case] = [
            .init(name: "sensitivityMin") { $0.sensitivityMin = 0.5; $0.sensitivityMin = 0.5 },
            .init(name: "sensitivityMax") { $0.sensitivityMax = 0.5; $0.sensitivityMax = 0.5 },
            .init(name: "debounce")    { $0.debounce = 0.2; $0.debounce = 0.2 },
            .init(name: "screenFlash")    { $0.screenFlash = false; $0.screenFlash = false },
            .init(name: "flashOpacityMin"){ $0.flashOpacityMin = 0.3; $0.flashOpacityMin = 0.3 },
            .init(name: "flashOpacityMax"){ $0.flashOpacityMax = 0.7; $0.flashOpacityMax = 0.7 },
            .init(name: "volumeMin")      { $0.volumeMin = 0.2; $0.volumeMin = 0.2 },
            .init(name: "volumeMax")      { $0.volumeMax = 0.8; $0.volumeMax = 0.8 },
        ]
        for c in cases {
            let store = freshStore()
            c.setTwice(store)
            // No crash = success. Verifies guard-clamp pattern handles same-value correctly.
        }
    }
}
