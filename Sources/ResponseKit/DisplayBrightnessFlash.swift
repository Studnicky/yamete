#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import CoreGraphics

private let log = AppLog(category: "DisplayBrightnessFlash")

/// Spikes display brightness above the user's current level on hard impact,
/// then restores it over the Envelope fade-out window.
///
/// Hardware boundary: `DisplayBrightnessDriver`. Default initializer wires a
/// `RealDisplayBrightnessDriver` (DisplayServices.framework). Tests inject a
/// mock that records every `set` and returns canned values from `get`.
@MainActor
public final class DisplayBrightnessFlash: ReactiveOutput {
    private let driver: DisplayBrightnessDriver
    private var originalBrightness: Float = 0.8

    public override init() {
        self.driver = RealDisplayBrightnessDriver()
        super.init()
    }

    public init(driver: DisplayBrightnessDriver) {
        self.driver = driver
        super.init()
    }

    /// True if the underlying driver loaded its symbols.
    public var isAvailable: Bool { driver.isAvailable }

    // MARK: - ReactiveOutput lifecycle

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        let c = provider.displayBrightnessConfig()
        return c.enabled && c.perReaction[fired.kind] != false
            && Double(fired.intensity) >= c.threshold
    }

    override public func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        guard driver.isAvailable else { return }
        if let captured = driver.get(displayID: CGMainDisplayID()) {
            originalBrightness = captured
        }
        log.debug("activity:DisplayBrightnessFlash captured original=\(String(format:"%.2f",originalBrightness))")
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        guard driver.isAvailable else { return }
        let config = provider.displayBrightnessConfig()
        let peak = Float(min(1.0, Double(originalBrightness) + config.boost * Double(min(1.0, fired.intensity * multiplier))))
        let envelope = Envelope.make(clipDuration: fired.clipDuration, intensity: fired.intensity)
        let tickNs = UInt64(1_000_000_000 / 30)
        let displayID = CGMainDisplayID()
        let start = Date()

        log.debug("activity:DisplayBrightnessFlash original=\(String(format:"%.2f",originalBrightness)) peak=\(String(format:"%.2f",peak))")

        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            if t >= envelope.total { break }
            let level = Float(envelope.level(at: t))
            let brightness = originalBrightness + (peak - originalBrightness) * level
            driver.set(displayID: displayID, level: brightness)
            try? await Task.sleep(nanoseconds: tickNs)
        }
    }

    override public func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        driver.set(displayID: CGMainDisplayID(), level: originalBrightness)
        log.debug("activity:DisplayBrightnessFlash restored=\(String(format:"%.2f",originalBrightness))")
    }

    override public func reset() {
        driver.set(displayID: CGMainDisplayID(), level: originalBrightness)
    }
}
