import Foundation

/// Valid ranges and signal processing parameters for the detection pipeline.
/// Referenced by SettingsStore (clamping), MenuBarView (slider bounds), and adapter factories.
/// Default values live in Defaults.swift.
public enum Detection {

    // MARK: - Accelerometer (bandpass-filtered g-force, BMI286 via IOKit)

    public enum Accel {
        public static let spikeThresholdRange: ClosedRange<Double> = 0.010...0.040
        public static let crestFactorRange: ClosedRange<Double> = 1.0...5.0
        public static let riseRateRange: ClosedRange<Double> = 0.005...0.020
        public static let confirmationsRange: ClosedRange<Int> = 1...5
        public static let warmupRange: ClosedRange<Int> = 10...100
        public static let reportIntervalRange: ClosedRange<Double> = 5000...50000
        public static let reportIntervalStep: Double = 1000
        public static let bandpassRange: ClosedRange<Double> = 10...25
        public static let intensityFloor: Float = 0.002
        public static let intensityCeiling: Float = 0.060
    }

    // MARK: - Gyroscope (deg/s angular velocity, BMI286 via SPU broker)

    public enum Gyro {
        public static let spikeThresholdRange: ClosedRange<Double> = 50.0...500.0
        public static let crestFactorRange: ClosedRange<Double> = 1.5...5.0
        public static let riseRateRange: ClosedRange<Double> = 10.0...200.0
        public static let confirmationsRange: ClosedRange<Int> = 1...10
        public static let warmupRange: ClosedRange<Int> = 0...200
        public static let intensityFloor: Float = 50.0
        public static let intensityCeiling: Float = 500.0
    }

    // MARK: - Lid angle (hinge angle in degrees, BMI286 + Apple SPU broker)

    public enum Lid {
        /// Angle past which the lid is considered open (deg).
        public static let openThresholdDegRange: ClosedRange<Double> = 5.0...30.0
        /// Angle below which the lid is considered closed (deg).
        public static let closedThresholdDegRange: ClosedRange<Double> = 1.0...10.0
        /// Closing rate (deg/s) below which a transition counts as a slam.
        /// Negative — slam rate is signed (closing reduces angle).
        public static let slamRateRange: ClosedRange<Double> = -500.0 ... -50.0
        /// EMA window over Δangle/Δt for jitter suppression (ms).
        public static let smoothingWindowMsRange: ClosedRange<Int> = 50...500
    }

    // MARK: - Ambient light (lux, BMI286 + Apple SPU broker)

    public enum AmbientLight {
        public static let coverDropThresholdRange: ClosedRange<Double> = 0.5...0.99
        public static let offDropPercentRange: ClosedRange<Double> = 0.5...0.99
        public static let offFloorLuxRange: ClosedRange<Double> = 1.0...300.0
        public static let onRisePercentRange: ClosedRange<Double> = 0.5...5.0
        public static let onCeilingLuxRange: ClosedRange<Double> = 50.0...1000.0
        public static let windowSecRange: ClosedRange<Double> = 0.5...10.0
    }

    // MARK: - Microphone (HP-filtered PCM amplitude, AVAudioEngine)

    public enum Mic {
        public static let spikeThresholdRange: ClosedRange<Double> = 0.005...0.100
        public static let crestFactorRange: ClosedRange<Double> = 1.0...5.0
        public static let riseRateRange: ClosedRange<Double> = 0.002...0.050
        public static let confirmationsRange: ClosedRange<Int> = 1...5
        public static let warmupRange: ClosedRange<Int> = 10...100
        public static let intensityFloor: Float = 0.005
        public static let intensityCeiling: Float = 0.300
        public static let hpAlpha: Float = 0.95
        public static let targetHz: Double = 50
    }

    // MARK: - Headphone Motion (g-force, CMHeadphoneMotionManager)

    public enum Headphone {
        public static let spikeThresholdRange: ClosedRange<Double> = 0.02...0.50
        public static let crestFactorRange: ClosedRange<Double> = 1.0...5.0
        public static let riseRateRange: ClosedRange<Double> = 0.010...0.200
        public static let confirmationsRange: ClosedRange<Int> = 1...5
        public static let warmupRange: ClosedRange<Int> = 10...100
        public static let intensityFloor: Float = 0.05
        public static let intensityCeiling: Float = 2.0
    }

    // MARK: - Shared detection parameters

    public static let windowDuration: TimeInterval = 0.12
    public static let rmsAlpha: Float = 0.02
    public static let intensityEpsilon: Float = 0.001
    public static let unitRange: ClosedRange<Double> = 0...1
    public static let debounceRange: ClosedRange<Double> = 0...2
    public static let consensusRange: ClosedRange<Int> = 1...10
}

/// BMI286 accelerometer hardware constants (IOKit HID report format).
public enum AccelHardwareConstants {
    public static let hidUsagePage: Int = 0xFF00
    public static let hidUsage: Int = 3
    public static let requiredTransport = "SPU"
    public static let decimationFactor = 2
    public static let magnitudeMin: Float = 0.3
    public static let magnitudeMax: Float = 4.0
    public static let minReportLength = 18
    public static let rawScale: Float = 65536.0
    public static let defaultSampleRate: Float = 50.0

    /// `AccelHardware.isSensorActivelyReporting()` returns true only when
    /// the driver's `_last_event_timestamp` is within this many nanoseconds
    /// of now. At 100Hz reports arrive every 10ms; 500ms is 50 missed
    /// samples — safely outside normal scheduler / run-loop jitter.
    public static let sensorActivityStalenessNs: UInt64 = 500_000_000
}
