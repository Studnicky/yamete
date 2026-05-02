#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation
import os

private let log = AppLog(category: "LEDFlash")

/// Drives the keyboard backlight + Caps Lock LED in a damped sinusoidal flash
/// pattern. All hardware access is delegated to a `LEDBrightnessDriver`. The
/// default initializer wires a `RealLEDBrightnessDriver`; tests inject a mock.
@MainActor
public final class LEDFlash: ReactiveOutput {
    private let driver: LEDBrightnessDriver
    private let pwmHz: Double = ReactionsConfig.ledPwmHz

    // Captured at launch — authoritative fallback for restore.
    private var kbLaunchLevel: Float = 1.0
    private var kbLaunchAutoEnabled: Bool = true

    // Snapshotted once before the first pulse in a sequence, never mid-flight.
    private var kbSnapshotLevel: Float = 1.0
    private var kbSnapshotAutoEnabled: Bool = true
    private var kbPulseActive: Bool = false

    public override init() {
        self.driver = RealLEDBrightnessDriver()
        super.init()
    }

    public init(driver: LEDBrightnessDriver) {
        self.driver = driver
        super.init()
    }

    /// Snapshots the initial keyboard brightness and clears any crash sentinel.
    /// Must be called from a MainActor context before the first reaction fires —
    /// called by `Yamete.bootstrap()`.
    public func setUp() {
        guard driver.keyboardBacklightAvailable else {
            log.warning("entity:KeyboardBrightnessClient wasInvalidatedBy activity:Init — backlight unavailable")
            return
        }
        // T2-B: crash-recovery sentinel — read before kbLaunchLevel is set.
        let dirtyURL = LEDFlash.kbDirtyFileURL()
        if let dirtyURL, FileManager.default.fileExists(atPath: dirtyURL.path),
           let raw = try? String(contentsOf: dirtyURL, encoding: .utf8),
           let recovered = Float(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kbLaunchLevel = recovered
            log.warning("entity:KeyboardBrightnessSentinel wasGeneratedBy activity:CrashRecovery level=\(String(format:"%.4f", recovered))")
            hardResetKBToLevel(recovered)
            try? FileManager.default.removeItem(at: dirtyURL)
        } else {
            kbLaunchLevel = driver.currentLevel() ?? 1.0
        }
        kbLaunchAutoEnabled = driver.isAutoEnabled()
        kbSnapshotLevel = kbLaunchLevel
        kbSnapshotAutoEnabled = kbLaunchAutoEnabled
        // Write sentinel so a crash leaves evidence of the pre-pulse level.
        if let dirtyURL {
            let fm = FileManager.default
            try? fm.createDirectory(at: dirtyURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? String(kbLaunchLevel).write(to: dirtyURL, atomically: true, encoding: .utf8)
        }
        log.info("entity:KeyboardBrightnessClient wasGeneratedBy activity:Init level=\(String(format:"%.4f", kbLaunchLevel)) auto=\(kbLaunchAutoEnabled)")
    }

    private static func kbDirtyFileURL() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent(LogStore.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("kb_dirty")
    }

    // MARK: - ReactiveOutput lifecycle

    /// True if CoreBrightness is available — exposes driver capability for callers.
    public var keyboardBacklightAvailable: Bool { driver.keyboardBacklightAvailable }

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        let c = provider.ledConfig()
        return (c.enabled || c.keyboardBrightnessEnabled) && c.perReaction[fired.kind] != false
    }

    override public func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        let config = provider.ledConfig()
        guard config.keyboardBrightnessEnabled else { return }
        // Always re-read live system brightness on every preAction so a sequence of
        // flashes restores to the current value, not a stale launch-time snapshot.
        let currentLevel = driver.currentLevel() ?? kbLaunchLevel
        kbSnapshotLevel = currentLevel > 0.01 ? currentLevel : kbLaunchLevel
        kbSnapshotAutoEnabled = driver.isAutoEnabled()
        driver.setIdleDimmingSuspended(true)
        kbPulseActive = true
        log.info("activity:KBSnapshot current=\(String(format:"%.4f", currentLevel)) using=\(String(format:"%.4f", kbSnapshotLevel))")
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        let config = provider.ledConfig()
        guard config.enabled || config.keyboardBrightnessEnabled,
              config.perReaction[fired.kind] != false else { return }
        let envelope = Envelope.make(clipDuration: fired.clipDuration, intensity: fired.intensity)
        guard envelope.total >= ReactionsConfig.ledMinPulseDuration else { return }
        let total = min(envelope.total, ReactionsConfig.ledMaxPulseDuration)
        let kbEnabled = config.keyboardBrightnessEnabled

        let base = Double(kbSnapshotLevel)
        let effectiveIntensity = min(1.0, fired.intensity * multiplier)
        let maxSwing = min(base, 1.0 - base, Double(effectiveIntensity))
        let amplitude = max(maxSwing, Double(effectiveIntensity) * 0.3)
        let omega = 2.0 * Double.pi * 3.0
        let decay = 3.5 / total
        let easeInDuration = min(0.08, total * 0.15)
        let tickNs = UInt64(1_000_000_000.0 / pwmHz)
        let start = Date()
        var pwmCounter = 0
        var lastLoggedLevel: Float = -1

        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            if t >= total { break }
            let easeIn = t < easeInDuration ? t / easeInDuration : 1.0
            let level = base + amplitude * easeIn * exp(-decay * t) * cos(omega * t)
            if kbEnabled {
                let kbLevel = Float(level).clamped(to: 0...1)
                if abs(kbLevel - lastLoggedLevel) > 0.1 {
                    log.debug("activity:KBWrite level=\(String(format:"%.3f",kbLevel)) t=\(String(format:"%.3f",t))")
                    lastLoggedLevel = kbLevel
                }
                driver.setLevel(kbLevel)
            }
            let dutyCyclePct = Int(level * 100)
            let shouldBeOn = (pwmCounter % 100) < dutyCyclePct
            driver.capsLockSet(shouldBeOn)
            pwmCounter += 1
            try? await Task.sleep(nanoseconds: tickNs)
        }

        driver.capsLockSet(false)
        log.debug("activity:LEDFlash wasStartedBy entity:LEDFlash duration=\(String(format: "%.2f", total))s")
    }

    override public func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        hardResetKB()
    }

    override public func reset() {
        hardResetKB()
    }

    private func hardResetKB() {
        hardResetKBToLevel(kbSnapshotLevel)
        driver.setAutoEnabled(kbSnapshotAutoEnabled)
        kbPulseActive = false
        // T2-B: clean up sentinel now that the level is successfully restored.
        if let dirtyURL = LEDFlash.kbDirtyFileURL() {
            try? FileManager.default.removeItem(at: dirtyURL)
        }
        log.info("activity:KBHardReset level=\(String(format:"%.4f", kbSnapshotLevel)) auto=\(kbSnapshotAutoEnabled)")
    }

    private func hardResetKBToLevel(_ level: Float) {
        driver.setLevel(level)
        driver.setIdleDimmingSuspended(false)
    }
}
