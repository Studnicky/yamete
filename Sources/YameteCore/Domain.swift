import AppKit
import Foundation
import os

// MARK: - Vec3

public struct Vec3: Sendable, CustomStringConvertible {
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
    public var x: Float
    public var y: Float
    public var z: Float

    public var magnitude: Float { sqrtf(x*x + y*y + z*z) }

    public var description: String {
        "(\(String(format: "%.3f", x)), \(String(format: "%.3f", y)), \(String(format: "%.3f", z)))"
    }

    public static let zero = Vec3(x: 0, y: 0, z: 0)
}

// MARK: - Impact tier

/// Five-tier impact strength rating derived from normalized 0–1 intensity.
public enum ImpactTier: Int, CaseIterable, Sendable, CustomStringConvertible {
    case tap = 1
    case light = 2
    case medium = 3
    case firm = 4
    case hard = 5

    public var description: String {
        switch self {
        case .tap:    NSLocalizedString("tier_tap_full", comment: "Impact tier: lightest")
        case .light:  NSLocalizedString("tier_light_full", comment: "Impact tier: light")
        case .medium: NSLocalizedString("tier_medium_full", comment: "Impact tier: medium")
        case .firm:   NSLocalizedString("tier_firm_full", comment: "Impact tier: firm")
        case .hard:   NSLocalizedString("tier_hard_full", comment: "Impact tier: hardest")
        }
    }

    /// Maps normalized intensity (0–1) to a tier.
    public static func from(intensity: Float) -> ImpactTier {
        switch intensity {
        case ..<0.20: .tap
        case ..<0.40: .light
        case ..<0.60: .medium
        case ..<0.80: .firm
        default:      .hard
        }
    }
}

// MARK: - Response protocols

/// Plays audio scaled by impact intensity. Returns clip duration.
@MainActor
public protocol AudioResponder {
    @discardableResult
    func play(intensity: Float, volumeMin: Float, volumeMax: Float, deviceUIDs: [String]) -> Double
    func playOnAllDevices(url: URL, volume: Float)
    var longestSoundURL: URL? { get }
}

/// Visual reaction to an impact. Implementations include the full-screen
/// overlay (`ScreenFlash`) and the system notification responder
/// (`NotificationResponder`); both fire from the same dispatch path.
///
/// `flash` is the historical method name kept for source compatibility.
/// Parameter shape is preserved as a flat list rather than a typed request
/// object — the typed-request refactor is tracked separately.
@MainActor
public protocol VisualResponder {
    func flash(intensity: Float, opacityMin: Float, opacityMax: Float, clipDuration: Double, dismissAfter: Double, enabledDisplayIDs: [Int])
}

// MARK: - Type-safe identifiers

/// Uniquely identifies a sensor adapter. Prevents accidental use of display names as dictionary keys.
public struct SensorID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let accelerometer = SensorID("accelerometer")
    public static let microphone = SensorID("microphone")
    public static let headphoneMotion = SensorID("headphone-motion")
}

// MARK: - Display helpers

extension NSScreen {
    /// The CGDirectDisplayID for this screen, or 0 if unavailable.
    public var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map(Int.init) ?? 0
    }
}

// MARK: - Clamping

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Once-only resource cleanup

/// Sendable wrapper that ensures a cleanup action runs exactly once.
/// Resources are consumed on first `perform()` call; subsequent calls are no-ops.
/// `T` must itself be `Sendable` so the lock state is concurrency-safe.
public struct OnceCleanup<T: Sendable>: Sendable {
    private let resources: OSAllocatedUnfairLock<T?>

    public init(_ resources: T) {
        self.resources = OSAllocatedUnfairLock(initialState: resources)
    }

    public func perform(_ action: (T) -> Void) {
        guard let r = resources.withLock({ val -> T? in let v = val; val = nil; return v }) else { return }
        action(r)
    }
}

// MARK: - Bundle resources

public enum BundleResources {
    /// Returns sorted file URLs from a subfolder of the app bundle's Resources directory,
    /// recursively discovering files that match any of the given extensions.
    public static func urls(in subfolder: String, extensions: Set<String>) -> [URL] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let folderPath = resourcePath + "/" + subfolder
        guard let enumerator = FileManager.default.enumerator(atPath: folderPath) else { return [] }
        var results: [URL] = []
        while let file = enumerator.nextObject() as? String {
            let lower = file.lowercased()
            if extensions.contains(where: { lower.hasSuffix("." + $0) }) {
                results.append(URL(fileURLWithPath: folderPath + "/" + file))
            }
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
