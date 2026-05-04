#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
@preconcurrency import Foundation
import os

// MARK: - ThermalSource — discrete state-transition source over NSProcessInfo
//
// `ProcessInfo.thermalState` is a 4-level enum (`.nominal`, `.fair`,
// `.serious`, `.critical`) the system raises to indicate sustained CPU
// thermal pressure. The kernel posts
// `ProcessInfo.thermalStateDidChangeNotification` on
// `NotificationCenter.default` on every transition. This source wraps
// that notification and republishes the new state as a discrete
// Reaction (`.thermalNominal`, `.thermalFair`, `.thermalSerious`,
// `.thermalCritical`).
//
// Unlike Phase 2/3 sources, this source does NOT touch the AppleSPU
// HID broker — thermal state is OS-defined and surfaces through Cocoa
// notifications. The semantic shape closest to this in the existing
// codebase is `SleepWakeSource` / `PowerSource` — both edge-trigger
// against a captured baseline. We follow the same pattern:
//   • At `start()`, capture the current state silently (no publish).
//   • On every notification, read the new state via the injected
//     provider, dedup against the last-seen state, and publish the
//     matching Reaction on a transition.
//
// Cold-start suppression: a host that boots in `.fair` must NOT
// surface `.thermalFair` on launch. Only transitions emit.
//
// Dedup: macOS occasionally posts the notification with no actual
// state change. The same-state guard collapses those into no-ops.

private let log = AppLog(category: "ThermalSource")

/// Indirection over `ProcessInfo.processInfo.thermalState`. Production
/// uses `RealThermalStateProvider`; tests inject `MockThermalStateProvider`
/// to drive the observed state without touching the real ProcessInfo.
public protocol ThermalStateProvider: Sendable {
    var thermalState: ProcessInfo.ThermalState { get }
}

/// Default provider — reads `ProcessInfo.processInfo.thermalState`.
public struct RealThermalStateProvider: ThermalStateProvider {
    public init() {}
    public var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}

/// Direct-publish reaction source for OS-level thermal pressure.
/// Emits `.thermalNominal`, `.thermalFair`, `.thermalSerious`,
/// `.thermalCritical` directly via the reaction bus on every kernel
/// transition. Not `@MainActor` because the observer registers on
/// `.main` OperationQueue but the source itself is shared state that
/// also exposes test-seam injectors that must run on the test's
/// MainActor.
public final class ThermalSource: Sendable {

    public let id = SensorID.thermal
    /// Localized display name. Resolved at access time via
    /// `NSLocalizedString` so the menu UI surfaces the user's
    /// preferred-locale string. Mirrors `LidAngleSource.name`.
    public var name: String {
        NSLocalizedString("sensor_thermal", comment: "Thermal pressure sensor name")
    }

    /// Always available — every macOS host exposes ProcessInfo
    /// thermal state. No hardware gate.
    public var isAvailable: Bool { true }

    private let provider: ThermalStateProvider

    /// Lock-protected lifecycle / state. The observer token is
    /// captured at `start()` and removed at `stop()`. `lastState`
    /// holds the most-recently observed state (or nil before start).
    private struct State {
        var token: NSObjectProtocol?
        var bus: ReactionBus?
        var lastState: ProcessInfo.ThermalState?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// Public init. Default provider reads `ProcessInfo.processInfo`.
    /// Tests inject a `MockThermalStateProvider`.
    public init(provider: ThermalStateProvider = RealThermalStateProvider()) {
        self.provider = provider
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - Lifecycle

    /// Register the notification observer and begin publishing
    /// thermal Reactions onto the supplied bus on detected
    /// transitions. Idempotent — calling while already started is a
    /// no-op. The current state at start is captured silently
    /// (cold-start suppression).
    public func start(publishingTo bus: ReactionBus) {
        let alreadyRunning = state.withLock { s -> Bool in
            return s.token != nil
        }
        if alreadyRunning { return }

        // Capture the cold-start baseline BEFORE registering the
        // observer so even if a notification fires immediately, the
        // dedup gate will see lastState != nil and only emit on a
        // genuine transition.
        let initial = provider.thermalState

        let token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main,
            using: { @Sendable [weak self] _ in
                self?.handleStateChange()
            }
        )

        state.withLock { s in
            s.token = token
            s.bus = bus
            s.lastState = initial
        }

        log.info("entity:ThermalSource wasGeneratedBy activity:Start initial=\(Self.describe(initial))")
    }

