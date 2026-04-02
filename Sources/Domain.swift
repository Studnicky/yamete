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

// MARK: - Concurrency helpers

/// Erases `Sendable` checking for values whose thread safety is guaranteed
/// by program structure (e.g., MainActor confinement) but not expressible
/// in the type system.
struct Transferred<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
