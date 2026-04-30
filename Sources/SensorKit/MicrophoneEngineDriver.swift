#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import AVFoundation
import Foundation

// MARK: - Microphone engine driver protocol
//
// Abstracts the AVAudioEngine + AVAudioInputNode pair used by
// `MicrophoneSource`. The protocol captures the surface area the
// adapter needs: install/remove a tap, query the input format, and
// drive start / stop. The real implementation talks to AVFoundation
// directly. Tests inject a mock that records calls and lets them
// synthesize buffers through the installed tap handler.
//
// Lifecycle contract:
//   - `inputFormat` is consulted before `installTap`. The adapter
//     fails fast if the format is invalid (no channels / zero rate).
//   - `installTap(handler:)` registers the per-buffer callback. The
//     handler is invoked on an audio-thread by real CoreAudio; for
//     mocks it is invoked synchronously by `emit(buffer:)`.
//   - `start()` may throw. On throw the adapter performs `removeTap`
//     and surfaces `SensorError.permissionDenied` to its consumer.
//   - `stop()` is unconditional; idempotent in real CoreAudio. Mocks
//     count calls.
//   - `removeTap()` is unconditional and idempotent. Real CoreAudio
//     no-ops if no tap is installed.
//
// Each `MicrophoneSource.impacts()` invocation requests a fresh
// driver from its factory because AVAudioEngine instances are not
// reusable after stop+restart on every macOS version.

public protocol MicrophoneEngineDriver: AnyObject, Sendable {
    /// Native input format. Channel count and sample rate must both
    /// be > 0 for the adapter to proceed past format validation.
    var inputFormat: AVAudioFormat { get }

    /// Install a per-buffer callback. The buffer is owned by the
    /// caller (CoreAudio) and must be consumed within the closure.
    /// At most one tap is installed at a time per driver instance.
    func installTap(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void)

    /// Remove the currently installed tap. Idempotent.
    func removeTap()

    /// Start the engine. May throw if the underlying engine cannot
    /// start (permission denied, audio HAL failure, etc.).
    func start() throws

    /// Stop the engine. Idempotent.
    func stop()
}

// MARK: - Real implementation

/// Production AVAudioEngine-backed driver. Owns one engine + input
/// node per instance.
public final class RealMicrophoneEngineDriver: MicrophoneEngineDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: AVAudioEngine and
    // AVAudioInputNode are `@preconcurrency` imported and not
    // formally `Sendable`. The adapter owns a single driver per
    // `impacts()` call, never shares it across tasks, and only
    // touches it from the consumer task that built it. The audio
    // tap callback is the only escape, and it captures only the
    // sendable `handler` closure passed in.
    private let engine: AVAudioEngine
    private let inputNode: AVAudioInputNode
    private let bufferSize: AVAudioFrameCount

    public init(bufferSize: AVAudioFrameCount? = nil) {
        let e = AVAudioEngine()
        self.engine = e
        self.inputNode = e.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // If caller didn't specify, use the same default the adapter
        // historically used: sampleRate / Mic.targetHz frames.
        if let bufferSize {
            self.bufferSize = bufferSize
        } else if format.sampleRate > 0 {
            self.bufferSize = AVAudioFrameCount(format.sampleRate / Detection.Mic.targetHz)
        } else {
            self.bufferSize = 1024
        }
    }

    public var inputFormat: AVAudioFormat {
        inputNode.outputFormat(forBus: 0)
    }

    public func installTap(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let format = inputFormat
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer)
        }
    }

    public func removeTap() {
        inputNode.removeTap(onBus: 0)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }
}
