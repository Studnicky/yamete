#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import Observation

/// User settings persisted in `UserDefaults`.
/// Includes guard-clamp updates to avoid recursive `didSet` loops.
@MainActor @Observable
public final class SettingsStore {

    // MARK: - Keys

    enum Key: String, CaseIterable, Sendable {
        case sensitivityMin, sensitivityMax
        case debounce
        case screenFlash
        case flashOpacityMin, flashOpacityMax
        case volumeMin, volumeMax
        case soundEnabled, debugLogging, enabledDisplays, enabledAudioDevices, enabledSensorIDs
        case consensusRequired
        // Accelerometer detection
        case accelSpikeThreshold, accelCrestFactor, accelRiseRate, accelConfirmations
        case accelWarmupSamples, accelReportInterval, accelBandpassLowHz, accelBandpassHighHz
        // Microphone detection
        case micSpikeThreshold, micCrestFactor, micRiseRate, micConfirmations, micWarmupSamples
        // Headphone motion detection
        case hpSpikeThreshold, hpCrestFactor, hpRiseRate, hpConfirmations, hpWarmupSamples
    }

    // MARK: - Defaults

    static let defaults: [String: Any] = [
        Key.sensitivityMin.rawValue:  0.10,
        Key.sensitivityMax.rawValue:  0.90,
        Key.debounce.rawValue:        0.5,
        Key.soundEnabled.rawValue:    true,
        Key.debugLogging.rawValue:    false,
        Key.screenFlash.rawValue:     true,
        Key.flashOpacityMin.rawValue: 0.50,
        Key.flashOpacityMax.rawValue: 0.9,
        Key.volumeMin.rawValue:       0.50,
        Key.volumeMax.rawValue:       0.9,
        Key.enabledDisplays.rawValue: [Int](),
        Key.enabledAudioDevices.rawValue: [String](),
        Key.enabledSensorIDs.rawValue: [String](),
        Key.consensusRequired.rawValue: 1,
        // Accelerometer detection
        Key.accelSpikeThreshold.rawValue:  0.020,
        Key.accelCrestFactor.rawValue:     1.5,
        Key.accelRiseRate.rawValue:        0.010,
        Key.accelConfirmations.rawValue:   3,
        Key.accelWarmupSamples.rawValue:   50,
        Key.accelReportInterval.rawValue:  10000.0,
        Key.accelBandpassLowHz.rawValue:   20.0,
        Key.accelBandpassHighHz.rawValue:  25.0,
        // Microphone detection
        Key.micSpikeThreshold.rawValue: 0.020,
        Key.micCrestFactor.rawValue:    1.5,
        Key.micRiseRate.rawValue:       0.010,
        Key.micConfirmations.rawValue:  2,
        Key.micWarmupSamples.rawValue:  50,
        // Headphone motion detection
        Key.hpSpikeThreshold.rawValue:  0.10,
        Key.hpCrestFactor.rawValue:     1.5,
        Key.hpRiseRate.rawValue:        0.05,
        Key.hpConfirmations.rawValue:   2,
        Key.hpWarmupSamples.rawValue:   50,
    ]

    // MARK: - Reactivity (inverted sensitivity: higher value = lower force threshold)

    var sensitivityMin: Double {
        didSet {
            guard sensitivityMin != oldValue else { return }
            let c = sensitivityMin.clamped(to: 0...1)
            if c != sensitivityMin { sensitivityMin = c; return }
            persist(sensitivityMin, .sensitivityMin)
            if sensitivityMin > sensitivityMax { sensitivityMax = sensitivityMin }
        }
    }

    var sensitivityMax: Double {
        didSet {
            guard sensitivityMax != oldValue else { return }
            let c = sensitivityMax.clamped(to: 0...1)
            if c != sensitivityMax { sensitivityMax = c; return }
            persist(sensitivityMax, .sensitivityMax)
            if sensitivityMax < sensitivityMin { sensitivityMin = sensitivityMax }
        }
    }

    // MARK: - Frequency band (bandpass filter)

