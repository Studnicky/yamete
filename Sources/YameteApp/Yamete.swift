#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
#if !RAW_SWIFTC_LUMP
import SensorKit
#endif
#if !RAW_SWIFTC_LUMP
import ResponseKit
#endif
import AppKit
import Foundation
import Observation

private let log = AppLog(category: "Yamete")

/// App-level orchestrator. Owns the reaction bus, every source, every output,
/// and the lifecycle wiring between them. Each output independently subscribes
/// to the bus and pattern-matches reactions it cares about (distributed
/// consumer pattern).
///
/// Lifecycle:
///   `bootstrap()` once at launch — registers the bus enricher, wires sources
///   to the bus, spawns one consume task per output, starts settings observation.
///   On settings changes, sources start/stop themselves to match the user's
///   enabled list. Outputs read settings live in their consume loops, no
///   restart needed.
@MainActor @Observable
public final class Yamete {
    public let settings: SettingsStore
    public let bus: ReactionBus

    // Outputs
    public let audioPlayer = AudioPlayer()
    public let screenFlash = ScreenFlash()
    public let notificationResponder: NotificationResponder
    public let ledFlash = LEDFlash()
    public let menuBarFace = MenuBarFace()

    // Hardware outputs
    public let hapticResponder = HapticResponder()
    public let displayBrightnessFlash = DisplayBrightnessFlash()
    public let displayTintFlash = DisplayTintFlash()
    #if DIRECT_BUILD
    public let volumeSpikeResponder = VolumeSpikeResponder()
    #endif

    // Impact pipeline
    public let fusion = ImpactFusion()
    public let accelerometerSource: AccelerometerSource
    public let microphoneSource: MicrophoneSource
    public let headphoneMotionSource: HeadphoneMotionSource

    // Gyroscope is a direct-publish reaction source (does NOT participate in
    // fusion); declared here so its lifecycle hooks into `rebuildEventSources`
    // alongside trackpad / mouse / keyboard.
    public let gyroscopeSource = GyroscopeSource()
    public let lidAngleSource = LidAngleSource()
    public let ambientLightSource = AmbientLightSource()

    // Event sources
    public let usbSource = USBSource()
    public let powerSource = PowerSource()
    public let audioPeripheralSource = AudioPeripheralSource()
    public let bluetoothSource = BluetoothSource()
    public let thunderboltSource = ThunderboltSource()
    public let displayHotplugSource = DisplayHotplugSource()
    public let sleepWakeSource = SleepWakeSource()
    public let trackpadActivitySource = TrackpadActivitySource()
    public let mouseActivitySource    = MouseActivitySource()
    public let keyboardActivitySource = KeyboardActivitySource()

    public private(set) var sensorError: String?
    public private(set) var activeSensorIDs: Set<SensorID> = []

    private var settingsTask: Task<Void, Never>?
    private var outputTasks: [Task<Void, Never>] = []
    private var lastPushedFusionConfig: FusionConfig?
    private var enabledStimulusSources: Set<String> = []
    private var deviceChangeObserver: (any NSObjectProtocol)?

    public init(settings: SettingsStore) {
        self.settings = settings
        self.bus = ReactionBus()
        self.notificationResponder = NotificationResponder(localeProvider: { [weak settings] in
            settings?.resolvedNotificationLocale ?? (Bundle.main.preferredLocalizations.first ?? "en")
        })
        self.accelerometerSource = AccelerometerSource()
        self.microphoneSource = MicrophoneSource()
        self.headphoneMotionSource = HeadphoneMotionSource()

        fusion.onActiveSourcesChanged = { [weak self] ids in
            self?.activeSensorIDs = ids
        }
        fusion.onError = { [weak self] msg in
            self?.sensorError = msg
        }
        // Apply user sensitivity band as the publish-side gate. The fusion
        // engine emits raw fused intensities; this remaps them into the
        // user's reactive window before any output sees the impact.
        fusion.intensityGate = { [weak settings] raw in
            guard let settings else { return raw }
            return FusedImpact.applySensitivity(
                rawIntensity: raw,
                sensitivityMin: Float(settings.sensitivityMin),
                sensitivityMax: Float(settings.sensitivityMax)
            )
        }

        mouseSourcePresent    = MouseActivitySource.isPresent
        keyboardSourcePresent = KeyboardActivitySource.isPresent

        hapticAvailable           = hapticResponder.hardwareAvailable
        displayBrightnessAvailable = displayBrightnessFlash.isAvailable
        keyboardBacklightAvailable = ledFlash.keyboardBacklightAvailable
        trackpadSourcePresent     = TrackpadActivitySource.isPresent
    }

