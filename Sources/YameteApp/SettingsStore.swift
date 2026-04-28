#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
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
        case visualResponseMode
        case notificationLocale
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
        // LED flash output (Caps Lock LED PWM dither)
        case ledEnabled, ledBrightnessMin, ledBrightnessMax, keyboardBrightnessEnabled
        // Cable / power / device event sources
        case enabledStimulusSourceIDs = "enabledEventSourceIDs"
        // Per-output × per-reaction toggle matrix (JSON-encoded Data)
        case soundReactionMatrix, flashReactionMatrix, notificationReactionMatrix, ledReactionMatrix
        // Independent output master toggles (replaces 3-way visualResponseMode gate)
        case flashEnabled
        case flashActiveDisplayOnly
        case notificationsEnabled
        // Haptic output
        case hapticEnabled, hapticIntensity
        // Display brightness output
        case displayBrightnessEnabled, displayBrightnessBoost, displayBrightnessThreshold
        // Display tint output
        case displayTintEnabled, displayTintIntensity
        // Volume spike output
        case volumeSpikeEnabled, volumeSpikeTarget, volumeSpikeThreshold
        // Trackpad source
        case trackpadWindowDuration
        case trackpadScrollMin, trackpadScrollMax  // legacy shared scroll thresholds (kept for back-compat)
        case trackpadTouchingMin, trackpadTouchingMax
        case trackpadSlidingMin, trackpadSlidingMax
        case trackpadContactMin, trackpadContactMax
        case trackpadTapMin, trackpadTapMax
        case trackpadTouchingEnabled, trackpadSlidingEnabled
        case trackpadContactEnabled, trackpadTappingEnabled, trackpadCirclingEnabled
        // Mouse source
        case mouseScrollThreshold
        // First-launch drama flag
        case firstLaunchDramaFired
        // Per-output reaction matrices for new outputs
        case hapticReactionMatrix, displayBrightnessReactionMatrix, displayTintReactionMatrix, volumeSpikeReactionMatrix
    }

    // MARK: - Defaults

    static let defaults: [String: Any] = [
        Key.sensitivityMin.rawValue:  Defaults.sensitivityMin,
        Key.sensitivityMax.rawValue:  Defaults.sensitivityMax,
        Key.debounce.rawValue:        Defaults.debounce,
        Key.soundEnabled.rawValue:    true,
        Key.debugLogging.rawValue:    false,
        Key.visualResponseMode.rawValue: Defaults.visualResponseMode.rawValue,
        Key.notificationLocale.rawValue: "",
        Key.flashOpacityMin.rawValue: Defaults.flashOpacityMin,
        Key.flashOpacityMax.rawValue: Defaults.flashOpacityMax,
        Key.volumeMin.rawValue:       Defaults.volumeMin,
        Key.volumeMax.rawValue:       Defaults.volumeMax,
        Key.enabledDisplays.rawValue: [Int](),
        Key.enabledAudioDevices.rawValue: [String](),
        Key.enabledSensorIDs.rawValue: [String](),
        Key.consensusRequired.rawValue: Defaults.consensus,
        // Accelerometer detection
        Key.accelSpikeThreshold.rawValue:  Defaults.accelSpikeThreshold,
        Key.accelCrestFactor.rawValue:     Defaults.accelCrestFactor,
        Key.accelRiseRate.rawValue:        Defaults.accelRiseRate,
        Key.accelConfirmations.rawValue:   Defaults.accelConfirmations,
        Key.accelWarmupSamples.rawValue:   Defaults.accelWarmup,
        Key.accelReportInterval.rawValue:  Defaults.accelReportInterval,
        Key.accelBandpassLowHz.rawValue:   Defaults.accelBandpassLow,
        Key.accelBandpassHighHz.rawValue:  Defaults.accelBandpassHigh,
        // Microphone detection
        Key.micSpikeThreshold.rawValue: Defaults.micSpikeThreshold,
        Key.micCrestFactor.rawValue:    Defaults.micCrestFactor,
        Key.micRiseRate.rawValue:       Defaults.micRiseRate,
        Key.micConfirmations.rawValue:  Defaults.micConfirmations,
        Key.micWarmupSamples.rawValue:  Defaults.micWarmup,
        // Headphone motion detection
        Key.hpSpikeThreshold.rawValue:  Defaults.hpSpikeThreshold,
        Key.hpCrestFactor.rawValue:     Defaults.hpCrestFactor,
        Key.hpRiseRate.rawValue:        Defaults.hpRiseRate,
        Key.hpConfirmations.rawValue:   Defaults.hpConfirmations,
        Key.hpWarmupSamples.rawValue:   Defaults.hpWarmup,
        // LED flash defaults
        Key.ledEnabled.rawValue:           false,
        Key.ledBrightnessMin.rawValue:     0.30,
        Key.ledBrightnessMax.rawValue:     1.00,
        Key.keyboardBrightnessEnabled.rawValue: false,
        // Event sources default on across the board
        Key.enabledStimulusSourceIDs.rawValue: StimulusSourceDefaults.allStimulusSourceIDs,
        // Per-output toggle matrices empty → defaults to "enabled"
        Key.soundReactionMatrix.rawValue:        Data(),
        Key.flashReactionMatrix.rawValue:        Data(),
        Key.notificationReactionMatrix.rawValue: Data(),
        Key.ledReactionMatrix.rawValue:          Data(),
        // Independent output toggles — flash on by default, notifications opt-in
        Key.flashEnabled.rawValue:              true,
        Key.flashActiveDisplayOnly.rawValue:    false,
        Key.notificationsEnabled.rawValue:      false,
        // Haptic output
        Key.hapticEnabled.rawValue:                false,
        Key.hapticIntensity.rawValue:              1.0,
        // Display brightness output
        Key.displayBrightnessEnabled.rawValue:     false,
        Key.displayBrightnessBoost.rawValue:       0.5,
        Key.displayBrightnessThreshold.rawValue:   0.4,
        // Display tint output
        Key.displayTintEnabled.rawValue:           false,
        Key.displayTintIntensity.rawValue:         0.5,
        // Volume spike output
        Key.volumeSpikeEnabled.rawValue:           false,
        Key.volumeSpikeTarget.rawValue:            0.9,
        Key.volumeSpikeThreshold.rawValue:         0.7,
        // Trackpad source
        Key.trackpadWindowDuration.rawValue:  1.5,
        Key.trackpadScrollMin.rawValue:       0.1,
        Key.trackpadScrollMax.rawValue:       0.8,
        Key.trackpadTouchingMin.rawValue:     0.1,
        Key.trackpadTouchingMax.rawValue:     0.5,
        Key.trackpadSlidingMin.rawValue:      0.5,
        Key.trackpadSlidingMax.rawValue:      0.9,
        Key.trackpadContactMin.rawValue:      0.5,
        Key.trackpadContactMax.rawValue:      2.5,
        Key.trackpadTapMin.rawValue:          2.0,
        Key.trackpadTapMax.rawValue:          6.0,
        Key.trackpadTouchingEnabled.rawValue: true,
        Key.trackpadSlidingEnabled.rawValue:  true,
        Key.trackpadContactEnabled.rawValue:  true,
        Key.trackpadTappingEnabled.rawValue:  true,
        Key.trackpadCirclingEnabled.rawValue: true,
        Key.mouseScrollThreshold.rawValue:    3.0,
        // First-launch drama flag
        Key.firstLaunchDramaFired.rawValue:        false,
        // New output reaction matrices empty → defaults to "enabled"
        Key.hapticReactionMatrix.rawValue:               Data(),
        Key.displayBrightnessReactionMatrix.rawValue:    Data(),
        Key.displayTintReactionMatrix.rawValue:          Data(),
        Key.volumeSpikeReactionMatrix.rawValue:          Data(),
    ]

    // MARK: - Reactivity (inverted sensitivity: higher value = lower force threshold)

    var sensitivityMin: Double {
        didSet {
            guard sensitivityMin != oldValue else { return }
            let c = sensitivityMin.clamped(to: Detection.unitRange)
            if c != sensitivityMin { sensitivityMin = c; return }
            persist(sensitivityMin, .sensitivityMin)
            if sensitivityMin > sensitivityMax { sensitivityMax = sensitivityMin }
        }
    }

    var sensitivityMax: Double {
        didSet {
            guard sensitivityMax != oldValue else { return }
            let c = sensitivityMax.clamped(to: Detection.unitRange)
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
            let c = accelBandpassLowHz.clamped(to: Detection.Accel.bandpassRange)
            if c != accelBandpassLowHz { accelBandpassLowHz = c; return }
            persist(accelBandpassLowHz, .accelBandpassLowHz)
            if accelBandpassLowHz > accelBandpassHighHz { accelBandpassHighHz = accelBandpassLowHz }
        }
    }

    /// Low-pass cutoff: vibrations above this frequency are rejected (electronic noise, rattling).
    var accelBandpassHighHz: Double {
        didSet {
            guard accelBandpassHighHz != oldValue else { return }
            let c = accelBandpassHighHz.clamped(to: Detection.Accel.bandpassRange)
            if c != accelBandpassHighHz { accelBandpassHighHz = c; return }
            persist(accelBandpassHighHz, .accelBandpassHighHz)
            if accelBandpassHighHz < accelBandpassLowHz { accelBandpassLowHz = accelBandpassHighHz }
        }
    }

    // MARK: - Debounce

    var debounce: Double {
        didSet {
            guard debounce != oldValue else { return }
            let c = debounce.clamped(to: Detection.debounceRange)
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
            if !AppLog.supportsDebugLogging && debugLogging {
                debugLogging = false
                return
            }
            guard debugLogging != oldValue else { return }
            persist(debugLogging, .debugLogging)
        }
    }

    /// Computed proxy: true iff the user wants any visual response.
    /// Backed entirely by `visualResponseMode` — no separate storage. Exists
    /// so existing call sites (and tests) can keep reading/writing a Bool.
    var screenFlash: Bool {
        get { visualResponseMode != .off }
        set {
            if newValue {
                if visualResponseMode == .off { visualResponseMode = .overlay }
            } else {
                visualResponseMode = .off
            }
        }
    }

    var visualResponseMode: VisualResponseMode {
        didSet {
            guard visualResponseMode != oldValue else { return }
            persist(visualResponseMode.rawValue, .visualResponseMode)
        }
    }

    /// Locale identifier used for notification body strings (e.g. "en", "ja", "es").
    /// Empty string means "follow system language" — resolved at read time via
    /// `Bundle.main.preferredLocalizations.first`.
    var notificationLocale: String {
        didSet {
            guard notificationLocale != oldValue else { return }
            persist(notificationLocale, .notificationLocale)
        }
    }

    /// Resolved locale identifier: honors the user's override, or falls back to
    /// the system's preferred language (whichever available lproj matches best).
    var resolvedNotificationLocale: String {
        if !notificationLocale.isEmpty { return notificationLocale }
        return Bundle.main.preferredLocalizations.first ?? "en"
    }

    // MARK: - Flash opacity band (intensity → flash brightness)

    var flashOpacityMin: Double {
        didSet {
            guard flashOpacityMin != oldValue else { return }
            let c = flashOpacityMin.clamped(to: Detection.unitRange)
            if c != flashOpacityMin { flashOpacityMin = c; return }
            persist(flashOpacityMin, .flashOpacityMin)
            if flashOpacityMin > flashOpacityMax { flashOpacityMax = flashOpacityMin }
        }
    }

    var flashOpacityMax: Double {
        didSet {
            guard flashOpacityMax != oldValue else { return }
            let c = flashOpacityMax.clamped(to: Detection.unitRange)
            if c != flashOpacityMax { flashOpacityMax = c; return }
            persist(flashOpacityMax, .flashOpacityMax)
            if flashOpacityMax < flashOpacityMin { flashOpacityMin = flashOpacityMax }
        }
    }

    // MARK: - Volume band (intensity → audio level)

    var volumeMin: Double {
        didSet {
            guard volumeMin != oldValue else { return }
            let c = volumeMin.clamped(to: Detection.unitRange)
            if c != volumeMin { volumeMin = c; return }
            persist(volumeMin, .volumeMin)
            if volumeMin > volumeMax { volumeMax = volumeMin }
        }
    }

    var volumeMax: Double {
        didSet {
            guard volumeMax != oldValue else { return }
            let c = volumeMax.clamped(to: Detection.unitRange)
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

    /// SensorSource IDs to enable. Empty = all available sources.
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
            let c = accelSpikeThreshold.clamped(to: Detection.Accel.spikeThresholdRange)
            if c != accelSpikeThreshold { accelSpikeThreshold = c; return }
            persist(accelSpikeThreshold, .accelSpikeThreshold)
        }
    }

    var accelCrestFactor: Double {
        didSet {
            guard accelCrestFactor != oldValue else { return }
            let c = accelCrestFactor.clamped(to: Detection.Accel.crestFactorRange)
            if c != accelCrestFactor { accelCrestFactor = c; return }
            persist(accelCrestFactor, .accelCrestFactor)
        }
    }

    var accelRiseRate: Double {
        didSet {
            guard accelRiseRate != oldValue else { return }
            let c = accelRiseRate.clamped(to: Detection.Accel.riseRateRange)
            if c != accelRiseRate { accelRiseRate = c; return }
            persist(accelRiseRate, .accelRiseRate)
        }
    }

    var accelConfirmations: Int {
        didSet {
            guard accelConfirmations != oldValue else { return }
            let c = accelConfirmations.clamped(to: Detection.Accel.confirmationsRange)
            if c != accelConfirmations { accelConfirmations = c; return }
            persist(accelConfirmations, .accelConfirmations)
        }
    }

    var accelWarmupSamples: Int {
        didSet {
            guard accelWarmupSamples != oldValue else { return }
            let c = accelWarmupSamples.clamped(to: Detection.Accel.warmupRange)
            if c != accelWarmupSamples { accelWarmupSamples = c; return }
            persist(accelWarmupSamples, .accelWarmupSamples)
        }
    }

    /// Accelerometer report interval in microseconds (5000 = 200Hz, 10000 = 100Hz, 50000 = 20Hz).
    var accelReportInterval: Double {
        didSet {
            guard accelReportInterval != oldValue else { return }
            let c = accelReportInterval.clamped(to: Detection.Accel.reportIntervalRange)
            if c != accelReportInterval { accelReportInterval = c; return }
            persist(accelReportInterval, .accelReportInterval)
        }
    }

    /// Number of sensors required to independently detect an impact before triggering.
    var consensusRequired: Int {
        didSet {
            guard consensusRequired != oldValue else { return }
            let c = consensusRequired.clamped(to: Detection.consensusRange)
            if c != consensusRequired { consensusRequired = c; return }
            persist(consensusRequired, .consensusRequired)
        }
    }

    // MARK: - Microphone detection

    var micSpikeThreshold: Double {
        didSet {
            guard micSpikeThreshold != oldValue else { return }
            let c = micSpikeThreshold.clamped(to: Detection.Mic.spikeThresholdRange)
            if c != micSpikeThreshold { micSpikeThreshold = c; return }
            persist(micSpikeThreshold, .micSpikeThreshold)
        }
    }

    var micCrestFactor: Double {
        didSet {
            guard micCrestFactor != oldValue else { return }
            let c = micCrestFactor.clamped(to: Detection.Mic.crestFactorRange)
            if c != micCrestFactor { micCrestFactor = c; return }
            persist(micCrestFactor, .micCrestFactor)
        }
    }

    var micRiseRate: Double {
        didSet {
            guard micRiseRate != oldValue else { return }
            let c = micRiseRate.clamped(to: Detection.Mic.riseRateRange)
            if c != micRiseRate { micRiseRate = c; return }
            persist(micRiseRate, .micRiseRate)
        }
    }

    var micConfirmations: Int {
        didSet {
            guard micConfirmations != oldValue else { return }
            let c = micConfirmations.clamped(to: Detection.Mic.confirmationsRange)
            if c != micConfirmations { micConfirmations = c; return }
            persist(micConfirmations, .micConfirmations)
        }
    }

    var micWarmupSamples: Int {
        didSet {
            guard micWarmupSamples != oldValue else { return }
            let c = micWarmupSamples.clamped(to: Detection.Mic.warmupRange)
            if c != micWarmupSamples { micWarmupSamples = c; return }
            persist(micWarmupSamples, .micWarmupSamples)
        }
    }

    // MARK: - Headphone motion detection

    var hpSpikeThreshold: Double {
        didSet {
            guard hpSpikeThreshold != oldValue else { return }
            let c = hpSpikeThreshold.clamped(to: Detection.Headphone.spikeThresholdRange)
            if c != hpSpikeThreshold { hpSpikeThreshold = c; return }
            persist(hpSpikeThreshold, .hpSpikeThreshold)
        }
    }

    var hpCrestFactor: Double {
        didSet {
            guard hpCrestFactor != oldValue else { return }
            let c = hpCrestFactor.clamped(to: Detection.Headphone.crestFactorRange)
            if c != hpCrestFactor { hpCrestFactor = c; return }
            persist(hpCrestFactor, .hpCrestFactor)
        }
    }

    var hpRiseRate: Double {
        didSet {
            guard hpRiseRate != oldValue else { return }
            let c = hpRiseRate.clamped(to: Detection.Headphone.riseRateRange)
            if c != hpRiseRate { hpRiseRate = c; return }
            persist(hpRiseRate, .hpRiseRate)
        }
    }

    var hpConfirmations: Int {
        didSet {
            guard hpConfirmations != oldValue else { return }
            let c = hpConfirmations.clamped(to: Detection.Headphone.confirmationsRange)
            if c != hpConfirmations { hpConfirmations = c; return }
            persist(hpConfirmations, .hpConfirmations)
        }
    }

    var hpWarmupSamples: Int {
        didSet {
            guard hpWarmupSamples != oldValue else { return }
            let c = hpWarmupSamples.clamped(to: Detection.Headphone.warmupRange)
            if c != hpWarmupSamples { hpWarmupSamples = c; return }
            persist(hpWarmupSamples, .hpWarmupSamples)
        }
    }

    // MARK: - LED flash output

    public var ledEnabled: Bool {
        didSet {
            guard ledEnabled != oldValue else { return }
            persist(ledEnabled, .ledEnabled)
        }
    }

    public var ledBrightnessMin: Double {
        didSet {
            guard ledBrightnessMin != oldValue else { return }
            let c = ledBrightnessMin.clamped(to: 0.0...1.0)
            if c != ledBrightnessMin { ledBrightnessMin = c; return }
            persist(ledBrightnessMin, .ledBrightnessMin)
            if ledBrightnessMin > ledBrightnessMax { ledBrightnessMax = ledBrightnessMin }
        }
    }

    public var ledBrightnessMax: Double {
        didSet {
            guard ledBrightnessMax != oldValue else { return }
            let c = ledBrightnessMax.clamped(to: 0.0...1.0)
            if c != ledBrightnessMax { ledBrightnessMax = c; return }
            persist(ledBrightnessMax, .ledBrightnessMax)
            if ledBrightnessMax < ledBrightnessMin { ledBrightnessMin = ledBrightnessMax }
        }
    }

    public var keyboardBrightnessEnabled: Bool {
        didSet {
            guard keyboardBrightnessEnabled != oldValue else { return }
            persist(keyboardBrightnessEnabled, .keyboardBrightnessEnabled)
        }
    }

    // MARK: - Independent output master toggles

    /// Flash overlay independent of the notification toggle.
    public var flashEnabled: Bool {
        didSet {
            guard flashEnabled != oldValue else { return }
            persist(flashEnabled, .flashEnabled)
            // Keep visualResponseMode in sync for legacy code paths / tests.
            if flashEnabled && visualResponseMode == .off { visualResponseMode = .overlay }
            if !flashEnabled && visualResponseMode == .overlay { visualResponseMode = .off }
        }
    }

    /// When true, flash fires only on NSScreen.main (key-focus screen) at impact time,
    /// ignoring the enabled-display list.
    public var flashActiveDisplayOnly: Bool {
        didSet {
            guard flashActiveDisplayOnly != oldValue else { return }
            persist(flashActiveDisplayOnly, .flashActiveDisplayOnly)
        }
    }

    public var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            persist(notificationsEnabled, .notificationsEnabled)
            if notificationsEnabled { NotificationResponder.requestAuthorizationIfNeeded() }
        }
    }

    // MARK: - Event sources

    /// Event-source SensorIDs to enable. Empty array means "use defaults".
    public var enabledStimulusSourceIDs: [String] {
        didSet {
            guard enabledStimulusSourceIDs != oldValue else { return }
            persist(enabledStimulusSourceIDs, .enabledStimulusSourceIDs)
        }
    }

    // MARK: - Per-output × per-reaction toggle matrices

    public var soundReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard soundReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(soundReactionMatrix), .soundReactionMatrix)
        }
    }

    public var flashReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard flashReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(flashReactionMatrix), .flashReactionMatrix)
        }
    }

    public var notificationReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard notificationReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(notificationReactionMatrix), .notificationReactionMatrix)
        }
    }

    public var ledReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard ledReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(ledReactionMatrix), .ledReactionMatrix)
        }
    }

    public var hapticReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard hapticReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(hapticReactionMatrix), .hapticReactionMatrix)
        }
    }

    public var displayBrightnessReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard displayBrightnessReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(displayBrightnessReactionMatrix), .displayBrightnessReactionMatrix)
        }
    }

    public var displayTintReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard displayTintReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(displayTintReactionMatrix), .displayTintReactionMatrix)
        }
    }

    public var volumeSpikeReactionMatrix: ReactionToggleMatrix {
        didSet {
            guard volumeSpikeReactionMatrix != oldValue else { return }
            persist(ReactionToggleMatrix.encoded(volumeSpikeReactionMatrix), .volumeSpikeReactionMatrix)
        }
    }

    // MARK: - New output properties

    public var hapticEnabled: Bool {
        didSet {
            guard hapticEnabled != oldValue else { return }
            persist(hapticEnabled, .hapticEnabled)
        }
    }

    public var hapticIntensity: Double {
        didSet {
            guard hapticIntensity != oldValue else { return }
            let c = hapticIntensity.clamped(to: 0.5...3.0)
            if c != hapticIntensity { hapticIntensity = c; return }
            persist(hapticIntensity, .hapticIntensity)
        }
    }

    public var displayBrightnessEnabled: Bool {
        didSet {
            guard displayBrightnessEnabled != oldValue else { return }
            persist(displayBrightnessEnabled, .displayBrightnessEnabled)
        }
    }

    public var displayBrightnessBoost: Double {
        didSet {
            guard displayBrightnessBoost != oldValue else { return }
            let c = displayBrightnessBoost.clamped(to: 0.1...1.0)
            if c != displayBrightnessBoost { displayBrightnessBoost = c; return }
            persist(displayBrightnessBoost, .displayBrightnessBoost)
        }
    }

    public var displayBrightnessThreshold: Double {
        didSet {
            guard displayBrightnessThreshold != oldValue else { return }
            let c = displayBrightnessThreshold.clamped(to: 0.0...1.0)
            if c != displayBrightnessThreshold { displayBrightnessThreshold = c; return }
            persist(displayBrightnessThreshold, .displayBrightnessThreshold)
        }
    }

    public var displayTintEnabled: Bool {
        didSet {
            guard displayTintEnabled != oldValue else { return }
            persist(displayTintEnabled, .displayTintEnabled)
        }
    }

    public var displayTintIntensity: Double {
        didSet {
            guard displayTintIntensity != oldValue else { return }
            let c = displayTintIntensity.clamped(to: 0.0...1.0)
            if c != displayTintIntensity { displayTintIntensity = c; return }
            persist(displayTintIntensity, .displayTintIntensity)
        }
    }

    public var volumeSpikeEnabled: Bool {
        didSet {
            guard volumeSpikeEnabled != oldValue else { return }
            persist(volumeSpikeEnabled, .volumeSpikeEnabled)
        }
    }

    public var volumeSpikeTarget: Double {
        didSet {
            guard volumeSpikeTarget != oldValue else { return }
            let c = volumeSpikeTarget.clamped(to: 0.5...1.0)
            if c != volumeSpikeTarget { volumeSpikeTarget = c; return }
            persist(volumeSpikeTarget, .volumeSpikeTarget)
        }
    }

    public var volumeSpikeThreshold: Double {
        didSet {
            guard volumeSpikeThreshold != oldValue else { return }
            let c = volumeSpikeThreshold.clamped(to: 0.0...1.0)
            if c != volumeSpikeThreshold { volumeSpikeThreshold = c; return }
            persist(volumeSpikeThreshold, .volumeSpikeThreshold)
        }
    }

    public var trackpadWindowDuration: Double {
        didSet {
            guard trackpadWindowDuration != oldValue else { return }
            let c = trackpadWindowDuration.clamped(to: 0.5...5.0)
            if c != trackpadWindowDuration { trackpadWindowDuration = c; return }
            persist(trackpadWindowDuration, .trackpadWindowDuration)
        }
    }
    public var trackpadScrollMin: Double {
        didSet {
            guard trackpadScrollMin != oldValue else { return }
            let c = trackpadScrollMin.clamped(to: 0.0...1.0)
            if c != trackpadScrollMin { trackpadScrollMin = c; return }
            persist(trackpadScrollMin, .trackpadScrollMin)
            if trackpadScrollMin > trackpadScrollMax { trackpadScrollMax = trackpadScrollMin }
        }
    }
    public var trackpadScrollMax: Double {
        didSet {
            guard trackpadScrollMax != oldValue else { return }
            let c = trackpadScrollMax.clamped(to: 0.0...1.0)
            if c != trackpadScrollMax { trackpadScrollMax = c; return }
            persist(trackpadScrollMax, .trackpadScrollMax)
        }
    }
    public var trackpadTouchingMin: Double {
        didSet {
            guard trackpadTouchingMin != oldValue else { return }
            let c = trackpadTouchingMin.clamped(to: 0.0...1.0)
            if c != trackpadTouchingMin { trackpadTouchingMin = c; return }
            persist(trackpadTouchingMin, .trackpadTouchingMin)
            if trackpadTouchingMin > trackpadTouchingMax { trackpadTouchingMax = trackpadTouchingMin }
        }
    }
    public var trackpadTouchingMax: Double {
        didSet {
            guard trackpadTouchingMax != oldValue else { return }
            let c = trackpadTouchingMax.clamped(to: 0.0...1.0)
            if c != trackpadTouchingMax { trackpadTouchingMax = c; return }
            persist(trackpadTouchingMax, .trackpadTouchingMax)
            if trackpadTouchingMax < trackpadTouchingMin { trackpadTouchingMin = trackpadTouchingMax }
        }
    }
    public var trackpadSlidingMin: Double {
        didSet {
            guard trackpadSlidingMin != oldValue else { return }
            let c = trackpadSlidingMin.clamped(to: 0.0...1.0)
            if c != trackpadSlidingMin { trackpadSlidingMin = c; return }
            persist(trackpadSlidingMin, .trackpadSlidingMin)
            if trackpadSlidingMin > trackpadSlidingMax { trackpadSlidingMax = trackpadSlidingMin }
        }
    }
    public var trackpadSlidingMax: Double {
        didSet {
            guard trackpadSlidingMax != oldValue else { return }
            let c = trackpadSlidingMax.clamped(to: 0.0...1.0)
            if c != trackpadSlidingMax { trackpadSlidingMax = c; return }
            persist(trackpadSlidingMax, .trackpadSlidingMax)
            if trackpadSlidingMax < trackpadSlidingMin { trackpadSlidingMin = trackpadSlidingMax }
        }
    }
    public var trackpadContactMin: Double {
        didSet {
            guard trackpadContactMin != oldValue else { return }
            let c = trackpadContactMin.clamped(to: 0.1...5.0)
            if c != trackpadContactMin { trackpadContactMin = c; return }
            persist(trackpadContactMin, .trackpadContactMin)
            if trackpadContactMin > trackpadContactMax { trackpadContactMax = trackpadContactMin }
        }
    }
    public var trackpadContactMax: Double {
        didSet {
            guard trackpadContactMax != oldValue else { return }
            let c = trackpadContactMax.clamped(to: 0.5...10.0)
            if c != trackpadContactMax { trackpadContactMax = c; return }
            persist(trackpadContactMax, .trackpadContactMax)
        }
    }
    public var trackpadTapMin: Double {
        didSet {
            guard trackpadTapMin != oldValue else { return }
            let c = trackpadTapMin.clamped(to: 0.5...10.0)
            if c != trackpadTapMin { trackpadTapMin = c; return }
            persist(trackpadTapMin, .trackpadTapMin)
            if trackpadTapMin > trackpadTapMax { trackpadTapMax = trackpadTapMin }
        }
    }
    public var trackpadTapMax: Double {
        didSet {
            guard trackpadTapMax != oldValue else { return }
            let c = trackpadTapMax.clamped(to: 1.0...15.0)
            if c != trackpadTapMax { trackpadTapMax = c; return }
            persist(trackpadTapMax, .trackpadTapMax)
        }
    }

    public var trackpadTouchingEnabled: Bool {
        didSet {
            guard trackpadTouchingEnabled != oldValue else { return }
            persist(trackpadTouchingEnabled, .trackpadTouchingEnabled)
        }
    }
    public var trackpadSlidingEnabled: Bool {
        didSet {
            guard trackpadSlidingEnabled != oldValue else { return }
            persist(trackpadSlidingEnabled, .trackpadSlidingEnabled)
        }
    }
    public var trackpadContactEnabled: Bool {
        didSet {
            guard trackpadContactEnabled != oldValue else { return }
            persist(trackpadContactEnabled, .trackpadContactEnabled)
        }
    }
    public var trackpadTappingEnabled: Bool {
        didSet {
            guard trackpadTappingEnabled != oldValue else { return }
            persist(trackpadTappingEnabled, .trackpadTappingEnabled)
        }
    }
    public var trackpadCirclingEnabled: Bool {
        didSet {
            guard trackpadCirclingEnabled != oldValue else { return }
            persist(trackpadCirclingEnabled, .trackpadCirclingEnabled)
        }
    }

    public var mouseScrollThreshold: Double {
        didSet {
            guard mouseScrollThreshold != oldValue else { return }
            let c = mouseScrollThreshold.clamped(to: 1.0...15.0)
            if c != mouseScrollThreshold { mouseScrollThreshold = c; return }
            persist(mouseScrollThreshold, .mouseScrollThreshold)
        }
    }

    public var firstLaunchDramaFired: Bool {
        didSet {
            guard firstLaunchDramaFired != oldValue else { return }
            persist(firstLaunchDramaFired, .firstLaunchDramaFired)
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
        notificationLocale = d.string(forKey: Key.notificationLocale.rawValue) ?? ""
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

        // LED flash
        ledEnabled               = d.bool(forKey: Key.ledEnabled.rawValue)
        ledBrightnessMin         = d.double(forKey: Key.ledBrightnessMin.rawValue)
        ledBrightnessMax         = d.double(forKey: Key.ledBrightnessMax.rawValue)
        keyboardBrightnessEnabled = d.bool(forKey: Key.keyboardBrightnessEnabled.rawValue)

        // flashEnabled and visualResponseMode must remain adjacent in init.
        // The flashEnabled didSet syncs visualResponseMode; both must be set
        // before any observer can read either property.
        visualResponseMode = VisualResponseMode(
            rawValue: d.string(forKey: Key.visualResponseMode.rawValue) ?? Defaults.visualResponseMode.rawValue
        ) ?? Defaults.visualResponseMode
        // Legacy migration: old builds persisted a separate `screenFlash` Bool.
        // If an existing user had screenFlash=false (explicitly disabled visual
        // response) but visualResponseMode defaulted to .overlay, unify them by
        // forcing visualResponseMode=.off, then delete the legacy key.
        let legacyScreenFlashKey = "screenFlash"
        if d.object(forKey: legacyScreenFlashKey) != nil {
            if d.bool(forKey: legacyScreenFlashKey) == false {
                visualResponseMode = .off
                d.set(VisualResponseMode.off.rawValue, forKey: Key.visualResponseMode.rawValue)
            }
            d.removeObject(forKey: legacyScreenFlashKey)
        }
        // Independent output toggles
        // Migrate: if there's no persisted flashEnabled, derive from visualResponseMode.
        if d.object(forKey: Key.flashEnabled.rawValue) != nil {
            flashEnabled = d.bool(forKey: Key.flashEnabled.rawValue)
        } else {
            let mode = VisualResponseMode(
                rawValue: d.string(forKey: Key.visualResponseMode.rawValue) ?? Defaults.visualResponseMode.rawValue
            ) ?? Defaults.visualResponseMode
            flashEnabled = (mode == .overlay)
        }
        flashActiveDisplayOnly = d.bool(forKey: Key.flashActiveDisplayOnly.rawValue)
        notificationsEnabled = d.bool(forKey: Key.notificationsEnabled.rawValue)

        // Event sources
        enabledStimulusSourceIDs = (d.array(forKey: Key.enabledStimulusSourceIDs.rawValue) as? [String])
            ?? StimulusSourceDefaults.allStimulusSourceIDs

        // Reaction matrices
        soundReactionMatrix        = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.soundReactionMatrix.rawValue) ?? Data()))
        flashReactionMatrix        = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.flashReactionMatrix.rawValue) ?? Data()))
        notificationReactionMatrix = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.notificationReactionMatrix.rawValue) ?? Data()))
        ledReactionMatrix          = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.ledReactionMatrix.rawValue) ?? Data()))

        // New output reaction matrices
        hapticReactionMatrix               = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.hapticReactionMatrix.rawValue) ?? Data()))
        displayBrightnessReactionMatrix    = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.displayBrightnessReactionMatrix.rawValue) ?? Data()))
        displayTintReactionMatrix          = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.displayTintReactionMatrix.rawValue) ?? Data()))
        volumeSpikeReactionMatrix          = ReactionToggleMatrix.decoded(from: (d.data(forKey: Key.volumeSpikeReactionMatrix.rawValue) ?? Data()))

        // New output properties — init assignments
        hapticEnabled              = false
        hapticIntensity            = 1.0
        displayBrightnessEnabled   = false
        displayBrightnessBoost     = 0.5
        displayBrightnessThreshold = 0.4
        displayTintEnabled         = false
        displayTintIntensity       = 0.5
        volumeSpikeEnabled         = false
        volumeSpikeTarget          = 0.9
        volumeSpikeThreshold       = 0.7
        trackpadWindowDuration     = 1.5
        trackpadScrollMin          = 0.1
        trackpadScrollMax          = 0.8
        trackpadTouchingMin        = 0.1
        trackpadTouchingMax        = 0.5
        trackpadSlidingMin         = 0.5
        trackpadSlidingMax         = 0.9
        trackpadContactMin         = 0.5
        trackpadContactMax         = 2.5
        trackpadTapMin             = 2.0
        trackpadTapMax             = 6.0
        trackpadTouchingEnabled    = true
        trackpadSlidingEnabled     = true
        trackpadContactEnabled     = true
        trackpadTappingEnabled     = true
        trackpadCirclingEnabled    = true
        firstLaunchDramaFired      = false

        // New output properties — UserDefaults loads.
        // Use (d.object(forKey:) as? Double) ?? default so that keys that have
        // never been written keep their init default rather than receiving 0.0
        // from d.double(forKey:), which would be clamped to the minimum and
        // then persisted — corrupting every subsequent launch.
        // Bool keys are safe: d.bool returns false for unset keys, matching all
        // new-output defaults (all disabled by default).
        hapticEnabled              = d.bool(forKey: Key.hapticEnabled.rawValue)
        hapticIntensity            = (d.object(forKey: Key.hapticIntensity.rawValue) as? Double) ?? 1.0
        displayBrightnessEnabled   = d.bool(forKey: Key.displayBrightnessEnabled.rawValue)
        displayBrightnessBoost     = (d.object(forKey: Key.displayBrightnessBoost.rawValue) as? Double) ?? 0.5
        displayBrightnessThreshold = (d.object(forKey: Key.displayBrightnessThreshold.rawValue) as? Double) ?? 0.4
        displayTintEnabled         = d.bool(forKey: Key.displayTintEnabled.rawValue)
        displayTintIntensity       = (d.object(forKey: Key.displayTintIntensity.rawValue) as? Double) ?? 0.5
        volumeSpikeEnabled         = d.bool(forKey: Key.volumeSpikeEnabled.rawValue)
        volumeSpikeTarget          = (d.object(forKey: Key.volumeSpikeTarget.rawValue) as? Double) ?? 0.9
        volumeSpikeThreshold       = (d.object(forKey: Key.volumeSpikeThreshold.rawValue) as? Double) ?? 0.7
        trackpadWindowDuration = (d.object(forKey: Key.trackpadWindowDuration.rawValue) as? Double) ?? 1.5
        trackpadScrollMin      = (d.object(forKey: Key.trackpadScrollMin.rawValue) as? Double) ?? 0.1
        trackpadScrollMax      = (d.object(forKey: Key.trackpadScrollMax.rawValue) as? Double) ?? 0.8
        trackpadTouchingMin    = (d.object(forKey: Key.trackpadTouchingMin.rawValue) as? Double) ?? 0.1
        trackpadTouchingMax    = (d.object(forKey: Key.trackpadTouchingMax.rawValue) as? Double) ?? 0.5
        trackpadSlidingMin     = (d.object(forKey: Key.trackpadSlidingMin.rawValue) as? Double) ?? 0.5
        trackpadSlidingMax     = (d.object(forKey: Key.trackpadSlidingMax.rawValue) as? Double) ?? 0.9
        trackpadContactMin     = (d.object(forKey: Key.trackpadContactMin.rawValue) as? Double) ?? 0.5
        trackpadContactMax     = (d.object(forKey: Key.trackpadContactMax.rawValue) as? Double) ?? 2.5
        trackpadTapMin         = (d.object(forKey: Key.trackpadTapMin.rawValue) as? Double) ?? 2.0
        trackpadTapMax         = (d.object(forKey: Key.trackpadTapMax.rawValue) as? Double) ?? 6.0
        // Bool keys registered in defaults so d.bool returns true for unset keys as expected.
        trackpadTouchingEnabled = d.bool(forKey: Key.trackpadTouchingEnabled.rawValue)
        trackpadSlidingEnabled  = d.bool(forKey: Key.trackpadSlidingEnabled.rawValue)
        trackpadContactEnabled  = d.bool(forKey: Key.trackpadContactEnabled.rawValue)
        trackpadTappingEnabled  = d.bool(forKey: Key.trackpadTappingEnabled.rawValue)
        trackpadCirclingEnabled = d.bool(forKey: Key.trackpadCirclingEnabled.rawValue)
        mouseScrollThreshold    = (d.object(forKey: Key.mouseScrollThreshold.rawValue) as? Double) ?? 3.0
        firstLaunchDramaFired      = d.bool(forKey: Key.firstLaunchDramaFired.rawValue)

        if !AppLog.supportsDebugLogging {
            debugLogging = false
            d.set(false, forKey: Key.debugLogging.rawValue)
        }
    }

    // MARK: - Reset

    /// Restores all settings to their factory default values.
    func resetToDefaults() {
        sensitivityMin        = Defaults.sensitivityMin
        sensitivityMax        = Defaults.sensitivityMax
        accelBandpassLowHz    = Defaults.accelBandpassLow
        accelBandpassHighHz   = Defaults.accelBandpassHigh
        debounce              = Defaults.debounce
        soundEnabled          = Defaults.soundEnabled
        debugLogging          = AppLog.supportsDebugLogging ? Defaults.debugLogging : false
        visualResponseMode    = Defaults.visualResponseMode
        notificationLocale    = ""
        flashOpacityMin       = Defaults.flashOpacityMin
        flashOpacityMax       = Defaults.flashOpacityMax
        volumeMin             = Defaults.volumeMin
        volumeMax             = Defaults.volumeMax
        enabledDisplays       = []
        enabledAudioDevices   = []
        enabledSensorIDs      = []
        consensusRequired     = Defaults.consensus
        accelSpikeThreshold   = Defaults.accelSpikeThreshold
        accelCrestFactor      = Defaults.accelCrestFactor
        accelRiseRate         = Defaults.accelRiseRate
        accelConfirmations    = Defaults.accelConfirmations
        accelWarmupSamples    = Defaults.accelWarmup
        accelReportInterval   = Defaults.accelReportInterval
        micSpikeThreshold     = Defaults.micSpikeThreshold
        micCrestFactor        = Defaults.micCrestFactor
        micRiseRate           = Defaults.micRiseRate
        micConfirmations      = Defaults.micConfirmations
        micWarmupSamples      = Defaults.micWarmup
        hpSpikeThreshold      = Defaults.hpSpikeThreshold
        hpCrestFactor         = Defaults.hpCrestFactor
        hpRiseRate            = Defaults.hpRiseRate
        hpConfirmations       = Defaults.hpConfirmations
        hpWarmupSamples       = Defaults.hpWarmup
        ledEnabled               = false
        ledBrightnessMin         = 0.30
        ledBrightnessMax         = 1.00
        keyboardBrightnessEnabled = false
        flashEnabled             = true
        flashActiveDisplayOnly   = false
        notificationsEnabled  = false
        enabledStimulusSourceIDs = StimulusSourceDefaults.allStimulusSourceIDs
        soundReactionMatrix        = ReactionToggleMatrix()
        flashReactionMatrix        = ReactionToggleMatrix()
        notificationReactionMatrix = ReactionToggleMatrix()
        ledReactionMatrix          = ReactionToggleMatrix()
        hapticEnabled              = false
        hapticIntensity            = 1.0
        displayBrightnessEnabled   = false
        displayBrightnessBoost     = 0.5
        displayBrightnessThreshold = 0.4
        displayTintEnabled         = false
        displayTintIntensity       = 0.5
        volumeSpikeEnabled         = false
        volumeSpikeTarget          = 0.9
        volumeSpikeThreshold       = 0.7
        trackpadWindowDuration = 1.5
        trackpadScrollMin      = 0.1
        trackpadScrollMax      = 0.8
        trackpadTouchingMin    = 0.1
        trackpadTouchingMax    = 0.5
        trackpadSlidingMin     = 0.5
        trackpadSlidingMax     = 0.9
        trackpadContactMin     = 0.5
        trackpadContactMax     = 2.5
        trackpadTapMin         = 2.0
        trackpadTapMax         = 6.0
        trackpadTouchingEnabled = true
        trackpadSlidingEnabled  = true
        trackpadContactEnabled  = true
        trackpadTappingEnabled  = true
        trackpadCirclingEnabled = true
        mouseScrollThreshold    = 3.0
        firstLaunchDramaFired      = false
        hapticReactionMatrix               = ReactionToggleMatrix()
        displayBrightnessReactionMatrix    = ReactionToggleMatrix()
        displayTintReactionMatrix          = ReactionToggleMatrix()
        volumeSpikeReactionMatrix          = ReactionToggleMatrix()
    }

    // MARK: - Private

    private func persist<T>(_ value: T, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}

