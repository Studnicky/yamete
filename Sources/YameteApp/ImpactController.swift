#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(SensorKit)
import SensorKit
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import Foundation
import Observation

private let log = AppLog(category: "ImpactController")

/// Coordinates sensor adapters, impact fusion, and app responses.
///
/// Signal chain:
///   adapter (per-sensor detection) → fusion engine (consensus + rearm) → response (audio + flash)
@MainActor @Observable
public final class ImpactController {
    let settings: SettingsStore
    let audioPlayer: any AudioResponder

    public let allAdapters: [any SensorAdapter]
    private var sensorManager: SensorManager
    private let fusion = ImpactFusionEngine()
    private let screenFlash: any FlashResponder

    var impactCount: Int = 0
    var isEnabled = false
    var sensorError: String?
    var lastImpactMagnitude: Float = 0
    var lastImpactTier: ImpactTier?

    private var sensorTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var lastPushedConfig: FusionConfig?
    private var rearmUntil: Date = .distantPast
    private var countDate: Date = Calendar.current.startOfDay(for: Date())
    private var activeSensorIDs: Set<SensorID> = []

    public init(settings: SettingsStore,
         audioPlayer: (any AudioResponder)? = nil,
         flashResponder: (any FlashResponder)? = nil,
         adapters: [any SensorAdapter]? = nil) {
        self.settings = settings
        self.audioPlayer = audioPlayer ?? AudioPlayer()
        self.screenFlash = flashResponder ?? ScreenFlash()
        self.allAdapters = adapters ?? [
            SPUAccelerometerAdapter(),
            MicrophoneAdapter(),
            HeadphoneMotionAdapter(),
        ]
        sensorManager = SensorManager(adapters: allAdapters)
    }

    // MARK: - Lifecycle (driven by response toggles)

    /// Whether any response is enabled. Pipeline runs only when true.
    var shouldBeEnabled: Bool { settings.soundEnabled || settings.screenFlash }

    /// Called once at app launch. Starts the settings observation loop
    /// which manages the pipeline lifecycle based on response toggles.
    public func bootstrap() {
        AppLog.debugEnabled = AppLog.supportsDebugLogging && settings.debugLogging
        syncPipelineState()
        startSettingsObservation()
    }

    private func syncPipelineState() {
        if shouldBeEnabled && !isEnabled {
            startPipeline()
        } else if !shouldBeEnabled && isEnabled {
            stopPipeline()
        }
    }

    private func rebuildPipeline() {
        AppLog.debugEnabled = AppLog.supportsDebugLogging && settings.debugLogging
        if isEnabled { stopPipeline() }
        if shouldBeEnabled { startPipeline() }
    }

    private func startPipeline() {
        guard !isEnabled else { return }
        isEnabled = true
        sensorError = nil

        let adapters = buildAdapters()
        sensorManager = SensorManager(adapters: adapters)
        log.info("activity:ImpactDetection wasStartedBy agent:ImpactController adapters=\(adapters.map(\.name))")

        sensorTask = Task {
            for await event in sensorManager.events() {
                switch event {
                case .impact(let impact):
                    handleImpact(impact)
                case .error(let msg):
                    sensorError = msg
                case .adaptersChanged(let ids, _):
                    activeSensorIDs = ids
                }
            }
        }
    }

    private func stopPipeline() {
        sensorTask?.cancel()
        sensorTask = nil
        isEnabled = false
        activeSensorIDs = []
        fusion.reset()
        lastPushedConfig = nil
        log.info("activity:ImpactDetection wasEndedBy agent:ImpactController")
    }

