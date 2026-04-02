import Foundation
import Observation

private let log = AppLog(category: "ImpactController")

/// Central coordinator: accelerometer → detector → audio + flash.
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
@MainActor @Observable
final class ImpactController: @unchecked Sendable {
    let settings: SettingsStore
    let audioPlayer: AudioPlayer

    private let accelerometer = AccelerometerReader()
    private let detector = ImpactDetector()
    private let screenFlash = ScreenFlash()

    var impactCount: Int = 0
    var isEnabled = false
    var sensorError: String?

    private var playingUntil: Date = .distantPast
    private var countDate: Date = Calendar.current.startOfDay(for: Date())

    // Calibrated for "fun impact" range. After HPF removes gravity:
    //   0.15g = lightest detectable tap (above typing noise)
    //   1.5g  = hard impact (approaching damage threshold)
    private let intensityRange: ClosedRange<Float> = 0.15...1.5

    init(settings: SettingsStore) {
        self.settings = settings
        audioPlayer = AudioPlayer()
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        sensorError = nil
        detector.sensitivity = (settings.sensitivityMin + settings.sensitivityMax) / 2.0
        log.info("activity:ImpactDetection wasStartedBy agent:ImpactController sensitivityBand=[\(String(format: "%.2f", settings.sensitivityMin)),\(String(format: "%.2f", settings.sensitivityMax))]")

        accelerometer.onSample = { [weak self] vec in
            MainActor.assumeIsolated { self?.handleSample(vec) }
        }
        accelerometer.onError = { [weak self] msg in
            MainActor.assumeIsolated { self?.sensorError = msg }
        }
        accelerometer.start()
    }

    func stop() {
        isEnabled = false
        accelerometer.stop()
        log.info("activity:ImpactDetection wasEndedBy agent:ImpactController")
    }

    func toggle() {
        isEnabled ? stop() : start()
    }

    // MARK: - Private

    private func handleSample(_ vec: Vec3) {
        detector.sensitivity = (settings.sensitivityMin + settings.sensitivityMax) / 2.0

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
        // Volume:  intensity 0 → volumeMin,  intensity 1 → volumeMax
        // Opacity: intensity 0 → opacityMin, intensity 1 → opacityMax
        // Debounce: intensity 0 → debounceMin (quick), intensity 1 → debounceMax (long)

        let deviceUID: String? = settings.audioDeviceUID.isEmpty ? nil : settings.audioDeviceUID
        let clipDuration = audioPlayer.play(
            intensity: intensity,
            volumeMin: Float(settings.volumeMin),
            volumeMax: Float(settings.volumeMax),
            deviceUID: deviceUID
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
