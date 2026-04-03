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

// MARK: - ImpactEvent

struct ImpactEvent: Sendable {
    let timestamp: Date
    let amplitude: Vec3
}

// MARK: - Clamping

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Bundle resources

enum BundleResources {
    /// Returns sorted file URLs from the app bundle matching a prefix and set of extensions.
    static func urls(prefix: String, extensions: Set<String>) -> [URL] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: resourcePath)) ?? []
        return files
            .filter { name in
                name.hasPrefix(prefix) && extensions.contains(where: { name.hasSuffix("." + $0) })
            }
            .sorted()
            .map { URL(fileURLWithPath: resourcePath + "/" + $0) }
    }
}

