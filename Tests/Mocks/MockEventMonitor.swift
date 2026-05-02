import Foundation
import AppKit
import os
@testable import SensorKit

/// Test double for `EventMonitor`. Records every install / remove and
/// retains the handler so tests can fire synthetic events. By default
/// installation succeeds; `shouldFailInstall = true` simulates an
/// installation failure (e.g. accessibility permission missing).
@MainActor
final class MockEventMonitor: EventMonitor {
    struct InstalledMonitor {
        let mask: NSEvent.EventTypeMask
        let handler: (NSEvent) -> Void
    }

    var shouldFailInstall: Bool = false
    private(set) var installed: [ObjectIdentifier: InstalledMonitor] = [:]
    private(set) var removalCount: Int = 0
    private(set) var installCount: Int = 0

    func addGlobalMonitor(matching: NSEvent.EventTypeMask,
                          handler: @escaping (NSEvent) -> Void) -> EventMonitorToken? {
        installCount += 1
        guard !shouldFailInstall else { return nil }
        let token = EventMonitorToken()
        installed[ObjectIdentifier(token)] = InstalledMonitor(mask: matching, handler: handler)
        return token
    }

    func removeMonitor(_ token: EventMonitorToken) {
        if installed.removeValue(forKey: ObjectIdentifier(token)) != nil {
            removalCount += 1
        }
    }

    /// Fire a synthetic event through every monitor whose mask includes
    /// the given type.
    func emit(_ event: NSEvent, ofType type: NSEvent.EventType) {
        let mask = NSEvent.EventTypeMask(rawValue: 1 << UInt64(type.rawValue))
        for (_, monitor) in installed where !monitor.mask.intersection(mask).isEmpty {
            monitor.handler(event)
        }
    }

    var installedCount: Int { installed.count }
}