    /// All sensor sources for first-run device defaults / reconciliation.
    public var allSensorSources: [any SensorSource] {
        [accelerometerSource, microphoneSource, headphoneMotionSource]
    }

    /// True if a non-trackpad pointer device (mouse) is currently connected.
    /// Computed once at init — reflects hardware at launch time.
    public private(set) var mouseSourcePresent: Bool = false
    /// True if a non-SPI keyboard device is connected.
    public private(set) var keyboardSourcePresent: Bool = false
    /// True if a Force Touch trackpad is present (haptic feedback available).
    public private(set) var hapticAvailable: Bool = false
    /// True if DisplayServices.framework loaded and brightness symbols resolved.
    public private(set) var displayBrightnessAvailable: Bool = false
    /// False on macOS 26+ where CGSetDisplayTransferByTable is unreliable.
    public var displayTintAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
    }
    /// True if the keyboard backlight (CoreBrightness) is present.
    public private(set) var keyboardBacklightAvailable: Bool = false
    /// True if a built-in or Magic Trackpad is connected.
    public private(set) var trackpadSourcePresent: Bool = false

    /// Re-queries IOKit for connected pointer/keyboard/trackpad hardware.
    /// Called on panel open and on audio-device-change notifications so the
    /// Stimuli section shows/hides hardware-gated cards correctly at runtime.
    public func refreshHardwarePresence() {
        mouseSourcePresent    = MouseActivitySource.isPresent
        keyboardSourcePresent = KeyboardActivitySource.isPresent
        trackpadSourcePresent = TrackpadActivitySource.isPresent
    }

    #if DEBUG
    /// Test seam: lets integration tests drive every hardware-presence flag
    /// directly without touching real IOKit / DisplayServices probes. Same
    /// pattern as the `_testEmit` seams on stimulus sources. nil arguments
    /// leave the corresponding flag unchanged.
    @MainActor
    internal func _testSetHardwarePresence(
        haptic: Bool? = nil,
        displayBrightness: Bool? = nil,
        keyboardBacklight: Bool? = nil,
        trackpad: Bool? = nil,
        mouse: Bool? = nil,
        keyboard: Bool? = nil
    ) {
        if let v = haptic { hapticAvailable = v }
        if let v = displayBrightness { displayBrightnessAvailable = v }
        if let v = keyboardBacklight { keyboardBacklightAvailable = v }
        if let v = trackpad { trackpadSourcePresent = v }
        if let v = mouse    { mouseSourcePresent = v }
        if let v = keyboard { keyboardSourcePresent = v }
    }
    #endif

    /// All ReactiveOutput instances for shutdown-time cancelAndReset calls.
    /// AudioPlayer is excluded — it holds NSObject/NSSoundDelegate and manages
    /// its own lifetime via the activeSounds pool.
    public var allReactiveOutputs: [ReactiveOutput] {
        var outputs: [ReactiveOutput] = [
            screenFlash, notificationResponder, ledFlash,
            hapticResponder, displayBrightnessFlash, displayTintFlash
        ]
        #if DIRECT_BUILD
        outputs.append(volumeSpikeResponder)
        #endif
        return outputs
    }

    // MARK: - Lifecycle

    /// Wires every output to the bus and starts the source pipelines.
    /// Call once at app launch.
    public func bootstrap() {
        AppLog.debugEnabled = AppLog.supportsDebugLogging && settings.debugLogging
        ledFlash.setUp()
        startOutputs()
        rebuildPipeline()
        startSettingsObservation()
        AudioDeviceManager.startObserving()
        refreshHardwarePresence()
        // The block runs on `.main` OperationQueue but Swift strict-concurrency
        // can't prove that's the MainActor — hop explicitly so refreshHardwarePresence
        // (a @MainActor method) is called from an isolated context.
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: AudioDeviceManager.devicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshHardwarePresence() }
        }
    }

    /// Tears down the pipeline on app quit.
    /// - Cancels all output consumer tasks.
    /// - Cancels the settings observation task.
    /// - Stops the sensor fusion pipeline.
    /// - Closes the reaction bus (finishes all subscriber async streams).
    /// - Restores keyboard brightness to its pre-launch state.
    public func shutdown() {
        if let obs = deviceChangeObserver { NotificationCenter.default.removeObserver(obs) }
        deviceChangeObserver = nil
        for task in outputTasks { task.cancel() }
        outputTasks.removeAll()
        settingsTask?.cancel()
        settingsTask = nil
        fusion.stop()
        let busRef = bus
        Task { await busRef.close() }
        for output in allReactiveOutputs { output.cancelAndReset() }
    }

    private func startOutputs() {
        // Register enricher on the bus: audio selection runs first, duration is
        // resolved once before fan-out. All subscribers receive FiredReaction with
        // identical clipDuration — no per-output duration math needed.
        let player = audioPlayer

        Task { await bus.setEnricher { [weak player] reaction, publishedAt in
            // Sound: dedup-filtered, intensity-matched, random within window.
            // peekSound reads recentlyPlayed but does not write — consume() records on actual playback.
            let selection = await player?.peekSound(intensity: reaction.intensity, reaction: reaction)
            let soundURL = selection?.url
            let clipDuration = selection?.duration ?? ReactionsConfig.eventResponseDuration

            // Face: one per connected display, scored for recency dedup.
            // faceIndices[0] is the primary display — used by MenuBarFace.
            let screenCount = NSScreen.screens.count
            let faceIndices = await FaceLibrary.shared.selectIndices(count: max(screenCount, 1))

            // publishedAt is stamped by the bus at entry — use it directly so
            // FiredReaction.publishedAt is stable and does not drift with async enrichment time.
            return FiredReaction(reaction: reaction, clipDuration: clipDuration, soundURL: soundURL, faceIndices: faceIndices, publishedAt: publishedAt)
        }}

        // Each output independently subscribes to the bus and pattern-matches
        // reactions it cares about. Per-output × per-event toggle gating
        // happens inside each consume() loop.
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.audioPlayer.consume(from: self.bus, configProvider: self.settings)
        })
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.screenFlash.consume(from: self.bus, configProvider: self.settings)
        })
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.notificationResponder.consume(from: self.bus, configProvider: self.settings)
        })
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ledFlash.consume(from: self.bus, configProvider: self.settings)
        })
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hapticResponder.consume(from: self.bus, configProvider: self.settings)
        })
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.displayBrightnessFlash.consume(from: self.bus, configProvider: self.settings)
        })
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.displayTintFlash.consume(from: self.bus, configProvider: self.settings)
        })
        #if DIRECT_BUILD
        outputTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            await self.volumeSpikeResponder.consume(from: self.bus, configProvider: self.settings)
        })
        #endif
        menuBarFace.consume(from: bus) { [weak settings] in
            settings?.debounce ?? Defaults.debounce
        }
    }

    private func rebuildPipeline() {
        AppLog.debugEnabled = AppLog.supportsDebugLogging && settings.debugLogging
        rebuildSensorPipeline()
        rebuildEventSources()
    }

    private func rebuildSensorPipeline() {
        let enabled = Set(settings.enabledSensorIDs)
        let sources: [any SensorSource] = allSensorSources.filter { enabled.contains($0.id.rawValue) }

        let config = FusionConfig(
            consensusRequired: settings.consensusRequired,
            rearmDuration: settings.debounce
        )
        if config != lastPushedFusionConfig {
            fusion.configure(config)
            lastPushedFusionConfig = config
        }

        let shouldRun = settings.soundEnabled
            || settings.flashEnabled
            || settings.notificationsEnabled
            || settings.ledEnabled
            || settings.hapticEnabled
            || settings.displayBrightnessEnabled
            || settings.displayTintEnabled
            || settings.volumeSpikeEnabled
        if shouldRun && !sources.isEmpty {
            fusion.start(sources: sources, bus: bus)
        } else {
            fusion.stop()
        }
    }

    private func rebuildEventSources() {
        let desired = Set(settings.enabledStimulusSourceIDs)
        guard desired != enabledStimulusSources else { return }

        for sourceID in desired.subtracting(enabledStimulusSources) {
            switch sourceID {
            case SensorID.usb.rawValue:             usbSource.start(publishingTo: bus)
            case SensorID.power.rawValue:           powerSource.start(publishingTo: bus)
            case SensorID.audioPeripheral.rawValue: audioPeripheralSource.start(publishingTo: bus)
            case SensorID.bluetooth.rawValue:       bluetoothSource.start(publishingTo: bus)
            case SensorID.thunderbolt.rawValue:     thunderboltSource.start(publishingTo: bus)
            case SensorID.displayHotplug.rawValue:  displayHotplugSource.start(publishingTo: bus)
            case SensorID.sleepWake.rawValue:       sleepWakeSource.start(publishingTo: bus)
            case SensorID.trackpadActivity.rawValue:
                let tc = settings.trackpadSourceConfig()
                trackpadActivitySource.configure(
                    windowDuration: tc.windowDuration,
                    scrollMin: tc.scrollMin, scrollMax: tc.scrollMax,
                    touchingMin: settings.trackpadTouchingMin, touchingMax: settings.trackpadTouchingMax,
                    slidingMin: settings.trackpadSlidingMin, slidingMax: settings.trackpadSlidingMax,
                    contactMin: tc.contactMin, contactMax: tc.contactMax,
                    tapMin: tc.tapMin, tapMax: tc.tapMax,
                    touchingEnabled: settings.trackpadTouchingEnabled,
                    slidingEnabled: settings.trackpadSlidingEnabled,
                    contactEnabled: settings.trackpadContactEnabled,
                    tappingEnabled: settings.trackpadTappingEnabled,
                    circlingEnabled: settings.trackpadCirclingEnabled
                )
                trackpadActivitySource.start(publishingTo: bus)
            case SensorID.mouseActivity.rawValue:
                mouseActivitySource.configure(scrollThreshold: settings.mouseScrollThreshold)
                mouseActivitySource.start(publishingTo: bus)
            case SensorID.keyboardActivity.rawValue:
                keyboardActivitySource.start(publishingTo: bus)
            case SensorID.gyroscope.rawValue:
                // Gyroscope is direct-publish like trackpad/mouse/keyboard but
                // gates on SPU HID hardware presence. Skip start when the host
                // does not expose a BMI286.
                if AppleSPUDevice.isHardwarePresent() {
                    gyroscopeSource.start(publishingTo: bus)
                }
            case SensorID.lidAngle.rawValue:
                // Lid angle is direct-publish, state-machine over hinge angle.
                // Same SPU-broker hardware-presence gate as gyroscope.
                if AppleSPUDevice.isHardwarePresent() {
                    lidAngleSource.start(publishingTo: bus)
                }
            case SensorID.ambientLight.rawValue:
                // Ambient light is direct-publish over a continuous lux
                // stream. Same SPU-broker hardware-presence gate as
                // gyroscope and lid.
                if AppleSPUDevice.isHardwarePresent() {
                    ambientLightSource.start(publishingTo: bus)
                }
            default: break
            }
        }
        for sourceID in enabledStimulusSources.subtracting(desired) {
            switch sourceID {
            case SensorID.usb.rawValue:             usbSource.stop()
            case SensorID.power.rawValue:           powerSource.stop()
            case SensorID.audioPeripheral.rawValue: audioPeripheralSource.stop()
            case SensorID.bluetooth.rawValue:       bluetoothSource.stop()
            case SensorID.thunderbolt.rawValue:     thunderboltSource.stop()
            case SensorID.displayHotplug.rawValue:  displayHotplugSource.stop()
            case SensorID.sleepWake.rawValue:       sleepWakeSource.stop()
            case SensorID.trackpadActivity.rawValue: trackpadActivitySource.stop()
            case SensorID.mouseActivity.rawValue:    mouseActivitySource.stop()
            case SensorID.keyboardActivity.rawValue: keyboardActivitySource.stop()
            case SensorID.gyroscope.rawValue:        gyroscopeSource.stop()
            case SensorID.lidAngle.rawValue:         lidAngleSource.stop()
            case SensorID.ambientLight.rawValue:     ambientLightSource.stop()
            default: break
            }
        }
        enabledStimulusSources = desired
    }

    private func startSettingsObservation() {
        settingsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let changed = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        guard let self else { return }
                        _ = self.settings.soundEnabled
                        _ = self.settings.flashEnabled
                        _ = self.settings.notificationsEnabled
                        _ = self.settings.ledEnabled
                        _ = self.settings.debugLogging
                        _ = self.settings.enabledSensorIDs
                        _ = self.settings.enabledStimulusSourceIDs
                        _ = self.settings.consensusRequired
                        _ = self.settings.debounce
                    } onChange: {
                        continuation.resume(returning: true)
                    }
                }
                guard changed, let self, !Task.isCancelled else { break }
                self.rebuildPipeline()
            }
        }
    }

    public func playWelcomeSound() {
        guard let url = audioPlayer.longestSoundURL else { return }
        audioPlayer.playOnAllDevices(url: url, volume: 1.0)
    }
}
