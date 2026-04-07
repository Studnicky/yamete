import XCTest
@testable import YameteCore

// MARK: - Signal processing end-to-end tests
//
// Tests HighPassFilter and LowPassFilter frequency response characteristics
// using synthetic waveforms. Validates DC removal, high-frequency attenuation,
// and bandpass combination behavior.

final class SignalProcessingE2ETests: XCTestCase {

    private let sampleRate: Float = 50.0  // 50 Hz effective rate (after decimation)

    // MARK: - Helpers

    /// Generates a sine wave on the Z axis at a given frequency.
    private func sineWave(frequency: Float, amplitude: Float = 1.0,
                           sampleRate: Float, duration: Float) -> [Vec3] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { i in
            let t = Float(i) / sampleRate
            let z = amplitude * sinf(2.0 * .pi * frequency * t)
            return Vec3(x: 0, y: 0, z: z)
        }
    }

    /// Generates a DC constant signal on Z axis.
    private func dcSignal(value: Float, sampleRate: Float, duration: Float) -> [Vec3] {
        let sampleCount = Int(sampleRate * duration)
        return Array(repeating: Vec3(x: 0, y: 0, z: value), count: sampleCount)
    }

    /// Generates a combined signal: DC + sine at given frequency.
    private func dcPlusSine(dc: Float, frequency: Float, amplitude: Float,
                             sampleRate: Float, duration: Float) -> [Vec3] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { i in
            let t = Float(i) / sampleRate
            let z = dc + amplitude * sinf(2.0 * .pi * frequency * t)
            return Vec3(x: 0, y: 0, z: z)
        }
    }

    /// Measures RMS of filtered Z-axis output over the last N samples.
    private func rmsZ(of samples: [Vec3], lastN: Int? = nil) -> Float {
        let subset = lastN.map { Array(samples.suffix($0)) } ?? samples
        guard !subset.isEmpty else { return 0 }
        let sumSq = subset.reduce(Float(0)) { $0 + $1.z * $1.z }
        return sqrtf(sumSq / Float(subset.count))
    }

    /// Measures peak absolute Z value in the last N samples.
    private func peakZ(of samples: [Vec3], lastN: Int? = nil) -> Float {
        let subset = lastN.map { Array(samples.suffix($0)) } ?? samples
        return subset.map { abs($0.z) }.max() ?? 0
    }

    // MARK: - HighPassFilter: DC removal

    func testHighPassRemovesDCComponent() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let signal = dcSignal(value: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(hpf.process(s)) }

        // After settling, DC should be removed (near zero)
        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        XCTAssertLessThan(steadyRMS, 0.05, "High-pass should remove DC component to near zero")
    }

    func testHighPassRemovesGravityOffset() {
        // Simulates accelerometer gravity: constant ~0.98g on Z
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let signal = dcSignal(value: 0.98, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(hpf.process(s)) }

        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        XCTAssertLessThan(steadyRMS, 0.05, "High-pass should remove gravity offset")
    }

    func testHighPassPassesImpulse() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)

        // Settle on zero
        for _ in 0..<100 { _ = hpf.process(.zero) }

        // Sharp impulse
        let impulse = hpf.process(Vec3(x: 0, y: 0, z: 3.0))
        XCTAssertGreaterThan(abs(impulse.z), 1.0, "High-pass should pass through sharp impulses")
    }

    func testHighPassPassesHighFrequency() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let signal = sineWave(frequency: 15.0, amplitude: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(hpf.process(s)) }

        // 15 Hz is well above 5 Hz cutoff -- should pass through with good amplitude
        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        let inputRMS = rmsZ(of: Array(signal.suffix(50)))
        XCTAssertGreaterThan(steadyRMS, inputRMS * 0.7,
            "High-pass should pass 15 Hz signal (well above 5 Hz cutoff)")
    }

    func testHighPassAttenuatesLowFrequency() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let signal = sineWave(frequency: 1.0, amplitude: 1.0, sampleRate: sampleRate, duration: 8.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(hpf.process(s)) }

        // 1 Hz is well below 5 Hz cutoff -- should be significantly attenuated
        let steadyRMS = rmsZ(of: filtered, lastN: 100)
        XCTAssertLessThan(steadyRMS, 0.3,
            "High-pass should attenuate 1 Hz signal (well below 5 Hz cutoff)")
    }

    // MARK: - LowPassFilter: high frequency attenuation

    func testLowPassAttenuatesHighFrequency() {
        let lpf = LowPassFilter(cutoffHz: 10.0, sampleRate: sampleRate)
        // Nyquist is 25 Hz; test at 20 Hz (well above 10 Hz cutoff)
        let signal = sineWave(frequency: 20.0, amplitude: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(lpf.process(s)) }

        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        XCTAssertLessThan(steadyRMS, 0.5,
            "Low-pass should attenuate 20 Hz signal (well above 10 Hz cutoff)")
    }

    func testLowPassPassesLowFrequency() {
        let lpf = LowPassFilter(cutoffHz: 20.0, sampleRate: sampleRate)
        let signal = sineWave(frequency: 2.0, amplitude: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(lpf.process(s)) }

        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        let inputRMS = rmsZ(of: Array(signal.suffix(50)))
        XCTAssertGreaterThan(steadyRMS, inputRMS * 0.8,
            "Low-pass should pass 2 Hz signal (well below 20 Hz cutoff)")
    }

    func testLowPassPassesDC() {
        let lpf = LowPassFilter(cutoffHz: 10.0, sampleRate: sampleRate)
        let signal = dcSignal(value: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(lpf.process(s)) }

        // DC should pass through low-pass filter
        let lastSample = filtered.last!
        XCTAssertEqual(lastSample.z, 1.0, accuracy: 0.05,
            "Low-pass should pass DC component through")
    }

    func testLowPassSmoothsImpulse() {
        let lpf = LowPassFilter(cutoffHz: 10.0, sampleRate: sampleRate)

        // Settle at zero
        for _ in 0..<50 { _ = lpf.process(.zero) }

        // Impulse: the low-pass will smooth it, reducing peak amplitude
        let impulseResponse = lpf.process(Vec3(x: 0, y: 0, z: 5.0))
        XCTAssertLessThan(abs(impulseResponse.z), 5.0,
            "Low-pass should smooth impulse, reducing peak")
        XCTAssertGreaterThan(abs(impulseResponse.z), 0.0,
            "Low-pass should still respond to impulse")
    }

    // MARK: - Bandpass combination (high-pass + low-pass)

    func testBandpassPassesMidFrequency() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let lpf = LowPassFilter(cutoffHz: 20.0, sampleRate: sampleRate)

        // 12 Hz is in the passband (5-20 Hz)
        let signal = sineWave(frequency: 12.0, amplitude: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal {
            let hp = hpf.process(s)
            let bp = lpf.process(hp)
            filtered.append(bp)
        }

        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        XCTAssertGreaterThan(steadyRMS, 0.25,
            "Bandpass should pass 12 Hz signal (in 5-20 Hz passband) with reasonable amplitude")
    }

    func testBandpassRejectsDC() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let lpf = LowPassFilter(cutoffHz: 20.0, sampleRate: sampleRate)

        let signal = dcSignal(value: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal {
            let hp = hpf.process(s)
            let bp = lpf.process(hp)
            filtered.append(bp)
        }

        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        XCTAssertLessThan(steadyRMS, 0.05,
            "Bandpass should reject DC (removed by high-pass stage)")
    }

    func testBandpassRejectsHighFrequencyNoise() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let lpf = LowPassFilter(cutoffHz: 10.0, sampleRate: sampleRate)

        // 22 Hz is above the low-pass cutoff
        let signal = sineWave(frequency: 22.0, amplitude: 1.0, sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal {
            let hp = hpf.process(s)
            let bp = lpf.process(hp)
            filtered.append(bp)
        }

        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        XCTAssertLessThan(steadyRMS, 0.4,
            "Bandpass should attenuate 22 Hz signal (above low-pass cutoff)")
    }

    func testBandpassRejectsLowFrequencyVibration() {
        let hpf = HighPassFilter(cutoffHz: 10.0, sampleRate: sampleRate)
        let lpf = LowPassFilter(cutoffHz: 20.0, sampleRate: sampleRate)

        // 2 Hz simulates footsteps -- below high-pass cutoff
        let signal = sineWave(frequency: 2.0, amplitude: 1.0, sampleRate: sampleRate, duration: 8.0)

        var filtered: [Vec3] = []
        for s in signal {
            let hp = hpf.process(s)
            let bp = lpf.process(hp)
            filtered.append(bp)
        }

        let steadyRMS = rmsZ(of: filtered, lastN: 100)
        XCTAssertLessThan(steadyRMS, 0.3,
            "Bandpass should reject 2 Hz footstep vibration (below high-pass cutoff)")
    }

    // MARK: - Mixed signal (DC + impact frequency)

    func testHighPassExtractsImpactFromGravity() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)

        // Gravity (0.98g DC) + desk hit vibration (15 Hz, 0.05g)
        let signal = dcPlusSine(dc: 0.98, frequency: 15.0, amplitude: 0.05,
                                 sampleRate: sampleRate, duration: 4.0)

        var filtered: [Vec3] = []
        for s in signal { filtered.append(hpf.process(s)) }

        // After settling, should see the 15 Hz component without DC
        let steadyRMS = rmsZ(of: filtered, lastN: 50)
        let steadyPeak = peakZ(of: filtered, lastN: 50)

        // RMS should be near the sine amplitude / sqrt(2) = ~0.035
        XCTAssertGreaterThan(steadyRMS, 0.02, "Should pass through 15 Hz vibration component")
        XCTAssertLessThan(steadyRMS, 0.10, "Should not carry DC offset through")
        XCTAssertLessThan(steadyPeak, 0.15, "Peak should be near impact amplitude, not gravity")
    }

    // MARK: - Multi-axis processing

    func testHighPassProcessesAllAxes() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)

        // Settle with constant on all axes
        for _ in 0..<200 {
            _ = hpf.process(Vec3(x: 0.5, y: -0.3, z: 0.98))
        }

        // After settling, DC on all axes should be removed
        let result = hpf.process(Vec3(x: 0.5, y: -0.3, z: 0.98))
        XCTAssertLessThan(abs(result.x), 0.05, "X-axis DC should be removed")
        XCTAssertLessThan(abs(result.y), 0.05, "Y-axis DC should be removed")
        XCTAssertLessThan(abs(result.z), 0.05, "Z-axis DC should be removed")
    }

    func testLowPassProcessesAllAxes() {
        let lpf = LowPassFilter(cutoffHz: 10.0, sampleRate: sampleRate)

        // Feed constant on all axes
        for _ in 0..<200 {
            _ = lpf.process(Vec3(x: 1.0, y: -1.0, z: 0.5))
        }

        let result = lpf.process(Vec3(x: 1.0, y: -1.0, z: 0.5))
        XCTAssertEqual(result.x, 1.0, accuracy: 0.05, "X-axis DC should pass through low-pass")
        XCTAssertEqual(result.y, -1.0, accuracy: 0.05, "Y-axis DC should pass through low-pass")
        XCTAssertEqual(result.z, 0.5, accuracy: 0.05, "Z-axis DC should pass through low-pass")
    }

    // MARK: - Filter stability under long sequences

    func testHighPassStabilityUnderLongSequence() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        let signal = sineWave(frequency: 10.0, amplitude: 1.0, sampleRate: sampleRate, duration: 60.0)

        var last = Vec3.zero
        for s in signal { last = hpf.process(s) }

        // Should not diverge or produce NaN/Inf
        XCTAssertFalse(last.z.isNaN, "Filter should not produce NaN after long sequence")
        XCTAssertFalse(last.z.isInfinite, "Filter should not diverge after long sequence")
    }

    func testLowPassStabilityUnderLongSequence() {
        let lpf = LowPassFilter(cutoffHz: 20.0, sampleRate: sampleRate)
        let signal = sineWave(frequency: 10.0, amplitude: 1.0, sampleRate: sampleRate, duration: 60.0)

        var last = Vec3.zero
        for s in signal { last = lpf.process(s) }

        XCTAssertFalse(last.z.isNaN, "Filter should not produce NaN after long sequence")
        XCTAssertFalse(last.z.isInfinite, "Filter should not diverge after long sequence")
    }

    // MARK: - Edge cases

    func testHighPassWithZeroInput() {
        let hpf = HighPassFilter(cutoffHz: 5.0, sampleRate: sampleRate)
        for _ in 0..<100 {
            let result = hpf.process(.zero)
            XCTAssertFalse(result.z.isNaN, "Zero input should not produce NaN")
        }
    }

    func testLowPassWithZeroInput() {
        let lpf = LowPassFilter(cutoffHz: 20.0, sampleRate: sampleRate)
        for _ in 0..<100 {
            let result = lpf.process(.zero)
            XCTAssertFalse(result.z.isNaN, "Zero input should not produce NaN")
        }
    }
}
