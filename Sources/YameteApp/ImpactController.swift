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

/// Coordinates sensor input, impact detection, and app responses.
///
/// Signal chain:
///   sensor sample → detection (fusion engine) → normalization → response (audio + flash)
@MainActor @Observable
final class ImpactController {
    let settings: SettingsStore
    let audioPlayer: any AudioResponder

    private let sensorManager: SensorManager
    private let fusion = ImpactDetectionEngine()
    private let screenFlash: any FlashResponder

    var impactCount: Int = 0
    var isEnabled = false
    var sensorError: String?
    var sensorName: String?
    var lastImpactMagnitude: Float = 0
    var lastImpactTier: ImpactTier?
    var lastImpactFreqHz: String = "—"

    private var sensorTask: Task<Void, Never>?
    private var rearmUntil: Date = .distantPast
    private var countDate: Date = Calendar.current.startOfDay(for: Date())
    private var activeSensorIDs: Set<SensorID> = []

    /// Intensity mapping calibrated to accelerometer data:
    ///   0.020g = firm desk slap (minimum useful impact)
    ///   0.060g = hard slap (approaching hardware stress)
    private static let intensityFloor: Float = 0.020
    private static let intensityCeiling: Float = 0.060
    private let intensityRange: ClosedRange<Float> = intensityFloor...intensityCeiling

    init(settings: SettingsStore,
         audioPlayer: (any AudioResponder)? = nil,
         flashResponder: (any FlashResponder)? = nil,
         adapters: [any SensorAdapter]? = nil) {
        self.settings = settings
        self.audioPlayer = audioPlayer ?? AudioPlayer()
        self.screenFlash = flashResponder ?? ScreenFlash()
        sensorManager = SensorManager(adapters: adapters ?? [
            SPUAccelerometerAdapter(),
        ])
    }

    // MARK: - Lifecycle

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        sensorError = nil
        log.info("activity:ImpactDetection wasStartedBy agent:ImpactController")

        sensorTask = Task {
            for await event in sensorManager.events() {
                switch event {
                case .sample(let sample):
                    handleSample(sample)
                case .error(let msg):
                    sensorError = msg
                case .adaptersChanged(let ids, let names):
                    activeSensorIDs = ids
                    sensorName = names.isEmpty ? nil : names.sorted().joined(separator: ", ")
                }
            }
        }
    }

    func stop() {
        sensorTask?.cancel()
        sensorTask = nil
        isEnabled = false
        sensorName = nil
        activeSensorIDs = []
        log.info("activity:ImpactDetection wasEndedBy agent:ImpactController")
    }

    func toggle() { isEnabled ? stop() : start() }

    /// Plays the longest loaded sound on all output devices at full volume.
    func playWelcomeSound() {
        guard let url = audioPlayer.longestSoundURL else { return }
        audioPlayer.playOnAllDevices(url: url, volume: 1.0)
    }

    // MARK: - Signal chain

    private func handleSample(_ sample: SensorSample) {
        pushConfigToFusion()
        guard let impact = detect(sample) else { return }
        respond(to: impact)
    }

    // MARK: - Detection

    private struct DetectedImpact {
        let magnitude: Float
        let intensity: Float
        let tier: ImpactTier
        let timestamp: Date
        let confidence: Float
    }

    private func detect(_ sample: SensorSample) -> DetectedImpact? {
        let sources = activeSensorIDs.isEmpty ? Set([sample.source]) : activeSensorIDs
        guard let fused = fusion.ingest(sample, activeSources: sources) else { return nil }

        let now = fused.timestamp
        let mag = fused.amplitude.magnitude

        guard now >= rearmUntil else { return nil }
        guard let intensity = normalizeIntensity(mag) else { return nil }

        return DetectedImpact(
            magnitude: mag,
            intensity: intensity,
            tier: ImpactTier.from(intensity: intensity),
            timestamp: now,
            confidence: fused.confidence
        )
    }

    // MARK: - Response

    private func respond(to impact: DetectedImpact) {
        lastImpactMagnitude = impact.magnitude
        lastImpactTier = impact.tier
        lastImpactFreqHz = "\(Int(settings.bandpassLowHz))–\(Int(settings.bandpassHighHz)) Hz"

        let clipDuration = audioPlayer.play(
            intensity: impact.intensity,
            volumeMin: Float(settings.volumeMin),
            volumeMax: Float(settings.volumeMax),
            deviceUIDs: settings.enabledAudioDevices
        )

        rearmUntil = impact.timestamp.addingTimeInterval(max(clipDuration, settings.debounce))

        if settings.screenFlash && clipDuration > 0 {
            screenFlash.flash(
                intensity: impact.intensity,
                opacityMin: Float(settings.flashOpacityMin),
                opacityMax: Float(settings.flashOpacityMax),
                clipDuration: clipDuration,
                enabledDisplayIDs: settings.enabledDisplays
            )
        }

        log.debug("entity:Impact tier=\(impact.tier) intensity=\(String(format: "%.2f", impact.intensity)) mag=\(String(format: "%.4f", impact.magnitude)) confidence=\(String(format: "%.2f", impact.confidence))")
        incrementDailyCount(now: impact.timestamp)
    }

    // MARK: - Configuration

    private func pushConfigToFusion() {
        let config = DetectionConfig(
            spikeThreshold: Float(settings.spikeThreshold),
            minCrestFactor: Float(settings.crestFactor),
            minRiseRate: Float(settings.riseRate),
            minConfirmations: settings.confirmations,
            minRearmDuration: settings.debounce,
            minWarmupSamples: settings.warmupSamples,
            bandpassLowHz: Float(settings.bandpassLowHz),
            bandpassHighHz: Float(settings.bandpassHighHz)
        )
        fusion.configure(config)
    }

    // MARK: - Normalization

    /// Converts force magnitude to 0...1 intensity; returns nil below threshold.
    /// Sensitivity is inverted to thresholds: high sensitivity → low threshold → more reactive.
    private func normalizeIntensity(_ magnitude: Float) -> Float? {
        let rawIntensity = ((magnitude - intensityRange.lowerBound)
            / (intensityRange.upperBound - intensityRange.lowerBound))
            .clamped(to: 0...1)

        let thresholdLow = 1.0 - Float(settings.sensitivityMax)
        let thresholdHigh = 1.0 - Float(settings.sensitivityMin)
        guard rawIntensity >= thresholdLow else { return nil }

        let bandWidth = max(Float(0.001), thresholdHigh - thresholdLow)
        return ((rawIntensity - thresholdLow) / bandWidth).clamped(to: 0...1)
    }

    // MARK: - Daily counter

    private func incrementDailyCount(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        if today > countDate {
            impactCount = 0
            countDate = today
        }
        impactCount += 1
    }
}
