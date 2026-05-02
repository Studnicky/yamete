#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import CoreHaptics

private let log = AppLog(category: "HapticResponder")

/// Fires Force Touch haptic pulses on impact using CoreHaptics.
/// Unlike NSHapticFeedbackManager, CHHapticEngine fires even when the app is
/// not the frontmost window — correct behaviour for a menu-bar app.
/// Pulse density and intensity scale with the Envelope level.
/// No entitlements required. Requires a Mac with a Force Touch trackpad.
///
/// Hardware boundary: `HapticEngineDriver`. The default `init()` produces a
/// `RealHapticEngineDriver` (CHHapticEngine-backed). Tests inject a mock that
/// reports `isHardwareAvailable = true` regardless of host capabilities and
/// records every `playPattern` call.
@MainActor
public final class HapticResponder: ReactiveOutput {

    private let driver: HapticEngineDriver
    private var engineStarted = false
    public let hardwareAvailable: Bool

    public override init() {
        self.driver = RealHapticEngineDriver()
        self.hardwareAvailable = self.driver.isHardwareAvailable
    }

    public init(driver: HapticEngineDriver) {
        self.driver = driver
        self.hardwareAvailable = driver.isHardwareAvailable
    }

    // MARK: - ReactiveOutput lifecycle

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        let c = provider.hapticConfig()
        return hardwareAvailable && c.enabled && c.perReaction[fired.kind] != false
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        guard hardwareAvailable else { return }

        // Lazy engine init — runs on MainActor so no concurrency concern.
        if !engineStarted {
            do {
                try await driver.start()
                engineStarted = true
                log.info("entity:HapticEngine wasGeneratedBy activity:Init")
            } catch {
                log.warning("entity:HapticEngine wasInvalidatedBy activity:Init — \(error.localizedDescription)")
                return
            }
        }

        let config = provider.hapticConfig()
        let effectiveIntensity = min(1.0, fired.intensity * multiplier)
        let envelope = Envelope.make(clipDuration: fired.clipDuration, intensity: effectiveIntensity)
        let total = envelope.total
        let basePulses = max(1, Int((Double(effectiveIntensity) * config.intensity * 8).rounded()))
        let tickS = total / Double(basePulses)

        do {
            // Build all transient events upfront as a CHHapticPattern so the
            // entire burst plays in a single engine call — no per-pulse await loop.
            var events: [CHHapticEvent] = []
            for i in 0..<basePulses {
                let t = Double(i) * tickS
                let level = Float(envelope.level(at: t))
                guard level > 0.1 else { continue }
                let scaledIntensity = level * Float(min(config.intensity, 1.0))
                let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: scaledIntensity)
                let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: scaledIntensity)
                let event = CHHapticEvent(eventType: .hapticTransient,
                                          parameters: [intensityParam, sharpnessParam],
                                          relativeTime: t)
                events.append(event)
            }
            guard !events.isEmpty else { return }

            let pattern = try CHHapticPattern(events: events, parameters: [])
            try await driver.playPattern(pattern)

            log.debug("activity:HapticRumble pulses=\(events.count) duration=\(String(format:"%.2f",total))s")

            // Wait for pattern to finish before postAction runs.
            try? await Task.sleep(for: .seconds(total))
        } catch {
            log.warning("activity:HapticEngine playback failed — \(error.localizedDescription)")
            // Engine may have reset; clear it so the next call recreates it.
            engineStarted = false
        }
    }

    override public func reset() {
        driver.stop()
        engineStarted = false
    }
}