// MARK: - Output config snapshots (consumed by ResponseKit outputs)

extension SettingsStore: OutputConfigProvider {
    public func audioConfig() -> AudioOutputConfig {
        AudioOutputConfig(
            enabled: soundEnabled,
            volumeMin: Float(volumeMin),
            volumeMax: Float(volumeMax),
            deviceUIDs: enabledAudioDevices,
            perReaction: soundReactionMatrix.asDictionary()
        )
    }

    public func flashConfig() -> FlashOutputConfig {
        FlashOutputConfig(
            enabled: flashEnabled,
            opacityMin: Float(flashOpacityMin),
            opacityMax: Float(flashOpacityMax),
            enabledDisplayIDs: enabledDisplays,
            perReaction: flashReactionMatrix.asDictionary(),
            dismissAfter: debounce,
            activeDisplayOnly: flashActiveDisplayOnly
        )
    }

    public func notificationConfig() -> NotificationOutputConfig {
        NotificationOutputConfig(
            enabled: notificationsEnabled,
            perReaction: notificationReactionMatrix.asDictionary(),
            dismissAfter: max(0.5, debounce),
            localeID: resolvedNotificationLocale
        )
    }

    public func ledConfig() -> LEDOutputConfig {
        LEDOutputConfig(
            enabled: ledEnabled,
            brightnessMin: Float(ledBrightnessMin),
            brightnessMax: Float(ledBrightnessMax),
            keyboardBrightnessEnabled: keyboardBrightnessEnabled,
            perReaction: ledReactionMatrix.asDictionary()
        )
    }

