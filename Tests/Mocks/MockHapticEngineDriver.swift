import Foundation
import CoreHaptics
import os
@testable import ResponseKit

/// Test double for `HapticEngineDriver`. Default state reports
/// hardware available and accepts all engine + pattern operations.
/// Tests flip `isHardwareAvailable` to exercise the
/// "no Force Touch trackpad" path that the production code
/// previously skipped.
final class MockHapticEngineDriver: HapticEngineDriver, @unchecked Sendable {
    private struct State: Sendable {
        var hardwareAvailable: Bool = true
        var startCalls: Int = 0
        var stopCalls: Int = 0
        var playPatternCalls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    var shouldFailStart: Bool = false
    var startError: Error = MockHapticError.engineStartFailed
    var shouldFailPlay: Bool = false
    var playError: Error = MockHapticError.playbackFailed

    var isHardwareAvailable: Bool {
        get { state.withLock { $0.hardwareAvailable } }
    }
    func setHardwareAvailable(_ value: Bool) {
        state.withLock { $0.hardwareAvailable = value }
    }

    var startCalls: Int { state.withLock { $0.startCalls } }
    var stopCalls: Int { state.withLock { $0.stopCalls } }
    var playPatternCalls: Int { state.withLock { $0.playPatternCalls } }

    func start() async throws {
        state.withLock { $0.startCalls += 1 }
        if shouldFailStart { throw startError }
    }

    func stop() {
        state.withLock { $0.stopCalls += 1 }
    }

    func playPattern(_ pattern: CHHapticPattern) async throws {
        state.withLock { $0.playPatternCalls += 1 }
        if shouldFailPlay { throw playError }
    }
}

enum MockHapticError: Error, Sendable {
    case engineStartFailed
    case playbackFailed
}
