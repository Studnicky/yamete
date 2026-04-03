import Foundation
import Observation

/// User-configurable settings, persisted to UserDefaults.
///
/// All output parameters (volume, opacity, debounce) are range-based sliding
/// windows driven by the normalized intensity from the sensitivity band:
///
///   raw force → [sensitivity] → intensity 0–1 → [volume]    → audio level
///                                              → [opacity]   → flash brightness
///                                              → [debounce]  → cooldown time
///
/// `@Observable` re-invokes setters on self-assignment in `didSet`, so clamping
/// uses a guard-clamp-return pattern to prevent infinite recursion.
@MainActor @Observable
final class SettingsStore {

    // MARK: - Keys

    enum Key: String, CaseIterable, Sendable {
        case sensitivityMin, sensitivityMax
        case debounce
        case screenFlash
        case flashOpacityMin, flashOpacityMax
        case volumeMin, volumeMax
        case enabledDisplays, enabledAudioDevices, autoCheckForUpdates, lastUpdateCheck
    }

    // MARK: - Defaults

    static let defaults: [String: Any] = [
        Key.sensitivityMin.rawValue:  0.10,
        Key.sensitivityMax.rawValue:  0.90,
        Key.debounce.rawValue:        0.3,
        Key.screenFlash.rawValue:     true,
        Key.flashOpacityMin.rawValue: 0.50,
        Key.flashOpacityMax.rawValue: 0.9,
        Key.volumeMin.rawValue:       0.50,
        Key.volumeMax.rawValue:       0.9,
        Key.enabledDisplays.rawValue: [Int](),
        Key.enabledAudioDevices.rawValue: [String](),
        Key.autoCheckForUpdates.rawValue: true,
        Key.lastUpdateCheck.rawValue: 0.0,
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

    // MARK: - Debounce

    var debounce: Double {
        didSet {
            guard debounce != oldValue else { return }
            let c = debounce.clamped(to: 0...3)
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

    // MARK: - Init

    init() {
        UserDefaults.standard.register(defaults: Self.defaults)
        let d = UserDefaults.standard
        sensitivityMin  = d.double(forKey: Key.sensitivityMin.rawValue)
        sensitivityMax  = d.double(forKey: Key.sensitivityMax.rawValue)
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

        migrateOldKeys()
    }

    // MARK: - Migration

    /// One-time migration of orphaned keys from earlier versions.
    private func migrateOldKeys() {
        let d = UserDefaults.standard

        // v0: "sensitivity" (single Double) → sensitivityMin/Max
        if d.object(forKey: "sensitivity") != nil && d.object(forKey: Key.sensitivityMin.rawValue) == nil {
            let old = d.double(forKey: "sensitivity")
            sensitivityMin = max(0, old - 0.3)
            sensitivityMax = min(1, old + 0.3)
            d.removeObject(forKey: "sensitivity")
        }

        // v0: "isEnabled" (Bool) → removed (use isEnabled on controller)
        d.removeObject(forKey: "isEnabled")

        // v0: "audioDeviceUID" (String) → enabledAudioDevices ([String])
        if let old = d.string(forKey: "audioDeviceUID"), !old.isEmpty {
            if enabledAudioDevices.isEmpty {
                enabledAudioDevices = [old]
            }
            d.removeObject(forKey: "audioDeviceUID")
        }

        // v0: "debounceMin"/"debounceMax" → debounce (single)
        if d.object(forKey: "debounceMin") != nil {
            let lo = d.double(forKey: "debounceMin")
            let hi = d.double(forKey: "debounceMax")
            debounce = (lo + hi) / 2.0
            d.removeObject(forKey: "debounceMin")
            d.removeObject(forKey: "debounceMax")
        }
    }

    // MARK: - Private

    private func persist<T>(_ value: T, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