    private func startSettingsObservation() {
        settingsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let changed = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        guard let self else { return }
                        _ = self.settings.soundEnabled
                        _ = self.settings.screenFlash
                        _ = self.settings.debugLogging
                        _ = self.settings.accelSpikeThreshold
                        _ = self.settings.accelRiseRate
                        _ = self.settings.accelCrestFactor
                        _ = self.settings.accelConfirmations
                        _ = self.settings.accelWarmupSamples
                        _ = self.settings.accelBandpassLowHz
                        _ = self.settings.accelBandpassHighHz
                        _ = self.settings.accelReportInterval
                        _ = self.settings.micSpikeThreshold
                        _ = self.settings.micRiseRate
                        _ = self.settings.micCrestFactor
                        _ = self.settings.micConfirmations
                        _ = self.settings.micWarmupSamples
                        _ = self.settings.hpSpikeThreshold
                        _ = self.settings.hpRiseRate
                        _ = self.settings.hpCrestFactor
                        _ = self.settings.hpConfirmations
                        _ = self.settings.hpWarmupSamples
                        _ = self.settings.enabledSensorIDs
                    } onChange: {
                        continuation.resume(returning: true)
                    }
                }
                guard changed, let self, !Task.isCancelled else { break }
                self.rebuildPipeline()
                // Re-register by looping
            }
        }
    }

    public func playWelcomeSound() {
        guard let url = audioPlayer.longestSoundURL else { return }
        audioPlayer.playOnAllDevices(url: url, volume: 1.0)
    }

    // MARK: - Impact handling

    private func handleImpact(_ impact: SensorImpact) {
        pushFusionConfigIfNeeded()

        guard let fused = fusion.ingest(impact, activeSources: activeSensorIDs) else { return }
        guard Date() >= rearmUntil else { return }
        guard let intensity = mapSensitivity(fused.intensity) else { return }

        respond(intensity: intensity, timestamp: fused.timestamp, confidence: fused.confidence)
    }

    // MARK: - Response

    private func respond(intensity: Float, timestamp: Date, confidence: Float) {
        let tier = ImpactTier.from(intensity: intensity)
        lastImpactMagnitude = intensity
        lastImpactTier = tier

        let clipDuration = ImpactResponse.playSound(
            audioPlayer: audioPlayer, settings: settings, intensity: intensity)
        rearmUntil = ImpactResponse.rearmDeadline(
            from: timestamp, clipDuration: clipDuration, debounce: settings.debounce)
        ImpactResponse.triggerFlash(
            flashResponder: screenFlash, settings: settings,
            intensity: intensity, clipDuration: clipDuration)

        log.debug("entity:Impact tier=\(tier) intensity=\(String(format: "%.2f", intensity)) confidence=\(String(format: "%.2f", confidence))")
        incrementDailyCount(now: timestamp)
    }

    // MARK: - Configuration

    /// Builds fresh adapter instances configured from current settings.
    /// Adapters are immutable after creation — config is baked in at init.
    private func buildAdapters() -> [any SensorAdapter] {
        let enabled = Set(settings.enabledSensorIDs)
        return allAdapters.compactMap { template -> (any SensorAdapter)? in
            guard enabled.contains(template.id.rawValue) else { return nil }
            switch template.id {
            case .accelerometer: return AdapterFactory.accelerometer(from: settings)
            case .microphone:    return AdapterFactory.microphone(from: settings)
            case .headphoneMotion: return AdapterFactory.headphoneMotion(from: settings)
            default:             return template
            }
        }
    }

    private func pushFusionConfigIfNeeded() {
        let config = FusionConfig(
            consensusRequired: settings.consensusRequired,
            rearmDuration: settings.debounce
        )
        guard config != lastPushedConfig else { return }
        lastPushedConfig = config
        fusion.configure(config)
    }

    // MARK: - Sensitivity mapping

    /// Maps 0–1 adapter intensity through the user's sensitivity window.
    private func mapSensitivity(_ intensity: Float) -> Float? {
        let thresholdLow = 1.0 - Float(settings.sensitivityMax)
        let thresholdHigh = 1.0 - Float(settings.sensitivityMin)
        guard intensity >= thresholdLow else { return nil }

        let bandWidth = max(Float(0.001), thresholdHigh - thresholdLow)
        return ((intensity - thresholdLow) / bandWidth).clamped(to: 0...1)
    }

    // MARK: - Daily counter

    private func incrementDailyCount(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        if today > countDate { impactCount = 0; countDate = today }
        impactCount += 1
    }
}

// MARK: - Impact response dispatch

@MainActor
private enum ImpactResponse {
    static func playSound(audioPlayer: any AudioResponder, settings: SettingsStore, intensity: Float) -> Double {
        guard settings.soundEnabled else { return 0 }
        return audioPlayer.play(
            intensity: intensity,
            volumeMin: Float(settings.volumeMin),
            volumeMax: Float(settings.volumeMax),
            deviceUIDs: settings.enabledAudioDevices)
    }

    static func rearmDeadline(from timestamp: Date, clipDuration: Double, debounce: Double) -> Date {
        timestamp.addingTimeInterval(max(clipDuration, debounce))
    }

    static func triggerFlash(flashResponder: any FlashResponder, settings: SettingsStore,
                             intensity: Float, clipDuration: Double) {
        guard settings.screenFlash else { return }
        flashResponder.flash(
            intensity: intensity,
            opacityMin: Float(settings.flashOpacityMin),
            opacityMax: Float(settings.flashOpacityMax),
            clipDuration: clipDuration > 0 ? clipDuration : 0.5,
            enabledDisplayIDs: settings.enabledDisplays)
    }
}

// MARK: - Adapter construction from current settings

@MainActor
private enum AdapterFactory {
    static func accelerometer(from s: SettingsStore) -> SPUAccelerometerAdapter {
        SPUAccelerometerAdapter(
            reportIntervalUS: Int(s.accelReportInterval),
            bandpassLowHz: Float(s.accelBandpassLowHz),
            bandpassHighHz: Float(s.accelBandpassHighHz),
            detectorConfig: .accelerometer(
                spikeThreshold: Float(s.accelSpikeThreshold),
                riseRate: Float(s.accelRiseRate),
                crestFactor: Float(s.accelCrestFactor),
                confirmations: s.accelConfirmations,
                warmupSamples: s.accelWarmupSamples))
    }

    static func microphone(from s: SettingsStore) -> MicrophoneAdapter {
        MicrophoneAdapter(detectorConfig: .microphone(
            spikeThreshold: Float(s.micSpikeThreshold),
            riseRate: Float(s.micRiseRate),
            crestFactor: Float(s.micCrestFactor),
            confirmations: s.micConfirmations,
            warmupSamples: s.micWarmupSamples))
    }

    static func headphoneMotion(from s: SettingsStore) -> HeadphoneMotionAdapter {
        HeadphoneMotionAdapter(detectorConfig: .headphoneMotion(
            spikeThreshold: Float(s.hpSpikeThreshold),
            riseRate: Float(s.hpRiseRate),
            crestFactor: Float(s.hpCrestFactor),
            confirmations: s.hpConfirmations,
            warmupSamples: s.hpWarmupSamples))
    }
}
