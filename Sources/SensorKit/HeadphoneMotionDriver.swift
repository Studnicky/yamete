#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import CoreMotion
import Foundation
import os

// MARK: - Headphone motion driver protocol
//
// Abstracts the `CMHeadphoneMotionManager` surface used by
// `HeadphoneMotionSource`. The protocol covers the three calls the
// adapter makes plus the device-availability flag and a connection
// observer hook.
//
// The adapter normally creates one driver up front and reuses it for
// the lifetime of the source instance. Mocks expose `simulateConnect`
// / `simulateDisconnect` / `emit(motion:)` so lifecycle tests can
// drive the connect → stream → disconnect path without real
// hardware.

/// A snapshot of the values consumed by the adapter. We deliberately
/// project only `userAcceleration` so mocks don't have to fabricate
/// full `CMDeviceMotion` values (the framework type is not directly
/// constructible).
public struct HeadphoneMotionSample: Sendable {
    public let userAccelerationX: Double
    public let userAccelerationY: Double
    public let userAccelerationZ: Double

    public init(x: Double, y: Double, z: Double) {
        self.userAccelerationX = x
        self.userAccelerationY = y
        self.userAccelerationZ = z
    }
}

public protocol HeadphoneMotionDriver: AnyObject, Sendable {
    /// Whether the framework supports headphone motion on this host.
    /// Independent of whether AirPods are currently paired.
    var isDeviceMotionAvailable: Bool { get }

    /// Whether motion-capable headphones are currently connected.
    /// Maintained by the underlying `CMHeadphoneMotionManagerDelegate`
    /// in the real driver. Mocks expose a setter.
    var isHeadphonesConnected: Bool { get }

    /// Begin streaming motion samples. The handler is invoked with
    /// either a sample or an error (mutually exclusive). Idempotent:
    /// calling twice replaces the prior handler.
    func startUpdates(handler: @escaping @Sendable (HeadphoneMotionSample?, Error?) -> Void)

    /// Stop streaming. Idempotent.
    func stopUpdates()
}

// MARK: - Real implementation

/// Production CMHeadphoneMotionManager-backed driver. Owns one
/// motion manager + a connection tracker for the lifetime of the
/// instance.
public final class RealHeadphoneMotionDriver: HeadphoneMotionDriver, @unchecked Sendable {
    // `@unchecked Sendable` rationale: `CMHeadphoneMotionManager` is
    // not formally `Sendable`. The driver instance is owned by one
    // `HeadphoneMotionSource` and accessed only from its consumer
    // task plus the framework's delivery queue.
    private let manager = CMHeadphoneMotionManager()
    private let tracker = HeadphoneConnectionTracker()

    public init() {
        manager.delegate = tracker
    }

    public var isDeviceMotionAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    public var isHeadphonesConnected: Bool {
        tracker.isConnected
    }

    public func startUpdates(handler: @escaping @Sendable (HeadphoneMotionSample?, Error?) -> Void) {
        let tracker = self.tracker
        manager.startDeviceMotionUpdates(to: OperationQueue()) { motion, error in
            if let error {
                handler(nil, error)
                return
            }
            guard let motion else {
                handler(nil, nil)
                return
            }
            // Any non-nil sample means headphones are physically streaming
            // motion data, which means they're connected. The delegate's
            // didConnect should also fire — both paths set the same flag.
            tracker.markConnected()
            let accel = motion.userAcceleration
            handler(HeadphoneMotionSample(x: accel.x, y: accel.y, z: accel.z), nil)
        }
    }

    public func stopUpdates() {
        manager.stopDeviceMotionUpdates()
    }
}

// MARK: - Connection state tracker
//
// Tracks whether motion-capable headphones are currently connected by
// observing `CMHeadphoneMotionManagerDelegate` callbacks. Lives at
// file scope so the real driver can own one without exposing it
// through the protocol.
//
// `CMHeadphoneMotionManager.isDeviceMotionAvailable` only reports framework
// support — it returns true on every Apple Silicon Mac regardless of whether
// AirPods are paired/connected. Real connection state requires the delegate.
//
// Sendable: the only stored state is an `OSAllocatedUnfairLock<Bool>`.
// `OSAllocatedUnfairLock` is Sendable when its state type is Sendable, and
// `Bool` is Sendable. No unchecked escape required.
final class HeadphoneConnectionTracker: NSObject, CMHeadphoneMotionManagerDelegate, Sendable {
    private let state = OSAllocatedUnfairLock<Bool>(initialState: false)

    var isConnected: Bool { state.withLock { $0 } }

    /// Set by the startup probe (in `HeadphoneMotionSource.startConnectionProbe`)
    /// when motion data starts flowing. The delegate's didConnect callback
    /// is also expected to fire — both paths land in the same flag.
    func markConnected() {
        state.withLock { $0 = true }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        state.withLock { $0 = true }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        state.withLock { $0 = false }
    }
}
