import Foundation
import CoreGraphics
import os
@testable import ResponseKit

/// Test double for `DisplayTintDriver`. Records every applyGamma + restore
/// call. Defaults to `isAvailable = true`.
final class MockDisplayTintDriver: DisplayTintDriver, @unchecked Sendable {
    struct GammaRecord: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let r: [Float]
        let g: [Float]
        let b: [Float]
    }

    private struct State: Sendable {
        var available: Bool = true
        var applyGammaHistory: [GammaRecord] = []
        var restoreHistory: [CGDirectDisplayID] = []
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    var isAvailable: Bool { state.withLock { $0.available } }
    func setAvailable(_ value: Bool) { state.withLock { $0.available = value } }

    var applyGammaHistory: [GammaRecord] { state.withLock { $0.applyGammaHistory } }
    var restoreHistory: [CGDirectDisplayID] { state.withLock { $0.restoreHistory } }

    func applyGamma(displayID: CGDirectDisplayID, r: [Float], g: [Float], b: [Float]) {
        state.withLock { s in
            guard s.available else { return }
            s.applyGammaHistory.append(GammaRecord(displayID: displayID, r: r, g: g, b: b))
        }
    }

    func restore(displayID: CGDirectDisplayID) {
        state.withLock { s in
            s.restoreHistory.append(displayID)
        }
    }
}