    /// Remove the notification observer and tear down internal state.
    /// Idempotent.
    public func stop() {
        let token = state.withLock { s -> NSObjectProtocol? in
            let t = s.token
            s.token = nil
            s.bus = nil
            s.lastState = nil
            return t
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
            log.info("entity:ThermalSource wasInvalidatedBy activity:Stop")
        }
    }

    // MARK: - State handling

    /// Read the current state via the provider, dedup against the
    /// last-observed state, and publish on a transition. Exposed
    /// `internal` so the matrix mutation cells in
    /// `MatrixThermalSource_Tests` can drive the gate set without
    /// posting through `NotificationCenter`.
    internal func handleStateChange() {
        let current = provider.thermalState

        // Resolve the publish decision under the lock, then publish
        // outside the lock — `bus.publish` is async and we must not
        // hold an unfair lock across an await.
        struct Pending {
            let bus: ReactionBus
            let reaction: Reaction
        }
        let pending: Pending? = state.withLock { s in
            guard let bus = s.bus else { return nil }
            // Dedup: identical state → no emission.
            if s.lastState == current { return nil }
            s.lastState = current
            return Pending(bus: bus, reaction: Self.reaction(for: current))
        }

        if let pending {
            log.info("activity:Publish wasGeneratedBy entity:ThermalSource state=\(Self.describe(current))")
            Task { await pending.bus.publish(pending.reaction) }
        }
    }

    /// Maps `ProcessInfo.ThermalState` to its corresponding Reaction.
    /// Centralised so the mutation cell `thermal-state-mapping` has a
    /// single mutation site.
    internal static func reaction(for state: ProcessInfo.ThermalState) -> Reaction {
        switch state {
        case .nominal:  return .thermalNominal
        case .fair:     return .thermalFair
        case .serious:  return .thermalSerious
        case .critical: return .thermalCritical
        @unknown default: return .thermalNominal
        }
    }

    private static func describe(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Test seams

    #if DEBUG
    /// Test seam — drives one notification cycle directly. Mirrors
    /// the production observer callback: re-reads the provider's
    /// current state and runs the dedup + publish path. Tests that
    /// use a `MockThermalStateProvider` should mutate the mock's
    /// state THEN call this to simulate the kernel notification.
    @MainActor
    internal func _testTriggerStateChange() async {
        handleStateChange()
        await Task.yield()
    }

    /// Convenience seam — mutates the mock provider's state (if
    /// injected) and triggers the change handler in one call.
    /// No-op when the source was constructed with a non-mock
    /// provider.
    @MainActor
    internal func _testTriggerStateChange(to newState: ProcessInfo.ThermalState) async {
        if let mock = provider as? MockThermalStateProvider {
            mock.set(newState)
        }
        handleStateChange()
        await Task.yield()
    }

    /// Test seam — reads the current cached `lastState` for assertion.
    internal func _testCurrentLastState() -> ProcessInfo.ThermalState? {
        state.withLock { $0.lastState }
    }
    #endif
}

#if DEBUG
/// Test-only mock provider. Mutable state under the same unfair-lock
/// shape used elsewhere in the suite.
public final class MockThermalStateProvider: ThermalStateProvider, @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<ProcessInfo.ThermalState>

    public init(_ initial: ProcessInfo.ThermalState = .nominal) {
        self.storage = OSAllocatedUnfairLock(initialState: initial)
    }

    public var thermalState: ProcessInfo.ThermalState {
        storage.withLock { $0 }
    }

    public func set(_ newState: ProcessInfo.ThermalState) {
        storage.withLock { $0 = newState }
    }
}
#endif
