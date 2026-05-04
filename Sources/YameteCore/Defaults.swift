import Foundation

/// All user-facing default values in one place.
/// SettingsStore registers these with UserDefaults and uses them for resetToDefaults().
/// Adapter factories and fusion engine also read from here.
public enum Defaults {

    // MARK: - Response controls

    public static let sensitivityMin: Double = 0.10
    public static let sensitivityMax: Double = 0.90
    public static let volumeMin: Double = 0.50
    public static let volumeMax: Double = 0.90
    public static let flashOpacityMin: Double = 0.50
    public static let flashOpacityMax: Double = 0.90
    public static let soundEnabled = true
    public static let screenFlash = true
    public static let visualResponseMode = VisualResponseMode.overlay
    public static let debugLogging = false

    // MARK: - Fusion / timing

    public static let consensus: Int = 1
    public static let debounce: Double = 0.5
    public static let fusionWindow: TimeInterval = 0.15
    public static let rearmDuration: TimeInterval = 0.50

    // MARK: - Accelerometer detection

    public static let accelSpikeThreshold: Double = 0.020
    public static let accelCrestFactor: Double = 1.5
    public static let accelRiseRate: Double = 0.010
    public static let accelConfirmations: Int = 3
    public static let accelWarmup: Int = 50
    public static let accelReportInterval: Double = 10000
    public static let accelBandpassLow: Double = 20.0
    public static let accelBandpassHigh: Double = 25.0

    // MARK: - Gyroscope detection (deg/s)

    public static let gyroSpikeThreshold: Double = 200.0
    public static let gyroCrestFactor: Double = 2.5
    public static let gyroRiseRate: Double = 50.0
    public static let gyroConfirmations: Int = 3
    public static let gyroWarmup: Int = 50

    // MARK: - Lid angle detection (degrees / deg-per-second)

    public static let lidOpenThresholdDeg: Double = 10.0
    public static let lidClosedThresholdDeg: Double = 5.0
    public static let lidSlamRateDegPerSec: Double = -180.0
    public static let lidSmoothingWindowMs: Int = 100

    // MARK: - Ambient light detection (lux)

    public static let alsCoverDropThreshold: Double = 0.95
    public static let alsOffDropPercent: Double = 0.80
    public static let alsOffFloorLux: Double = 30.0
    public static let alsOnRisePercent: Double = 1.50
    public static let alsOnCeilingLux: Double = 100.0
    public static let alsWindowSec: Double = 2.0

    // MARK: - Microphone detection

    public static let micSpikeThreshold: Double = 0.020
    public static let micCrestFactor: Double = 1.5
    public static let micRiseRate: Double = 0.010
    public static let micConfirmations: Int = 2
    public static let micWarmup: Int = 50

    // MARK: - Headphone motion detection

    public static let hpSpikeThreshold: Double = 0.10
    public static let hpCrestFactor: Double = 1.5
    public static let hpRiseRate: Double = 0.05
    public static let hpConfirmations: Int = 2
    public static let hpWarmup: Int = 50
}
