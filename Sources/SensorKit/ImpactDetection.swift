#if canImport(YameteCore)
import YameteCore
#endif
import Foundation

private let log = AppLog(category: "ImpactFusion")

/// Fusion engine configuration.
public struct FusionConfig: Equatable {
    /// Number of sensors that must independently detect an impact within the fusion window.
    /// Clamped at runtime to never exceed the number of sensors reporting.
    public var consensusRequired: Int = 1
    /// Time window for collecting impacts from multiple sensors for consensus.
    public var fusionWindow: TimeInterval = 0.15
    /// Minimum time between fused impact responses.
    public var rearmDuration: TimeInterval = 0.50

    public init(consensusRequired: Int = 1, fusionWindow: TimeInterval = 0.15,
                rearmDuration: TimeInterval = 0.50) {
        self.consensusRequired = consensusRequired
        self.fusionWindow = fusionWindow
        self.rearmDuration = rearmDuration
    }
}

/// Fuses impact events from multiple independent sensor adapters.
///
/// Each adapter runs its own detection pipeline and emits SensorImpact events.
/// The fusion engine collects these within a time window, checks consensus
/// (N sensors must agree), applies rearm timing, and produces a fused result.
@MainActor
public final class ImpactFusionEngine {
    public struct FusedImpact {
        public let timestamp: Date
        /// Average intensity across participating sensors (0–1).
        public let intensity: Float
        /// Fraction of active sensors that detected the impact.
        public let confidence: Float
        /// Which sensors participated.
        public let sources: [SensorID]
    }

    private(set) var config: FusionConfig
    private var recentImpacts: [SensorImpact] = []
    private var lastTriggerAt: Date = .distantPast

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

    /// Ingest an impact event from an adapter. Returns a fused impact if consensus is met.
    public func ingest(_ impact: SensorImpact, activeSources: Set<SensorID>) -> FusedImpact? {
        let now = impact.timestamp

        // Prune impacts outside fusion window
        recentImpacts.removeAll { now.timeIntervalSince($0.timestamp) > config.fusionWindow }
        recentImpacts.append(impact)

        // Rearm gate
        guard now.timeIntervalSince(lastTriggerAt) >= config.rearmDuration else { return nil }

        // Consensus: unique sources that reported an impact within the fusion window
        let participatingSources = Set(recentImpacts.map(\.source))
        let required = max(1, min(config.consensusRequired, activeSources.count))

        guard participatingSources.count >= required else { return nil }

        // Fuse: average intensity across participating sources
        // Use the strongest impact per source
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
