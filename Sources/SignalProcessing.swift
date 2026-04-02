import Foundation

// MARK: - RingBuffer

struct RingBuffer {
    private var buffer: [Float]
    private var head = 0
    private var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        buffer = Array(repeating: 0, count: capacity)
    }

    mutating func push(_ value: Float) {
        buffer[head] = value
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    var isFull: Bool { count == capacity }
    var currentCount: Int { count }

    func asArray() -> [Float] {
        guard count == capacity else { return Array(buffer[0..<count]) }
        var out = [Float](repeating: 0, count: capacity)
        for i in 0..<capacity { out[i] = buffer[(head + i) % capacity] }
        return out
    }

    func sumAbs() -> Float { buffer[0..<count].reduce(0) { $0 + abs($1) } }
}

// MARK: - HighPassFilter

final class HighPassFilter {
    private let alpha: Float
    private var prev: Vec3 = .zero
    private var prevFiltered: Vec3 = .zero

    /// - Parameters:
    ///   - cutoffHz: High-pass cutoff frequency.
    ///   - sampleRate: Actual processing rate (post-decimation).
    ///     The accelerometer reports at 100 Hz, decimated by 2 → 50 Hz.
    init(cutoffHz: Float = 5.0, sampleRate: Float = 50.0) {
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        alpha = rc / (rc + dt)
    }

    func process(_ sample: Vec3) -> Vec3 {
        let filtered = Vec3(
            x: alpha * (prevFiltered.x + sample.x - prev.x),
            y: alpha * (prevFiltered.y + sample.y - prev.y),
            z: alpha * (prevFiltered.z + sample.z - prev.z)
        )
        prev = sample
        prevFiltered = filtered
        return filtered
    }

    func reset() { prev = .zero; prevFiltered = .zero }
}
