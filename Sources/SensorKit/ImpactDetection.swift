#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import Foundation

private let log = AppLog(category: "ImpactFusion")

/// Fusion engine configuration.
public struct FusionConfig: Equatable, Sendable {
    /// Sensors that must independently detect an impact within the fusion
    /// window. Clamped at runtime to never exceed the number of active sources.
    public var consensusRequired: Int = Defaults.consensus
    /// Time window for collecting impacts from multiple sensors for consensus.
    public var fusionWindow: TimeInterval = Defaults.fusionWindow
    /// Minimum time between fused impact responses.
    public var rearmDuration: TimeInterval = Defaults.rearmDuration

    public init(consensusRequired: Int = Defaults.consensus,
                fusionWindow: TimeInterval = Defaults.fusionWindow,
                rearmDuration: TimeInterval = Defaults.rearmDuration) {
        self.consensusRequired = consensusRequired
        self.fusionWindow = fusionWindow
        self.rearmDuration = rearmDuration
    }
}

/// Subscribes to a set of `SensorSource` impact streams, runs consensus +
/// rearm gating, and publishes `Reaction.impact(...)` onto the bus.
///
/// Lifecycle is owned by this class — `start()` spawns one task per source
/// plus the fan-in/fusion task. `stop()` cancels them all and resets state.
@MainActor
public final class ImpactFusion {
    public private(set) var config: FusionConfig
    public private(set) var isRunning: Bool = false
    public private(set) var activeSources: Set<SensorID> = []

    private var recentImpacts: [SensorImpact] = []
    private var lastTriggerAt: Date = .distantPast

    private var sourceTasks: [Task<Void, Never>] = []
    private var fanInContinuation: AsyncStream<FanInEvent>.Continuation?
    private var fusionTask: Task<Void, Never>?

    /// Reports the live active-source set whenever it changes (sources
    /// finish/error). Consumers use this for UI badge updates.
    public var onActiveSourcesChanged: (@MainActor (Set<SensorID>) -> Void)?
    /// Reports source errors — UI surfaces them as a banner.
    public var onError: (@MainActor (String) -> Void)?
    /// Optional intensity remapper applied to fused impacts before they
    /// reach the bus. Returns `nil` to drop the impact entirely. Used by
    /// the orchestrator to apply the user's sensitivity band gate.
    public var intensityGate: (@MainActor (Float) -> Float?)?

    public init(config: FusionConfig = FusionConfig()) {
        self.config = config
    }

    public func configure(_ newConfig: FusionConfig) {
        config = newConfig
    }

    public func reset() {
        recentImpacts.removeAll()
        lastTriggerAt = .distantPast
    }

    private func gateIntensity(of fused: FusedImpact) -> FusedImpact? {
        guard let gate = intensityGate else { return fused }
        guard let mapped = gate(fused.intensity) else { return nil }
        return FusedImpact(
            timestamp: fused.timestamp,
            intensity: mapped,
            confidence: fused.confidence,
            sources: fused.sources
        )
    }

    /// Start consuming the given sources. Sensor tasks fan into a private
    /// stream; the fusion task drains it, runs gating, and publishes to the
    /// bus. Re-entrant call: stops the existing pipeline first.
    public func start(sources: [any SensorSource], bus: ReactionBus) {
        if isRunning { stop() }
        let available = sources.filter { $0.isAvailable }
        guard !available.isEmpty else {
            onError?(SensorError.noAdaptersAvailable.localizedDescription)
            return
        }
        isRunning = true
        activeSources = Set(available.map(\.id))
        onActiveSourcesChanged?(activeSources)
        log.info("activity:ImpactFusion wasStartedBy entity:ImpactFusion sources=\(available.map(\.name))")

        let (fanIn, continuation) = AsyncStream<FanInEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        fanInContinuation = continuation

        for source in available {
            let task = Task.detached {
                do {
                    for try await impact in source.impacts() {
                        continuation.yield(.impact(impact))
                    }
                } catch is CancellationError {
                    // expected on stop()
                } catch {
                    continuation.yield(.sourceError(source.id, source.name, error.localizedDescription))
                }
                continuation.yield(.sourceFinished(source.id))
            }
            sourceTasks.append(task)
        }

        fusionTask = Task { @MainActor [weak self] in
            for await event in fanIn {
                guard let self else { return }
                switch event {
                case .impact(let impact):
                    if let fused = self.ingest(impact, activeSources: self.activeSources),
                       let gated = self.gateIntensity(of: fused) {
                        await bus.publish(.impact(gated))
                    }
                case .sourceFinished(let id):
                    self.activeSources.remove(id)
                    self.onActiveSourcesChanged?(self.activeSources)
                case .sourceError(_, let name, let message):
                    self.onError?("\(name): \(message)")
                }
            }
        }
    }

