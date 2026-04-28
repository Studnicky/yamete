#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
import CoreGraphics

private let log = AppLog(category: "DisplayTintFlash")

/// Briefly tints the display pink/warm by crushing green and blue gamma channels.
///
/// Hardware boundary: `DisplayTintDriver`. Default initializer wires a
/// `RealDisplayTintDriver` (CoreGraphics). Tests inject a mock that records
/// every gamma table application without affecting the real display.
@MainActor
public final class DisplayTintFlash: ReactiveOutput {
    private let driver: DisplayTintDriver
    private let tableSize: Int = 256

    /// Mirrors driver capability — false on macOS 26+ where the API is
    /// unreliable.
    public var isAvailable: Bool { driver.isAvailable }

    public override init() {
        self.driver = RealDisplayTintDriver()
        super.init()
    }

    public init(driver: DisplayTintDriver) {
        self.driver = driver
        super.init()
    }

    // MARK: - ReactiveOutput lifecycle

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        guard driver.isAvailable else { return false }
        let c = provider.displayTintConfig()
        return c.enabled && c.perReaction[fired.kind] != false
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        guard driver.isAvailable else { return }
        let config = provider.displayTintConfig()
        let displayID = CGMainDisplayID()
        let envelope = Envelope.make(clipDuration: fired.clipDuration, intensity: fired.intensity)
        let maxTint = config.intensity * Double(min(1.0, fired.intensity * multiplier))
        let tickNs = UInt64(1_000_000_000 / 30)
        let start = Date()

        // Identity ramp 0...1 for each channel.
        let identity: [Float] = (0..<tableSize).map { Float($0) / Float(tableSize - 1) }

        log.debug("activity:DisplayTintFlash maxTint=\(String(format:"%.2f",maxTint))")

        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            if t >= envelope.total { break }
            let level = envelope.level(at: t) * maxTint
            var g = identity
            var b = identity
            let gScale = Float(1.0 - level * 0.55)
            let bScale = Float(1.0 - level * 0.65)
            for i in 0..<tableSize {
                g[i] = identity[i] * gScale
                b[i] = identity[i] * bScale
            }
            driver.applyGamma(displayID: displayID, r: identity, g: g, b: b)
            try? await Task.sleep(nanoseconds: tickNs)
        }
    }

    override public func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        driver.restore(displayID: CGMainDisplayID())
        log.debug("activity:DisplayTintFlash restored")
    }

    override public func reset() {
        driver.restore(displayID: CGMainDisplayID())
    }
}