    public func hapticConfig() -> HapticOutputConfig {
        HapticOutputConfig(enabled: hapticEnabled, intensity: hapticIntensity,
                           perReaction: hapticReactionMatrix.asDictionary())
    }

    public func displayBrightnessConfig() -> DisplayBrightnessOutputConfig {
        DisplayBrightnessOutputConfig(enabled: displayBrightnessEnabled, boost: displayBrightnessBoost,
                                      threshold: displayBrightnessThreshold,
                                      perReaction: displayBrightnessReactionMatrix.asDictionary())
    }

    public func displayTintConfig() -> DisplayTintOutputConfig {
        DisplayTintOutputConfig(enabled: displayTintEnabled, intensity: displayTintIntensity,
                                perReaction: displayTintReactionMatrix.asDictionary())
    }

    public func volumeSpikeConfig() -> VolumeSpikeOutputConfig {
        VolumeSpikeOutputConfig(enabled: volumeSpikeEnabled, targetVolume: volumeSpikeTarget,
                                threshold: volumeSpikeThreshold,
                                perReaction: volumeSpikeReactionMatrix.asDictionary())
    }

    public func trackpadSourceConfig() -> TrackpadSourceConfig {
        TrackpadSourceConfig(
            windowDuration: trackpadWindowDuration,
            scrollMin: trackpadScrollMin, scrollMax: trackpadScrollMax,
            contactMin: trackpadContactMin, contactMax: trackpadContactMax,
            tapMin: trackpadTapMin, tapMax: trackpadTapMax
        )
    }
}
