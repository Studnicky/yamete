import Foundation
import os
@testable import ResponseKit

/// Test double for `SystemVolumeDriver`. Defaults: getVolume returns 0.4.
/// Tests flip `cannedVolume` to nil to drive the "no output device" path.
final class MockSystemVolumeDriver: SystemVolumeDriver, @unchecked Sendable {
    private struct State: Sendable {
        var canned: Float? = 0.4
        var setHistory: [Float] = []
        var getCalls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    func setCannedVolume(_ value: Float?) {
        state.withLock { $0.canned = value }
    }

    var setHistory: [Float] { state.withLock { $0.setHistory } }
    var getCalls: Int { state.withLock { $0.getCalls } }
    var lastSet: Float? { state.withLock { $0.setHistory.last } }

    func getVolume() -> Float? {
        state.withLock { s in
            s.getCalls += 1
            return s.canned
        }
    }

    func setVolume(_ volume: Float) {
        state.withLock { s in
            s.setHistory.append(volume)
            s.canned = volume
        }
    }
}