    /// High-pass cutoff: vibrations below this frequency are rejected (footsteps, HVAC).
    var accelBandpassLowHz: Double {
        didSet {
            guard accelBandpassLowHz != oldValue else { return }
            let c = accelBandpassLowHz.clamped(to: 10...25)
            if c != accelBandpassLowHz { accelBandpassLowHz = c; return }
            persist(accelBandpassLowHz, .accelBandpassLowHz)
            if accelBandpassLowHz > accelBandpassHighHz { accelBandpassHighHz = accelBandpassLowHz }
        }
    }

    /// Low-pass cutoff: vibrations above this frequency are rejected (electronic noise, rattling).
    var accelBandpassHighHz: Double {
        didSet {
            guard accelBandpassHighHz != oldValue else { return }
            let c = accelBandpassHighHz.clamped(to: 10...25)
            if c != accelBandpassHighHz { accelBandpassHighHz = c; return }
            persist(accelBandpassHighHz, .accelBandpassHighHz)
            if accelBandpassHighHz < accelBandpassLowHz { accelBandpassLowHz = accelBandpassHighHz }
        }
    }

    // MARK: - Debounce

    var debounce: Double {
        didSet {
            guard debounce != oldValue else { return }
            let c = debounce.clamped(to: 0...2)
            if c != debounce { debounce = c; return }
            persist(debounce, .debounce)
        }
    }

    // MARK: - Response toggles

    var soundEnabled: Bool {
        didSet {
            guard soundEnabled != oldValue else { return }
            persist(soundEnabled, .soundEnabled)
        }
    }

    var debugLogging: Bool {
        didSet {
            guard debugLogging != oldValue else { return }
            persist(debugLogging, .debugLogging)
        }
    }

    var screenFlash: Bool {
        didSet {
            guard screenFlash != oldValue else { return }
            persist(screenFlash, .screenFlash)
        }
    }

    // MARK: - Flash opacity band (intensity → flash brightness)

    var flashOpacityMin: Double {
        didSet {
            guard flashOpacityMin != oldValue else { return }
            let c = flashOpacityMin.clamped(to: 0...1)
            if c != flashOpacityMin { flashOpacityMin = c; return }
            persist(flashOpacityMin, .flashOpacityMin)
            if flashOpacityMin > flashOpacityMax { flashOpacityMax = flashOpacityMin }
        }
    }

    var flashOpacityMax: Double {
        didSet {
            guard flashOpacityMax != oldValue else { return }
            let c = flashOpacityMax.clamped(to: 0...1)
            if c != flashOpacityMax { flashOpacityMax = c; return }
            persist(flashOpacityMax, .flashOpacityMax)
            if flashOpacityMax < flashOpacityMin { flashOpacityMin = flashOpacityMax }
        }
    }

    // MARK: - Volume band (intensity → audio level)

    var volumeMin: Double {
        didSet {
            guard volumeMin != oldValue else { return }
            let c = volumeMin.clamped(to: 0...1)
            if c != volumeMin { volumeMin = c; return }
            persist(volumeMin, .volumeMin)
            if volumeMin > volumeMax { volumeMax = volumeMin }
        }
    }

    var volumeMax: Double {
        didSet {
            guard volumeMax != oldValue else { return }
            let c = volumeMax.clamped(to: 0...1)
            if c != volumeMax { volumeMax = c; return }
            persist(volumeMax, .volumeMax)
            if volumeMax < volumeMin { volumeMin = volumeMax }
        }
    }

    // MARK: - Display + audio device selection

    /// CGDirectDisplayID values of enabled displays. Empty = all displays.
    public var enabledDisplays: [Int] {
        didSet {
            guard enabledDisplays != oldValue else { return }
            persist(enabledDisplays, .enabledDisplays)
        }
    }

    /// Core Audio device UIDs for audio output. Empty = system default only.
    public var enabledAudioDevices: [String] {
        didSet {
            guard enabledAudioDevices != oldValue else { return }
            persist(enabledAudioDevices, .enabledAudioDevices)
        }
    }

