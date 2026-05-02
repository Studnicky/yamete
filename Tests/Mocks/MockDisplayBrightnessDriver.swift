import Foundation
import CoreGraphics
import os
@testable import ResponseKit

/// Test double for `DisplayBrightnessDriver`. Defaults: available, current
/// level = 0.5. Tests flip `isAvailable` and the canned level so the
/// flash output observes the desired hardware path.
final class MockDisplayBrightnessDriver: DisplayBrightnessDriver, @unchecked Sendable {
    private struct State: Sendable {
        var available: Bool = true
        var canned: [CGDirectDisplayID: Float] = [:]
        var defaultLevel: Float? = 0.5
        var setHistory: [(displayID: CGDirectDisplayID, level: Float)] = []
        var getCalls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    var isAvailable: Bool { state.withLock { $0.available } }
    func setAvailable(_ value: Bool) { state.withLock { $0.available = value } }

    func setCannedLevel(_ level: Float?, displayID: CGDirectDisplayID? = nil) {
        state.withLock { s in
            if let displayID, let level { s.canned[displayID] = level }
            else { s.defaultLevel = level }
        }
    }

    var setHistory: [(displayID: CGDirectDisplayID, level: Float)] { state.withLock { $0.setHistory } }
    var getCalls: Int { state.withLock { $0.getCalls } }

    func get(displayID: CGDirectDisplayID) -> Float? {
        state.withLock { s in
            s.getCalls += 1
            guard s.available else { return nil }
            return s.canned[displayID] ?? s.defaultLevel
        }
    }

    func set(displayID: CGDirectDisplayID, level: Float) {
        state.withLock { s in
            guard s.available else { return }
            s.setHistory.append((displayID, level))
            s.canned[displayID] = level
        }
    }
}
