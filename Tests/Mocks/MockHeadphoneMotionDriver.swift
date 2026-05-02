import Foundation
import os
@testable import SensorKit

/// Test double for `HeadphoneMotionDriver`. The mock starts in
/// "framework supports motion / no headphones connected" state.
/// Tests flip `isDeviceMotionAvailable` to simulate unsupported
/// hosts and `isHeadphonesConnected` to simulate connect /
/// disconnect events. `emit(sample:)` and `emit(error:)` drive the
/// captured handler synchronously.
final class MockHeadphoneMotionDriver: HeadphoneMotionDriver, @unchecked Sendable {
    private struct State: Sendable {
        var deviceMotionAvailable = true
        var headphonesConnected = false
        var startUpdatesCalls = 0
        var stopUpdatesCalls = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())
    private let handler = OSAllocatedUnfairLock<(@Sendable (HeadphoneMotionSample?, Error?) -> Void)?>(initialState: nil)

    var isDeviceMotionAvailable: Bool {
        get { state.withLock { $0.deviceMotionAvailable } }
    }
    func setDeviceMotionAvailable(_ value: Bool) {
        state.withLock { $0.deviceMotionAvailable = value }
    }

    var isHeadphonesConnected: Bool {
        get { state.withLock { $0.headphonesConnected } }
    }
    func setHeadphonesConnected(_ value: Bool) {
        state.withLock { $0.headphonesConnected = value }
    }

    var startUpdatesCalls: Int { state.withLock { $0.startUpdatesCalls } }
    var stopUpdatesCalls: Int { state.withLock { $0.stopUpdatesCalls } }

    func startUpdates(handler: @escaping @Sendable (HeadphoneMotionSample?, Error?) -> Void) {
        state.withLock { $0.startUpdatesCalls += 1 }
        self.handler.withLock { $0 = handler }
    }

    func stopUpdates() {
        state.withLock { $0.stopUpdatesCalls += 1 }
        self.handler.withLock { $0 = nil }
    }

    /// Push a synthetic motion sample through the installed handler.
    func emit(sample: HeadphoneMotionSample) {
        let h = handler.withLock { $0 }
        h?(sample, nil)
    }

    /// Push an error through the installed handler.
    func emit(error: Error) {
        let h = handler.withLock { $0 }
        h?(nil, error)
    }

    /// Convenience: simulate a sharp impact strong enough to clear
    /// the default headphone-motion intensity floor (0.05g).
    func emitImpact(magnitude: Double = 1.5) {
        emit(sample: HeadphoneMotionSample(x: magnitude, y: 0, z: 0))
    }
}