    public func stop() {
        #if DEBUG
        _testHooks.stopInvocationCount += 1
        #endif
        guard isRunning else {
            #if DEBUG
            _testHooks.lastStopWasNoOp = true
            #endif
            return
        }
        #if DEBUG
        _testHooks.lastStopWasNoOp = false
        _testHooks.stopTeardownCount += 1
        #endif
        for task in sourceTasks { task.cancel() }
        sourceTasks.removeAll()
        fanInContinuation?.finish()
        fanInContinuation = nil
        fusionTask?.cancel()
        fusionTask = nil
        isRunning = false
        activeSources = []
        reset()
        onActiveSourcesChanged?([])
        log.info("activity:ImpactFusion wasEndedBy entity:ImpactFusion")
    }

    #if DEBUG
    /// Test-only observability for the `stop()` idempotency gate
    /// (`guard isRunning else { return }`). Every `stop()` invocation
    /// increments `stopInvocationCount`; `stopTeardownCount` increments
    /// only when the gate allows teardown to proceed; `lastStopWasNoOp`
    /// reflects the most recent invocation. Tests use these to observe
    /// whether the idempotency guard is firing as designed.
    public struct TestHooks {
        public var stopInvocationCount: Int = 0
        public var stopTeardownCount: Int = 0
        public var lastStopWasNoOp: Bool = false
    }
    public var _testHooks = TestHooks()
    #endif

    // MARK: - Fusion gating

    /// Returns a `FusedImpact` when consensus + rearm are satisfied. The
    /// `activeSources` parameter is used to clamp `consensusRequired` (so
    /// "require 2" against a single active sensor still emits) and to
    /// compute confidence. The runtime path passes `self.activeSources`;
    /// tests can call this directly with synthetic active sets.
    public func ingest(_ impact: SensorImpact, activeSources: Set<SensorID>) -> FusedImpact? {
        let now = impact.timestamp
        recentImpacts.removeAll { now.timeIntervalSince($0.timestamp) > config.fusionWindow }
        recentImpacts.append(impact)

        guard now.timeIntervalSince(lastTriggerAt) >= config.rearmDuration else { return nil }

        let participatingSources = Set(recentImpacts.map(\.source))
        let required = max(1, min(config.consensusRequired, activeSources.count))
        if required != config.consensusRequired {
            log.info("activity:FusionConfig consensusRequired clamped from \(config.consensusRequired) to \(required) — only \(activeSources.count) source(s) active")
        }
        guard participatingSources.count >= required else { return nil }

        var bestPerSource: [SensorID: SensorImpact] = [:]
        for imp in recentImpacts {
            if let existing = bestPerSource[imp.source] {
                if imp.intensity > existing.intensity { bestPerSource[imp.source] = imp }
            } else {
                bestPerSource[imp.source] = imp
            }
        }

        let participants = Array(bestPerSource.values)
        let avgIntensity = participants.reduce(Float(0)) { $0 + $1.intensity } / Float(participants.count)
        let confidence = Float(participants.count) / Float(max(activeSources.count, 1))

        lastTriggerAt = now
        recentImpacts.removeAll()

        log.debug("entity:FusedImpact intensity=\(String(format: "%.2f", avgIntensity)) confidence=\(String(format: "%.2f", confidence)) sources=\(participants.map(\.source))")

        return FusedImpact(
            timestamp: now,
            intensity: avgIntensity,
            confidence: confidence,
            sources: participants.map(\.source)
        )
    }
}

// MARK: - Internal fan-in event

private enum FanInEvent: Sendable {
    case impact(SensorImpact)
    case sourceFinished(SensorID)
    case sourceError(SensorID, String, String)
}
