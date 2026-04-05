import Foundation

// MARK: - RingBuffer

public struct RingBuffer {
    private var buffer: [Float]
    private var head = 0
    private var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        buffer = Array(repeating: 0, count: capacity)
    }

    public mutating func push(_ value: Float) {
        buffer[head] = value
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    public var isFull: Bool { count == capacity }
    public var currentCount: Int { count }

    public func asArray() -> [Float] {
        guard count == capacity else { return Array(buffer[0..<count]) }
        var out = [Float](repeating: 0, count: capacity)
        for i in 0..<capacity { out[i] = buffer[(head + i) % capacity] }
        return out
    }

    public func sumAbs() -> Float { buffer[0..<count].reduce(0) { $0 + abs($1) } }
}

// MARK: - HighPassFilter

public final class HighPassFilter {
    private let alpha: Float
    private var prev: Vec3 = .zero
    private var prevFiltered: Vec3 = .zero

    /// - Parameters:
    ///   - cutoffHz: High-pass cutoff frequency.
    ///   - sampleRate: Effective processing rate after decimation (100 Hz -> 50 Hz).
    public init(cutoffHz: Float = 5.0, sampleRate: Float = 50.0) {
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        alpha = rc / (rc + dt)
    }

    public func process(_ sample: Vec3) -> Vec3 {
        let filtered = Vec3(
            x: alpha * (prevFiltered.x + sample.x - prev.x),
            y: alpha * (prevFiltered.y + sample.y - prev.y),
            z: alpha * (prevFiltered.z + sample.z - prev.z)
        )
        prev = sample
        prevFiltered = filtered
        return filtered
    }

    public func reset() { prev = .zero; prevFiltered = .zero }
}

// MARK: - LowPassFilter

public final class LowPassFilter {
    private let alpha: Float
    private var prevFiltered: Vec3 = .zero

    /// - Parameters:
    ///   - cutoffHz: Low-pass cutoff frequency.
    ///   - sampleRate: Effective processing rate after decimation.
    public init(cutoffHz: Float = 25.0, sampleRate: Float = 50.0) {
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        alpha = dt / (rc + dt)
    }

    public func process(_ sample: Vec3) -> Vec3 {
        let filtered = Vec3(
            x: prevFiltered.x + alpha * (sample.x - prevFiltered.x),
            y: prevFiltered.y + alpha * (sample.y - prevFiltered.y),
            z: prevFiltered.z + alpha * (sample.z - prevFiltered.z)
        )
        prevFiltered = filtered
        return filtered
    }

    public func reset() { prevFiltered = .zero }
}
