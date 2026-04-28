#if canImport(YameteCore)
import YameteCore
#endif
@preconcurrency import AVFoundation
import Foundation
import os

private let log = AppLog(category: "Microphone")

// MARK: - Microphone Adapter
//
// Detects impact transients via the built-in or external microphone using
// AVAudioEngine. Runs its own detection pipeline:
// per-buffer peak → DC-blocking HP filter → ImpactDetector gates → SensorImpact.
//
// Works on all Macs (not just Apple Silicon). Requires microphone permission
// (com.apple.security.device.audio-input entitlement under App Sandbox).
//
// Hardware boundary: `MicrophoneEngineDriver`. The default factory creates a
// `RealMicrophoneEngineDriver` (AVAudioEngine-backed). Tests inject a mock
// driver factory that returns a recording stub.
//
// Public API documentation:
//   https://developer.apple.com/documentation/avfaudio/avaudioengine
//   https://developer.apple.com/documentation/avfaudio/avaudioinputnode
//   https://developer.apple.com/documentation/avfaudio/avaudioinputnode/1390585-installtap
//   https://developer.apple.com/documentation/avfoundation/avcapturedevice

/// Detects impact transients via microphone audio using AVAudioEngine.
/// Works on all Macs. Requires microphone permission (audio-input entitlement).
public final class MicrophoneSource: SensorSource, @unchecked Sendable {

    public let id = SensorID.microphone
    public let name = "Microphone"

    /// Microphone detection config: thresholds in HP-filtered PCM amplitude units.
    /// Floor: quiet ambient (~0.005). Ceiling: firm desk slap (~0.300).
    public let detectorConfig: ImpactDetectorConfig

    /// Driver factory. Each `impacts()` call requests a fresh driver
    /// because AVAudioEngine instances are not reliably reusable
    /// across stop+restart cycles on every macOS version. Default
    /// produces a `RealMicrophoneEngineDriver`. Tests substitute a
    /// closure that returns a mock.
    private let driverFactory: @Sendable () -> MicrophoneEngineDriver

    /// Optional availability override. When `nil` the adapter falls
    /// back to `AVCaptureDevice.default(for: .audio)`. Tests inject a
    /// constant via this hook so `isAvailable` can be controlled
    /// without touching real audio hardware.
    private let availabilityOverride: (@Sendable () -> Bool)?

    public convenience init(detectorConfig: ImpactDetectorConfig = .microphone()) {
        self.init(
            detectorConfig: detectorConfig,
            driverFactory: { RealMicrophoneEngineDriver() },
            availabilityOverride: nil
        )
    }

    public init(
        detectorConfig: ImpactDetectorConfig = .microphone(),
        driverFactory: @escaping @Sendable () -> MicrophoneEngineDriver,
        availabilityOverride: (@Sendable () -> Bool)? = nil
    ) {
        self.detectorConfig = detectorConfig
        self.driverFactory = driverFactory
        self.availabilityOverride = availabilityOverride
    }

    public var isAvailable: Bool {
        if let availabilityOverride { return availabilityOverride() }
        return AVCaptureDevice.default(for: .audio) != nil
    }

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let adapterID = self.id
        let detector = ImpactDetector(config: detectorConfig, adapterName: name)

        let driver = driverFactory()
        let format = driver.inputFormat

        // Input format validity gate. A freshly-constructed AVAudioEngine on
        // a host with no real audio input (headless CI runner, container,
        // virtualized macOS) can report a zero-channel or zero-sample-rate
        // format. Calling `installTap` with such a format produces undefined
        // behavior in CoreAudio — observed as SIGSEGV during `swift test`
        // teardown on CI run 24548266785. Fail fast with a typed error
        // instead of touching the tap machinery at all.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            log.error("activity:SensorReading wasInvalidatedBy agent:MicrophoneAdapter — invalid input format (channels=\(format.channelCount) sampleRate=\(format.sampleRate))")
            continuation.finish(throwing: SensorError.deviceNotFound)
            return stream
        }

        // Per-stream filter state captured by the tap handler.
        let filterState = FilterState()
        let hpAlpha = Detection.Mic.hpAlpha

        driver.installTap { buffer in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var peak: Float = 0
            for i in 0..<frameLength {
                let v = Swift.abs(channelData[i])
                if v > peak { peak = v }
            }

            // DC-blocking high-pass
            let (filtered, _) = filterState.step(peak: peak, alpha: hpAlpha)
            let magnitude = Swift.abs(filtered)

            // Run detector — returns 0-1 intensity if impact detected
            let now = Date()
            if let intensity = detector.process(magnitude: magnitude, timestamp: now) {
                continuation.yield(SensorImpact(source: adapterID, timestamp: now, intensity: intensity))
            }
        }

        do {
            try driver.start()
            log.info("activity:SensorReading wasStartedBy agent:MicrophoneAdapter")
        } catch {
            log.error("activity:SensorReading wasInvalidatedBy agent:MicrophoneAdapter — \(error.localizedDescription)")
            // engine.start() failed — we already have a tap installed. Pair
            // the removal with the start-failure branch so we don't leak a
            // tap + continue into an undefined state.
            driver.removeTap()
            continuation.finish(throwing: SensorError.permissionDenied)
            return stream
        }

        let cleanup = OnceCleanup(driver)
        continuation.onTermination = { @Sendable _ in
            cleanup.perform { d in
                // Teardown order matters. `engine.stop()` blocks until the
                // audio unit has drained in-flight tap callbacks; removing
                // the tap first can race with a buffer still being processed
                // on the audio thread and dereference state captured by the
                // tap closure after it's been torn down. Observed as SIGSEGV
                // during `swift test` on CI run 24548266785.
                d.stop()
                d.removeTap()
            }
            log.info("activity:SensorReading wasEndedBy agent:MicrophoneAdapter")
        }

        return stream
    }
}

// MARK: - Per-stream filter state
//
// The HP filter holds two `Float`s of state across consecutive tap
// callbacks. CoreAudio invokes the tap on a real-time audio thread,
// so the state lives behind a `OSAllocatedUnfairLock` to satisfy
// strict concurrency. Lock contention is irrelevant here because the
// tap thread is the only writer.
private final class FilterState: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(prevRaw: Float, prevFiltered: Float)>(initialState: (0, 0))

    func step(peak: Float, alpha: Float) -> (filtered: Float, prevRaw: Float) {
        state.withLock { s in
            let filtered = alpha * (s.prevFiltered + peak - s.prevRaw)
            s.prevRaw = peak
            s.prevFiltered = filtered
            return (filtered, s.prevRaw)
        }
    }
}