    /// SensorAdapter IDs to enable. Empty = all available adapters.
    public var enabledSensorIDs: [String] {
        didSet {
            guard enabledSensorIDs != oldValue else { return }
            persist(enabledSensorIDs, .enabledSensorIDs)
        }
    }

    // MARK: - Accelerometer detection

    var accelSpikeThreshold: Double {
        didSet {
            guard accelSpikeThreshold != oldValue else { return }
            let c = accelSpikeThreshold.clamped(to: 0.010...0.040)
            if c != accelSpikeThreshold { accelSpikeThreshold = c; return }
            persist(accelSpikeThreshold, .accelSpikeThreshold)
        }
    }

    var accelCrestFactor: Double {
        didSet {
            guard accelCrestFactor != oldValue else { return }
            let c = accelCrestFactor.clamped(to: 1.0...5.0)
            if c != accelCrestFactor { accelCrestFactor = c; return }
            persist(accelCrestFactor, .accelCrestFactor)
        }
    }

    var accelRiseRate: Double {
        didSet {
            guard accelRiseRate != oldValue else { return }
            let c = accelRiseRate.clamped(to: 0.005...0.020)
            if c != accelRiseRate { accelRiseRate = c; return }
            persist(accelRiseRate, .accelRiseRate)
        }
    }

    var accelConfirmations: Int {
        didSet {
            guard accelConfirmations != oldValue else { return }
            let c = max(1, min(5, accelConfirmations))
            if c != accelConfirmations { accelConfirmations = c; return }
            persist(accelConfirmations, .accelConfirmations)
        }
    }

    var accelWarmupSamples: Int {
        didSet {
            guard accelWarmupSamples != oldValue else { return }
            let c = max(10, min(100, accelWarmupSamples))
            if c != accelWarmupSamples { accelWarmupSamples = c; return }
            persist(accelWarmupSamples, .accelWarmupSamples)
        }
    }

    /// Accelerometer report interval in microseconds (5000 = 200Hz, 10000 = 100Hz, 50000 = 20Hz).
    var accelReportInterval: Double {
        didSet {
            guard accelReportInterval != oldValue else { return }
            let c = accelReportInterval.clamped(to: 5000...50000)
            if c != accelReportInterval { accelReportInterval = c; return }
            persist(accelReportInterval, .accelReportInterval)
        }
    }

    /// Number of sensors required to independently detect an impact before triggering.
    var consensusRequired: Int {
        didSet {
            guard consensusRequired != oldValue else { return }
            let c = max(1, min(10, consensusRequired))
            if c != consensusRequired { consensusRequired = c; return }
            persist(consensusRequired, .consensusRequired)
        }
    }

    // MARK: - Microphone detection

    var micSpikeThreshold: Double {
        didSet {
            guard micSpikeThreshold != oldValue else { return }
            let c = micSpikeThreshold.clamped(to: 0.005...0.100)
            if c != micSpikeThreshold { micSpikeThreshold = c; return }
            persist(micSpikeThreshold, .micSpikeThreshold)
        }
    }

    var micCrestFactor: Double {
        didSet {
            guard micCrestFactor != oldValue else { return }
            let c = micCrestFactor.clamped(to: 1.0...5.0)
            if c != micCrestFactor { micCrestFactor = c; return }
            persist(micCrestFactor, .micCrestFactor)
        }
    }

    var micRiseRate: Double {
        didSet {
            guard micRiseRate != oldValue else { return }
            let c = micRiseRate.clamped(to: 0.002...0.050)
            if c != micRiseRate { micRiseRate = c; return }
            persist(micRiseRate, .micRiseRate)
        }
    }

    var micConfirmations: Int {
        didSet {
            guard micConfirmations != oldValue else { return }
            let c = max(1, min(5, micConfirmations))
            if c != micConfirmations { micConfirmations = c; return }
            persist(micConfirmations, .micConfirmations)
        }
    }

    var micWarmupSamples: Int {
        didSet {
            guard micWarmupSamples != oldValue else { return }
            let c = max(10, min(100, micWarmupSamples))
            if c != micWarmupSamples { micWarmupSamples = c; return }
            persist(micWarmupSamples, .micWarmupSamples)
        }
    }

