#if DIRECT_BUILD
#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import AudioToolbox

private let log = AppLog(category: "VolumeSpikeResponder")

/// Temporarily overrides system output volume to the audio output maximum, then
/// restores. This ensures clips can play at the configured volume level
/// regardless of where the system volume was set.
///
/// Hardware boundary: `SystemVolumeDriver`. Default initializer wires a
/// `RealSystemVolumeDriver` (CoreAudio). Tests inject a mock that lets tests
/// capture original values + verify spike + restore semantics. Direct build only.
@MainActor
public final class VolumeSpikeResponder: ReactiveOutput {
    private let driver: SystemVolumeDriver
    private var originalVolume: Float?

    public override init() {
        self.driver = RealSystemVolumeDriver()
        super.init()
    }

    public init(driver: SystemVolumeDriver) {
        self.driver = driver
        super.init()
    }

    // MARK: - ReactiveOutput lifecycle

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        let spike = provider.volumeSpikeConfig()
        let audio = provider.audioConfig()
        // Intensity threshold gate: reactions weaker than the configured
        // `volumeSpikeThreshold` skip the override entirely so light taps
        // don't unexpectedly raise the system volume.
        let intensityOK = Double(fired.intensity) >= spike.threshold
        return spike.enabled && audio.enabled && intensityOK
            && audio.perReaction[fired.kind] != false
    }

    override public func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        // Capture the system volume EXACTLY ONCE per pulse sequence. If a
        // rapid second reaction fires while the spike is still active, the
        // current driver volume IS the spike target — re-capturing here
        // would corrupt the restore value. Postaction clears `originalVolume`
        // so the next genuinely-new sequence re-captures the live level.
        guard originalVolume == nil else {
            log.debug("activity:VolumeOverride preAction reentrant — keeping originalVolume=\(String(format:"%.2f", originalVolume ?? -1))")
            return
        }
        originalVolume = driver.getVolume()
        log.debug("activity:VolumeOverride captured original=\(String(format:"%.2f", originalVolume ?? -1))")
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        let targetVolume = min(1.0, Float(provider.audioConfig().volumeMax) * multiplier)
        driver.setVolume(targetVolume)
        log.debug("activity:VolumeOverride target=\(String(format:"%.2f",targetVolume))")
        try? await Task.sleep(for: .seconds(fired.clipDuration))
    }

    override public func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        if let v = originalVolume {
            driver.setVolume(v)
            log.debug("activity:VolumeSpike restored=\(String(format:"%.2f",v))")
        }
        originalVolume = nil
    }

    override public func reset() {
        if let v = originalVolume {
            driver.setVolume(v)
            log.debug("activity:VolumeSpike reset=\(String(format:"%.2f",v))")
        }
        originalVolume = nil
    }
}
#endif
