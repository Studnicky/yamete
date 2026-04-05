import Foundation
import Observation

/// User settings persisted in `UserDefaults`.
/// Includes guard-clamp updates to avoid recursive `didSet` loops.
@MainActor @Observable
final class SettingsStore {

    // MARK: - Keys

    enum Key: String, CaseIterable, Sendable {
        case sensitivityMin, sensitivityMax
        case bandpassLowHz, bandpassHighHz
        case debounce
        case screenFlash
        case flashOpacityMin, flashOpacityMax
        case volumeMin, volumeMax
        case enabledDisplays, enabledAudioDevices, autoCheckForUpdates, lastUpdateCheck
        // Advanced detection
        case spikeThreshold, crestFactor, riseRate, confirmations, warmupSamples
    }

    // MARK: - Defaults

    static let defaults: [String: Any] = [
        Key.sensitivityMin.rawValue:  0.10,
        Key.sensitivityMax.rawValue:  0.90,
        Key.bandpassLowHz.rawValue:   20.0,
        Key.bandpassHighHz.rawValue:  25.0,
        Key.debounce.rawValue:        0.5,
        Key.screenFlash.rawValue:     true,
        Key.flashOpacityMin.rawValue: 0.50,
        Key.flashOpacityMax.rawValue: 0.9,
        Key.volumeMin.rawValue:       0.50,
        Key.volumeMax.rawValue:       0.9,
        Key.enabledDisplays.rawValue: [Int](),
        Key.enabledAudioDevices.rawValue: [String](),
        Key.autoCheckForUpdates.rawValue: true,
        Key.lastUpdateCheck.rawValue: 0.0,
        // Advanced detection
        Key.spikeThreshold.rawValue:  0.020,
        Key.crestFactor.rawValue:     6.0,
        Key.riseRate.rawValue:        0.010,
        Key.confirmations.rawValue:   3,
        Key.warmupSamples.rawValue:   50,
    ]

    // MARK: - Sensitivity band (input window)

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
    var bandpassLowHz: Double {
        didSet {
            guard bandpassLowHz != oldValue else { return }
            let c = bandpassLowHz.clamped(to: 10...25)
            if c != bandpassLowHz { bandpassLowHz = c; return }
            persist(bandpassLowHz, .bandpassLowHz)
            if bandpassLowHz > bandpassHighHz { bandpassHighHz = bandpassLowHz }
        }
    }

    /// Low-pass cutoff: vibrations above this frequency are rejected (electronic noise, rattling).
    var bandpassHighHz: Double {
        didSet {
            guard bandpassHighHz != oldValue else { return }
            let c = bandpassHighHz.clamped(to: 10...25)
            if c != bandpassHighHz { bandpassHighHz = c; return }
            persist(bandpassHighHz, .bandpassHighHz)
            if bandpassHighHz < bandpassLowHz { bandpassLowHz = bandpassHighHz }
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

    // MARK: - Screen flash toggle

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

    // MARK: - Update settings

    var autoCheckForUpdates: Bool {
        didSet {
            guard autoCheckForUpdates != oldValue else { return }
            persist(autoCheckForUpdates, .autoCheckForUpdates)
        }
    }

    /// TimeInterval of last update check (for daily throttling).
    var lastUpdateCheck: Double {
        didSet {
            guard lastUpdateCheck != oldValue else { return }
            persist(lastUpdateCheck, .lastUpdateCheck)
        }
    }

    // MARK: - Display + audio device selection

    /// CGDirectDisplayID values of enabled displays. Empty = all displays.
    var enabledDisplays: [Int] {
        didSet {
            guard enabledDisplays != oldValue else { return }
            persist(enabledDisplays, .enabledDisplays)
        }
    }

    /// Core Audio device UIDs for audio output. Empty = system default only.
    var enabledAudioDevices: [String] {
        didSet {
            guard enabledAudioDevices != oldValue else { return }
            persist(enabledAudioDevices, .enabledAudioDevices)
        }
    }

    // MARK: - Advanced detection

    var spikeThreshold: Double {
        didSet {
            guard spikeThreshold != oldValue else { return }
            let c = spikeThreshold.clamped(to: 0.010...0.040)
            if c != spikeThreshold { spikeThreshold = c; return }
            persist(spikeThreshold, .spikeThreshold)
        }
    }

    var crestFactor: Double {
        didSet {
            guard crestFactor != oldValue else { return }
            let c = crestFactor.clamped(to: 2.0...10.0)
            if c != crestFactor { crestFactor = c; return }
            persist(crestFactor, .crestFactor)
        }
    }

    var riseRate: Double {
        didSet {
            guard riseRate != oldValue else { return }
            let c = riseRate.clamped(to: 0.005...0.020)
            if c != riseRate { riseRate = c; return }
            persist(riseRate, .riseRate)
        }
    }

    var confirmations: Int {
        didSet {
            guard confirmations != oldValue else { return }
            let c = max(1, min(5, confirmations))
            if c != confirmations { confirmations = c; return }
            persist(confirmations, .confirmations)
        }
    }

    var warmupSamples: Int {
        didSet {
            guard warmupSamples != oldValue else { return }
            let c = max(10, min(100, warmupSamples))
            if c != warmupSamples { warmupSamples = c; return }
            persist(warmupSamples, .warmupSamples)
        }
    }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        d.register(defaults: Self.defaults)

        sensitivityMin  = d.double(forKey: Key.sensitivityMin.rawValue)
        sensitivityMax  = d.double(forKey: Key.sensitivityMax.rawValue)
        bandpassLowHz   = d.double(forKey: Key.bandpassLowHz.rawValue)
        bandpassHighHz  = d.double(forKey: Key.bandpassHighHz.rawValue)
        debounce        = d.double(forKey: Key.debounce.rawValue)
        screenFlash     = d.bool(forKey:   Key.screenFlash.rawValue)
        flashOpacityMin = d.double(forKey: Key.flashOpacityMin.rawValue)
        flashOpacityMax = d.double(forKey: Key.flashOpacityMax.rawValue)
        volumeMin       = d.double(forKey: Key.volumeMin.rawValue)
        volumeMax       = d.double(forKey: Key.volumeMax.rawValue)
        enabledDisplays = d.array(forKey: Key.enabledDisplays.rawValue) as? [Int] ?? []
        enabledAudioDevices = d.array(forKey: Key.enabledAudioDevices.rawValue) as? [String] ?? []
        autoCheckForUpdates = d.bool(forKey: Key.autoCheckForUpdates.rawValue)
        lastUpdateCheck = d.double(forKey: Key.lastUpdateCheck.rawValue)
        // Advanced
        spikeThreshold  = d.double(forKey: Key.spikeThreshold.rawValue)
        crestFactor     = d.double(forKey: Key.crestFactor.rawValue)
        riseRate        = d.double(forKey: Key.riseRate.rawValue)
        confirmations   = d.integer(forKey: Key.confirmations.rawValue)
        warmupSamples   = d.integer(forKey: Key.warmupSamples.rawValue)
    }

    // MARK: - Private

    private func persist<T>(_ value: T, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