    // MARK: - Headphone motion detection

    var hpSpikeThreshold: Double {
        didSet {
            guard hpSpikeThreshold != oldValue else { return }
            let c = hpSpikeThreshold.clamped(to: 0.02...0.50)
            if c != hpSpikeThreshold { hpSpikeThreshold = c; return }
            persist(hpSpikeThreshold, .hpSpikeThreshold)
        }
    }

    var hpCrestFactor: Double {
        didSet {
            guard hpCrestFactor != oldValue else { return }
            let c = hpCrestFactor.clamped(to: 1.0...5.0)
            if c != hpCrestFactor { hpCrestFactor = c; return }
            persist(hpCrestFactor, .hpCrestFactor)
        }
    }

    var hpRiseRate: Double {
        didSet {
            guard hpRiseRate != oldValue else { return }
            let c = hpRiseRate.clamped(to: 0.010...0.200)
            if c != hpRiseRate { hpRiseRate = c; return }
            persist(hpRiseRate, .hpRiseRate)
        }
    }

    var hpConfirmations: Int {
        didSet {
            guard hpConfirmations != oldValue else { return }
            let c = max(1, min(5, hpConfirmations))
            if c != hpConfirmations { hpConfirmations = c; return }
            persist(hpConfirmations, .hpConfirmations)
        }
    }

    var hpWarmupSamples: Int {
        didSet {
            guard hpWarmupSamples != oldValue else { return }
            let c = max(10, min(100, hpWarmupSamples))
            if c != hpWarmupSamples { hpWarmupSamples = c; return }
            persist(hpWarmupSamples, .hpWarmupSamples)
        }
    }

    // MARK: - Init

    public init() {
        let d = UserDefaults.standard
        d.register(defaults: Self.defaults)

        sensitivityMin  = d.double(forKey: Key.sensitivityMin.rawValue)
        sensitivityMax  = d.double(forKey: Key.sensitivityMax.rawValue)
        accelBandpassLowHz   = d.double(forKey: Key.accelBandpassLowHz.rawValue)
        accelBandpassHighHz  = d.double(forKey: Key.accelBandpassHighHz.rawValue)
        debounce        = d.double(forKey: Key.debounce.rawValue)
        soundEnabled    = d.bool(forKey:   Key.soundEnabled.rawValue)
        debugLogging    = d.bool(forKey:   Key.debugLogging.rawValue)
        screenFlash     = d.bool(forKey:   Key.screenFlash.rawValue)
        flashOpacityMin = d.double(forKey: Key.flashOpacityMin.rawValue)
        flashOpacityMax = d.double(forKey: Key.flashOpacityMax.rawValue)
        volumeMin       = d.double(forKey: Key.volumeMin.rawValue)
        volumeMax       = d.double(forKey: Key.volumeMax.rawValue)
        enabledDisplays = d.array(forKey: Key.enabledDisplays.rawValue) as? [Int] ?? []
        enabledAudioDevices = d.array(forKey: Key.enabledAudioDevices.rawValue) as? [String] ?? []
        enabledSensorIDs = d.array(forKey: Key.enabledSensorIDs.rawValue) as? [String] ?? []
        consensusRequired     = d.integer(forKey: Key.consensusRequired.rawValue)
        // Accelerometer
        accelSpikeThreshold   = d.double(forKey: Key.accelSpikeThreshold.rawValue)
        accelCrestFactor      = d.double(forKey: Key.accelCrestFactor.rawValue)
        accelRiseRate         = d.double(forKey: Key.accelRiseRate.rawValue)
        accelConfirmations    = d.integer(forKey: Key.accelConfirmations.rawValue)
        accelWarmupSamples    = d.integer(forKey: Key.accelWarmupSamples.rawValue)
        accelReportInterval   = d.double(forKey: Key.accelReportInterval.rawValue)
        accelBandpassLowHz    = d.double(forKey: Key.accelBandpassLowHz.rawValue)
        accelBandpassHighHz   = d.double(forKey: Key.accelBandpassHighHz.rawValue)
        // Microphone
        micSpikeThreshold = d.double(forKey: Key.micSpikeThreshold.rawValue)
        micCrestFactor    = d.double(forKey: Key.micCrestFactor.rawValue)
        micRiseRate       = d.double(forKey: Key.micRiseRate.rawValue)
        micConfirmations  = d.integer(forKey: Key.micConfirmations.rawValue)
        micWarmupSamples  = d.integer(forKey: Key.micWarmupSamples.rawValue)
        // Headphone
        hpSpikeThreshold  = d.double(forKey: Key.hpSpikeThreshold.rawValue)
        hpCrestFactor     = d.double(forKey: Key.hpCrestFactor.rawValue)
        hpRiseRate        = d.double(forKey: Key.hpRiseRate.rawValue)
        hpConfirmations   = d.integer(forKey: Key.hpConfirmations.rawValue)
        hpWarmupSamples   = d.integer(forKey: Key.hpWarmupSamples.rawValue)
    }

