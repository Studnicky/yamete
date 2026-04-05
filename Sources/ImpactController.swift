import Foundation
import Observation

private let log = AppLog(category: "ImpactController")

/// Coordinates sensor input, impact detection, and app responses.
@MainActor @Observable
final class ImpactController {
    let settings: SettingsStore
    let audioPlayer: AudioPlayer

    private let sensorManager: SensorManager
    private let fusion = SensorFusionEngine()
    private let screenFlash = ScreenFlash()

    var impactCount: Int = 0
    var isEnabled = false
    var sensorError: String?
    var sensorName: String?
    var lastImpactMagnitude: Float = 0
    var lastImpactTier: ImpactTier?
    var lastImpactFreqHz: String = "—"

    private var sensorTask: Task<Void, Never>?
    private var playingUntil: Date = .distantPast
    private var countDate: Date = Calendar.current.startOfDay(for: Date())
    private var activeSensors: Set<String> = []

    /// Maps post-fusion force to normalized intensity.
    /// IOHIDEventSystem returns pre-smoothed values — typical range:
    ///   light tap: ~0.003g filtered, hard hit: ~0.03g, maximum: ~0.6g
    /// Intensity mapping calibrated to IOHIDEventSystem data:
    ///   0.020g = firm desk slap (minimum useful impact)
    ///   0.060g = hard slap (approaching hardware stress)
    private static let intensityFloor: Float = 0.020
    private static let intensityCeiling: Float = 0.060
    private let intensityRange: ClosedRange<Float> = intensityFloor...intensityCeiling

    init(settings: SettingsStore, adapters: [any SensorAdapter]? = nil) {
        self.settings = settings
        audioPlayer = AudioPlayer()
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
                case .adaptersActive(let names):
                    activeSensors = Set(names)
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
        activeSensors = []
        log.info("activity:ImpactDetection wasEndedBy agent:ImpactController")
    }

    func toggle() { isEnabled ? stop() : start() }

    // MARK: - Signal chain

    private func handleSample(_ sample: SensorSample) {
        fusion.setBandpass(lowHz: Float(settings.bandpassLowHz), highHz: Float(settings.bandpassHighHz))
        fusion.spikeThreshold = Float(settings.spikeThreshold)
        fusion.minCrestFactor = Float(settings.crestFactor)
        fusion.minRiseRate = Float(settings.riseRate)
        fusion.minConfirmations = settings.confirmations
        fusion.minRearmDuration = settings.debounce
        fusion.minWarmupSamples = settings.warmupSamples
        let sources = activeSensors.isEmpty ? Set([sample.source]) : activeSensors
        guard let fused = fusion.ingest(sample, activeSources: sources) else { return }

        let now = fused.timestamp
        let mag = fused.amplitude.magnitude
        guard now >= playingUntil else {
            log.debug("entity:Gate blocked=debounce mag=\(String(format: "%.4f", mag)) remaining=\(String(format: "%.2f", playingUntil.timeIntervalSince(now)))s")
            return
        }

        guard let intensity = normalizeIntensity(mag) else {
            log.debug("entity:Gate blocked=sensitivity mag=\(String(format: "%.4f", mag))")
            return
        }

        let tier = ImpactTier.from(intensity: intensity)
        lastImpactMagnitude = mag
        lastImpactTier = tier
        lastImpactFreqHz = "\(Int(settings.bandpassLowHz))–\(Int(settings.bandpassHighHz)) Hz"

        let clipDuration = playAudioResponse(intensity: intensity)
        playingUntil = now.addingTimeInterval(max(clipDuration, settings.debounce))

        if settings.screenFlash && clipDuration > 0 {
            flashScreenResponse(intensity: intensity, clipDuration: clipDuration)
        }

        log.debug("entity:Impact tier=\(tier) intensity=\(String(format: "%.2f", intensity)) mag=\(String(format: "%.4f", mag)) confidence=\(String(format: "%.2f", fused.confidence))")
        incrementDailyCount(now: now)
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

    // MARK: - Response

    /// Plays audio scaled by intensity. Returns clip duration.
    private func playAudioResponse(intensity: Float) -> Double {
        audioPlayer.play(
            intensity: intensity,
            volumeMin: Float(settings.volumeMin),
            volumeMax: Float(settings.volumeMax),
            deviceUIDs: settings.enabledAudioDevices
        )
    }

    /// Flashes screens with intensity-scaled overlay.
    private func flashScreenResponse(intensity: Float, clipDuration: Double) {
        screenFlash.flash(
            intensity: intensity,
            opacityMin: Float(settings.flashOpacityMin),
            opacityMax: Float(settings.flashOpacityMax),
            clipDuration: clipDuration,
            enabledDisplayIDs: settings.enabledDisplays
        )
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
