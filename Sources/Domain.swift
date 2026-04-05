import AppKit
import Foundation

// MARK: - Vec3

struct Vec3: Sendable, CustomStringConvertible {
    var x: Float
    var y: Float
    var z: Float

    var magnitude: Float { sqrtf(x*x + y*y + z*z) }

    var description: String {
        "(\(String(format: "%.3f", x)), \(String(format: "%.3f", y)), \(String(format: "%.3f", z)))"
    }

    static let zero = Vec3(x: 0, y: 0, z: 0)
}

// MARK: - Impact tier

/// Five-tier impact strength rating derived from normalized 0–1 intensity.
enum ImpactTier: Int, CaseIterable, Sendable, CustomStringConvertible {
    case tap = 1
    case light = 2
    case medium = 3
    case firm = 4
    case hard = 5

    var description: String {
        switch self {
        case .tap:    "Tap"
        case .light:  "Light"
        case .medium: "Medium"
        case .firm:   "Firm"
        case .hard:   "Hard"
        }
    }

    /// Maps normalized intensity (0–1) to a tier.
    static func from(intensity: Float) -> ImpactTier {
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
protocol AudioResponder {
    @discardableResult
    func play(intensity: Float, volumeMin: Float, volumeMax: Float, deviceUIDs: [String]) -> Double
    func playOnAllDevices(url: URL, volume: Float)
    var longestSoundURL: URL? { get }
}

/// Flashes screen overlay scaled by impact intensity.
@MainActor
protocol FlashResponder {
    func flash(intensity: Float, opacityMin: Float, opacityMax: Float, clipDuration: Double, enabledDisplayIDs: [Int])
}

// MARK: - Display helpers

extension NSScreen {
    /// The CGDirectDisplayID for this screen, or 0 if unavailable.
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map(Int.init) ?? 0
    }
}

// MARK: - Clamping

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Bundle resources

enum BundleResources {
    /// Returns sorted file URLs from a subfolder of the app bundle's Resources directory,
    /// recursively discovering files that match any of the given extensions.
    static func urls(in subfolder: String, extensions: Set<String>) -> [URL] {
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

