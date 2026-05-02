import Foundation
import os
@testable import SensorKit

/// Test double for `HIDDeviceMonitor`. Tests configure
/// `cannedDevices` (returned regardless of matcher) or
/// `matcherResults` (per-matcher canned response). The default returns
/// no devices and reports no built-in display.
final class MockHIDDeviceMonitor: HIDDeviceMonitor, @unchecked Sendable {
    private struct State: Sendable {
        var cannedDevices: [HIDDeviceInfo] = []
        var matcherResults: [HIDMatcher: [HIDDeviceInfo]] = [:]
        var hasBuiltInDisplay: Bool = false
        var queryHistory: [[HIDMatcher]] = []
        var hasBuiltInDisplayCalls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    func setCannedDevices(_ devices: [HIDDeviceInfo]) {
        state.withLock { $0.cannedDevices = devices }
    }

    func setMatcherResult(_ matcher: HIDMatcher, devices: [HIDDeviceInfo]) {
        state.withLock { $0.matcherResults[matcher] = devices }
    }

    func setHasBuiltInDisplay(_ value: Bool) {
        state.withLock { $0.hasBuiltInDisplay = value }
    }

    var queryHistory: [[HIDMatcher]] { state.withLock { $0.queryHistory } }
    var hasBuiltInDisplayCalls: Int { state.withLock { $0.hasBuiltInDisplayCalls } }

    func queryDevices(matchers: [HIDMatcher]) -> [HIDDeviceInfo] {
        state.withLock { s in
            s.queryHistory.append(matchers)
            // If any matcher has a per-matcher canned result, union them.
            // Otherwise return the global canned list.
            var matched: [HIDDeviceInfo] = []
            var anyPerMatcher = false
            for matcher in matchers {
                if let r = s.matcherResults[matcher] {
                    anyPerMatcher = true
                    matched.append(contentsOf: r)
                }
            }
            if anyPerMatcher { return matched }
            return s.cannedDevices
        }
    }

    func hasBuiltInDisplay() -> Bool {
        state.withLock { s in
            s.hasBuiltInDisplayCalls += 1
            return s.hasBuiltInDisplay
        }
    }
}
