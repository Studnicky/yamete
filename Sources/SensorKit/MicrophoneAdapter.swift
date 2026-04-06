#if canImport(YameteCore)
import YameteCore
#endif
@preconcurrency import AVFoundation
import Foundation

private let log = AppLog(category: "Microphone")

// MARK: - Microphone Adapter
//
// Detects impact transients via the built-in or external microphone using
// AVAudioEngine (fully public API). Runs its own detection pipeline:
// per-buffer peak → DC-blocking HP filter → ImpactDetector gates → SensorImpact.

/// Detects impact transients via microphone audio using AVAudioEngine.
/// Works on all Macs. Requires microphone permission (audio-input entitlement).
public final class MicrophoneAdapter: SensorAdapter, @unchecked Sendable {

    public let id = SensorID("microphone")
    public let name = "Microphone"
    public let apiClassification: APIClassification = .publicAPI

    /// Microphone detection config: thresholds in HP-filtered PCM amplitude units.
    /// Floor: quiet ambient (~0.005). Ceiling: firm desk slap (~0.300).
    private let detectorConfig = ImpactDetectorConfig(
        spikeThreshold: 0.02,
        minRiseRate: 0.01,
        minCrestFactor: 1.5,
        minConfirmations: 2,
        warmupSamples: 50,
        intensityFloor: 0.005,
        intensityCeiling: 0.300
    )

    public init() {}

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
        let targetHz: Double = 50
        let bufferSize = AVAudioFrameCount(format.sampleRate / targetHz)

        // DC-blocking high-pass state
        var prevRaw: Float = 0
        var prevFiltered: Float = 0
        let hpAlpha: Float = 0.95

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
            log.info("activity:SensorReading wasStartedBy agent:MicrophoneAdapter sampleRate=\(format.sampleRate) bufferSize=\(bufferSize)")
        } catch {
            log.error("activity:SensorReading wasInvalidatedBy agent:MicrophoneAdapter — \(error.localizedDescription)")
            continuation.finish(throwing: SensorError.permissionDenied)
            return stream
        }

        let cleanup = AudioCleanup(engine: engine, inputNode: inputNode)
        continuation.onTermination = { @Sendable _ in
            cleanup.perform()
            log.info("activity:SensorReading wasEndedBy agent:MicrophoneAdapter")
        }

        return stream
    }
}

private struct AudioCleanup: @unchecked Sendable {
    let engine: AVAudioEngine
    let inputNode: AVAudioInputNode
    func perform() { inputNode.removeTap(onBus: 0); engine.stop() }
}
