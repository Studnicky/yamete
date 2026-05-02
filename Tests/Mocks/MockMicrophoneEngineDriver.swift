import Foundation
@preconcurrency import AVFoundation
import os
@testable import SensorKit

/// Test double for `MicrophoneEngineDriver`. All-success defaults so a
/// test that just wants a working driver gets one. Failure paths are
/// driven by `shouldFailStart` + `startError`. The recorded handler
/// can be invoked synchronously via `emit(buffer:)` so tests drive
/// the tap pipeline deterministically.
final class MockMicrophoneEngineDriver: MicrophoneEngineDriver, @unchecked Sendable {
    // Configurable failure injection
    var shouldFailStart: Bool = false
    var startError: Error = MockSensorError.engineStartFailed

    // Configurable input format. Defaults to a valid 48kHz mono float32.
    // When `simulateInvalidFormat` is true, `inputFormat` returns the
    // canonical "no real input" format the adapter is supposed to
    // reject: 1 channel at the lowest sample rate AVAudioFormat will
    // accept, with the channel count zeroed via `setInvalidFormat`.
    private let formatLock = OSAllocatedUnfairLock<AVAudioFormat>(
        initialState: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    )
    var inputFormat: AVAudioFormat {
        get { formatLock.withLock { $0 } }
    }
    func setInputFormat(_ format: AVAudioFormat) {
        formatLock.withLock { $0 = format }
    }

    // Recorded calls
    private let counters = OSAllocatedUnfairLock<Counters>(initialState: .init())
    private struct Counters: Sendable {
        var startCalls = 0
        var stopCalls = 0
        var installTapCalls = 0
        var removeTapCalls = 0
    }

    var startCalls: Int { counters.withLock { $0.startCalls } }
    var stopCalls: Int { counters.withLock { $0.stopCalls } }
    var installTapCalls: Int { counters.withLock { $0.installTapCalls } }
    var removeTapCalls: Int { counters.withLock { $0.removeTapCalls } }

    // Captured tap handler
    private let tapHandler = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    func installTap(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        counters.withLock { $0.installTapCalls += 1 }
        tapHandler.withLock { $0 = handler }
    }

    func removeTap() {
        counters.withLock { $0.removeTapCalls += 1 }
        tapHandler.withLock { $0 = nil }
    }

    func start() throws {
        counters.withLock { $0.startCalls += 1 }
        if shouldFailStart { throw startError }
    }

    func stop() {
        counters.withLock { $0.stopCalls += 1 }
    }

    /// Drive a synthetic buffer through the installed tap handler.
    /// No-op if no tap is installed.
    func emit(buffer: AVAudioPCMBuffer) {
        let h = tapHandler.withLock { $0 }
        h?(buffer)
    }
}

enum MockSensorError: Error, Sendable {
    case engineStartFailed
    case streamMidstreamFailure
}
