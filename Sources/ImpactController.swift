import Foundation
import Observation

private let log = AppLog(category: "ImpactController")

/// Central coordinator: sensor → detector → audio + flash.
///
/// The signal chain uses normalized intensity as a shared parameter that
/// flows through four sliding windows (all user-configurable range sliders):
///
///   raw force → [sensitivity band] → intensity 0–1 → [volume band]    → audio level
///                                                  → [opacity band]   → flash brightness
///                                                  → debounce  → cooldown time
///
/// Narrowing any window compresses the response; widening it expands it.
/// All four are coupled through the same intensity value.
///
/// The sensor stream is consumed via `for await event in sensorManager.events()`.
/// Cancelling `sensorTask` propagates through the entire chain — no callbacks,
/// no weak self, no manual cleanup.
@MainActor @Observable
final class ImpactController: @unchecked Sendable {
    let settings: SettingsStore
    let audioPlayer: AudioPlayer

    private let sensorManager: SensorManager
    private let detector = ImpactDetector()
    private let screenFlash = ScreenFlash()

    var impactCount: Int = 0
    var isEnabled = false
    var sensorError: String?
    var sensorName: String?

    private var sensorTask: Task<Void, Never>?
    private var playingUntil: Date = .distantPast
    private var countDate: Date = Calendar.current.startOfDay(for: Date())
    private var cachedSensitivityMin: Double = -1
    private var cachedSensitivityMax: Double = -1

    /// After HPF removes gravity, this maps raw force to 0–1 intensity.
    private static let intensityFloor: Float = 0.15
    private static let intensityCeiling: Float = 1.5
    private let intensityRange: ClosedRange<Float> = intensityFloor...intensityCeiling

    init(settings: SettingsStore, adapters: [any SensorAdapter]? = nil) {
        self.settings = settings
        audioPlayer = AudioPlayer()
        sensorManager = SensorManager(adapters: adapters ?? [
            SPUAccelerometerAdapter(),
        ])
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        sensorError = nil
        detector.sensitivity = (settings.sensitivityMin + settings.sensitivityMax) / 2.0
        log.info("activity:ImpactDetection wasStartedBy agent:ImpactController sensitivityBand=[\(String(format: "%.2f", settings.sensitivityMin)),\(String(format: "%.2f", settings.sensitivityMax))]")

        sensorTask = Task {
            for await event in sensorManager.events() {
                switch event {
                case .sample(let vec):  handleSample(vec)
                case .error(let msg):   sensorError = msg
                case .adapterChanged(let name): sensorName = name
                }
            }
        }
    }

    func stop() {
        sensorTask?.cancel()
        sensorTask = nil
        isEnabled = false
        sensorName = nil
        log.info("activity:ImpactDetection wasEndedBy agent:ImpactController")
    }

    func toggle() {
        isEnabled ? stop() : start()
    }

    // MARK: - Private

    private func handleSample(_ vec: Vec3) {
        if settings.sensitivityMin != cachedSensitivityMin || settings.sensitivityMax != cachedSensitivityMax {
            cachedSensitivityMin = settings.sensitivityMin
            cachedSensitivityMax = settings.sensitivityMax
            detector.sensitivity = (cachedSensitivityMin + cachedSensitivityMax) / 2.0
        }

        guard let event = detector.process(vec) else { return }

        let now = Date()
        guard now >= playingUntil else { return }

        // ── Stage 1: Sensitivity band → normalized intensity ──────
        let mag = event.amplitude.magnitude
        let rawIntensity = ((mag - intensityRange.lowerBound)
            / (intensityRange.upperBound - intensityRange.lowerBound))
            .clamped(to: 0...1)

        let sMin = Float(settings.sensitivityMin)
        let sMax = Float(settings.sensitivityMax)
        guard rawIntensity >= sMin else { return }

        let bandWidth = max(Float(0.001), sMax - sMin)
        let intensity = ((rawIntensity - sMin) / bandWidth).clamped(to: 0...1)

        // ── Stage 2: Intensity flows through all output windows ───
        let clipDuration = audioPlayer.play(
            intensity: intensity,
            volumeMin: Float(settings.volumeMin),
            volumeMax: Float(settings.volumeMax),
            deviceUIDs: settings.enabledAudioDevices
        )

        let debounce = settings.debounce
        playingUntil = now.addingTimeInterval(max(clipDuration, debounce))

        if settings.screenFlash && clipDuration > 0 {
            screenFlash.flash(
                intensity: intensity,
                opacityMin: Float(settings.flashOpacityMin),
                opacityMax: Float(settings.flashOpacityMax),
                clipDuration: clipDuration,
                enabledDisplayIDs: settings.enabledDisplays
            )
        }

        // Reset counter at day boundary
        let today = Calendar.current.startOfDay(for: now)
        if today > countDate {
            impactCount = 0
            countDate = today
        }
        impactCount += 1
    }
}
