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
// Public API documentation:
//   https://developer.apple.com/documentation/avfaudio/avaudioengine
//   https://developer.apple.com/documentation/avfaudio/avaudioinputnode
//   https://developer.apple.com/documentation/avfaudio/avaudioinputnode/1390585-installtap
//   https://developer.apple.com/documentation/avfoundation/avcapturedevice

/// Detects impact transients via microphone audio using AVAudioEngine.
/// Works on all Macs. Requires microphone permission (audio-input entitlement).
public final class MicrophoneAdapter: SensorAdapter, Sendable {

    public let id = SensorID.microphone
    public let name = "Microphone"

    /// Microphone detection config: thresholds in HP-filtered PCM amplitude units.
    /// Floor: quiet ambient (~0.005). Ceiling: firm desk slap (~0.300).
    public let detectorConfig: ImpactDetectorConfig

    public init(detectorConfig: ImpactDetectorConfig = .microphone()) {
        self.detectorConfig = detectorConfig
    }

    public var isAvailable: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    public func impacts() -> AsyncThrowingStream<SensorImpact, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SensorImpact.self)
        let adapterID = self.id
        let detector = ImpactDetector(config: detectorConfig, adapterName: name)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

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

        let bufferSize = AVAudioFrameCount(format.sampleRate / Detection.Mic.targetHz)

        var prevRaw: Float = 0
        var prevFiltered: Float = 0
        let hpAlpha = Detection.Mic.hpAlpha

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var peak: Float = 0
            for i in 0..<frameLength {
                let v = Swift.abs(channelData[i])
                if v > peak { peak = v }
            }

            // DC-blocking high-pass
            let filtered = hpAlpha * (prevFiltered + peak - prevRaw)
            prevRaw = peak
            prevFiltered = filtered

            let magnitude = Swift.abs(filtered)

            // Run detector — returns 0-1 intensity if impact detected
            let now = Date()
            if let intensity = detector.process(magnitude: magnitude, timestamp: now) {
                continuation.yield(SensorImpact(source: adapterID, timestamp: now, intensity: intensity))
            }
        }

        do {
            try engine.start()
            log.info("activity:SensorReading wasStartedBy agent:MicrophoneAdapter")
        } catch {
            log.error("activity:SensorReading wasInvalidatedBy agent:MicrophoneAdapter — \(error.localizedDescription)")
            // engine.start() failed — we already have a tap installed. Pair
            // the removal with the start-failure branch so we don't leak a
            // tap + continue into an undefined state.
            inputNode.removeTap(onBus: 0)
            continuation.finish(throwing: SensorError.permissionDenied)
            return stream
        }

        let cleanup = OnceCleanup((engine: engine, node: inputNode))
        continuation.onTermination = { @Sendable _ in
            cleanup.perform { r in
                // Teardown order matters. `engine.stop()` blocks until the
                // audio unit has drained in-flight tap callbacks; removing
                // the tap first can race with a buffer still being processed
                // on the audio thread and dereference state captured by the
                // tap closure after it's been torn down. Observed as SIGSEGV
                // during `swift test` on CI run 24548266785.
                r.engine.stop()
                r.node.removeTap(onBus: 0)
            }
            log.info("activity:SensorReading wasEndedBy agent:MicrophoneAdapter")
        }

        return stream
    }
}
