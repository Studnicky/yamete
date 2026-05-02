import Foundation
import os
@testable import ResponseKit

/// Test double for `LEDBrightnessDriver`. Defaults: keyboard backlight
/// available, Caps Lock access granted, current level = 0.5, auto enabled.
/// Tests flip the flags to drive availability + permission paths.
final class MockLEDBrightnessDriver: LEDBrightnessDriver, @unchecked Sendable {
    private struct State: Sendable {
        var keyboardBacklightAvailable: Bool = true
        var capsLockAccessGranted: Bool = true
        var currentLevel: Float? = 0.5
        var autoEnabled: Bool = true

        // Recorded calls
        var setLevelHistory: [Float] = []
        var setAutoHistory: [Bool] = []
        var setIdleSuspendedHistory: [Bool] = []
        var capsLockHistory: [Bool] = []
        var currentLevelCalls: Int = 0
        var isAutoEnabledCalls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    var keyboardBacklightAvailable: Bool {
        get { state.withLock { $0.keyboardBacklightAvailable } }
    }
    func setKeyboardBacklightAvailable(_ value: Bool) {
        state.withLock { $0.keyboardBacklightAvailable = value }
    }

    var capsLockAccessGranted: Bool {
        get { state.withLock { $0.capsLockAccessGranted } }
    }
    func setCapsLockAccessGranted(_ value: Bool) {
        state.withLock { $0.capsLockAccessGranted = value }
    }

    func setCurrentLevel(_ value: Float?) { state.withLock { $0.currentLevel = value } }
    /// Stage the value returned by `isAutoEnabled()`. Distinct from the
    /// protocol's `setAutoEnabled(_:)` write method.
    func stageAutoEnabled(_ value: Bool) { state.withLock { $0.autoEnabled = value } }

    var setLevelHistory: [Float] { state.withLock { $0.setLevelHistory } }
    var setAutoHistory: [Bool] { state.withLock { $0.setAutoHistory } }
    var setIdleSuspendedHistory: [Bool] { state.withLock { $0.setIdleSuspendedHistory } }
    var capsLockHistory: [Bool] { state.withLock { $0.capsLockHistory } }
    var currentLevelCalls: Int { state.withLock { $0.currentLevelCalls } }
    var isAutoEnabledCalls: Int { state.withLock { $0.isAutoEnabledCalls } }

    func currentLevel() -> Float? {
        state.withLock { s in
            s.currentLevelCalls += 1
            return s.keyboardBacklightAvailable ? s.currentLevel : nil
        }
    }

    func setLevel(_ level: Float) {
        state.withLock { s in
            guard s.keyboardBacklightAvailable else { return }
            s.setLevelHistory.append(level)
            s.currentLevel = level
        }
    }

    func isAutoEnabled() -> Bool {
        state.withLock { s in
            s.isAutoEnabledCalls += 1
            return s.autoEnabled
        }
    }

    func setAutoEnabled(_ enabled: Bool) {
        state.withLock { s in
            guard s.keyboardBacklightAvailable else { return }
            s.setAutoHistory.append(enabled)
            s.autoEnabled = enabled
        }
    }

    func setIdleDimmingSuspended(_ suspended: Bool) {
        state.withLock { s in
            guard s.keyboardBacklightAvailable else { return }
            s.setIdleSuspendedHistory.append(suspended)
        }
    }

    func capsLockSet(_ on: Bool) {
        state.withLock { s in
            guard s.capsLockAccessGranted else { return }
            s.capsLockHistory.append(on)
        }
    }
}