    // MARK: - Reset

    /// Restores all settings to their factory default values.
    func resetToDefaults() {
        let d = Self.defaults
        sensitivityMin    = d[Key.sensitivityMin.rawValue]  as! Double
        sensitivityMax    = d[Key.sensitivityMax.rawValue]  as! Double
        accelBandpassLowHz     = d[Key.accelBandpassLowHz.rawValue]   as! Double
        accelBandpassHighHz    = d[Key.accelBandpassHighHz.rawValue]   as! Double
        debounce          = d[Key.debounce.rawValue]         as! Double
        soundEnabled      = d[Key.soundEnabled.rawValue]     as! Bool
        debugLogging      = d[Key.debugLogging.rawValue]     as! Bool
        screenFlash       = d[Key.screenFlash.rawValue]      as! Bool
        flashOpacityMin   = d[Key.flashOpacityMin.rawValue]  as! Double
        flashOpacityMax   = d[Key.flashOpacityMax.rawValue]  as! Double
        volumeMin         = d[Key.volumeMin.rawValue]        as! Double
        volumeMax         = d[Key.volumeMax.rawValue]        as! Double
        enabledDisplays   = d[Key.enabledDisplays.rawValue]  as! [Int]
        enabledAudioDevices = d[Key.enabledAudioDevices.rawValue] as! [String]
        enabledSensorIDs  = d[Key.enabledSensorIDs.rawValue] as! [String]
        consensusRequired     = d[Key.consensusRequired.rawValue]     as! Int
        accelSpikeThreshold   = d[Key.accelSpikeThreshold.rawValue]  as! Double
        accelCrestFactor      = d[Key.accelCrestFactor.rawValue]     as! Double
        accelRiseRate         = d[Key.accelRiseRate.rawValue]        as! Double
        accelConfirmations    = d[Key.accelConfirmations.rawValue]   as! Int
        accelWarmupSamples    = d[Key.accelWarmupSamples.rawValue]   as! Int
        accelReportInterval   = d[Key.accelReportInterval.rawValue]  as! Double
        accelBandpassLowHz    = d[Key.accelBandpassLowHz.rawValue]   as! Double
        accelBandpassHighHz   = d[Key.accelBandpassHighHz.rawValue]  as! Double
        micSpikeThreshold = d[Key.micSpikeThreshold.rawValue] as! Double
        micCrestFactor    = d[Key.micCrestFactor.rawValue]    as! Double
        micRiseRate       = d[Key.micRiseRate.rawValue]       as! Double
        micConfirmations  = d[Key.micConfirmations.rawValue]  as! Int
        micWarmupSamples  = d[Key.micWarmupSamples.rawValue]  as! Int
        hpSpikeThreshold  = d[Key.hpSpikeThreshold.rawValue]  as! Double
        hpCrestFactor     = d[Key.hpCrestFactor.rawValue]     as! Double
        hpRiseRate        = d[Key.hpRiseRate.rawValue]        as! Double
        hpConfirmations   = d[Key.hpConfirmations.rawValue]   as! Int
        hpWarmupSamples   = d[Key.hpWarmupSamples.rawValue]   as! Int
    }

    // MARK: - Private

    private func persist<T>(_ value: T, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
