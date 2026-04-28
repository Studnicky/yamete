import Foundation

/// Closure type for the bus enricher. Called once per reaction before fan-out.
/// Receives the raw reaction and the bus-stamped publish timestamp.
public typealias ReactionEnricher = @Sendable (Reaction, Date) async -> FiredReaction

/// Multi-subscriber reaction broadcast with pre-fan-out enrichment.
///
/// Sensors publish raw `Reaction` via `publish(_:)`. Before delivery, the bus
/// runs a registered enricher (set once by the coordinator) that resolves
/// per-reaction metadata (e.g. audio clip duration). Every subscriber receives
/// a `FiredReaction` with identical, pre-resolved values.
public actor ReactionBus {
    private var subscribers: [UUID: AsyncStream<FiredReaction>.Continuation] = [:]
    /// Enricher receives the reaction and the bus-stamped publish time so that
    /// `FiredReaction.publishedAt` reflects when the reaction entered the bus,
    /// not when enrichment completes (which may be after async audio/face ops).
    private var enricher: ReactionEnricher?
    private let log = AppLog(category: "ReactionBus")

    public init() {}

    /// Register the enricher that runs once per reaction before fan-out.
    /// Call this once during bootstrap before any reactions fire.
    /// The `publishedAt` parameter is the timestamp captured at bus entry — pass
    /// it straight through to `FiredReaction.publishedAt` rather than calling `Date()`.
    public func setEnricher(_ enricher: @escaping ReactionEnricher) {
        precondition(self.enricher == nil, "ReactionBus: setEnricher called after enricher already set — call once during bootstrap")
        self.enricher = enricher
    }

    /// Sensors call this. The bus enriches and fans out to all subscribers.
    public func publish(_ reaction: Reaction) async {
        let publishedAt = Date()
        let fired: FiredReaction
        if let enricher {
            // Race the enricher against a 0.5 s timeout. The timeout task
            // returns nil to act as a sentinel: the first non-nil result
            // wins (enricher completed first), but if the timeout fires
            // before the enricher completes, the loop sees nil first AND
            // we cancel the in-flight enricher so the late result cannot
            // overwrite the fallback.
            let result: FiredReaction? = await withTaskGroup(of: FiredReaction?.self) { group -> FiredReaction? in
                group.addTask { await enricher(reaction, publishedAt) as FiredReaction? }
                group.addTask {
                    try? await Task.sleep(for: .seconds(0.5))
                    return nil
                }
                // First-result-wins: a non-nil from the enricher arrives
                // before the timeout → use it. A nil from the timeout
                // arrives first → cancel everything and fall back.
                let firstResult = await group.next() ?? nil
                group.cancelAll()
                return firstResult
            }
            fired = result ?? FiredReaction(reaction: reaction, clipDuration: ReactionsConfig.eventResponseDuration, soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
            if result == nil {
                log.warning("ReactionBus: enricher timed out after 0.5 s — using fallback FiredReaction")
            }
        } else {
            fired = FiredReaction(reaction: reaction, clipDuration: ReactionsConfig.eventResponseDuration, soundURL: nil, faceIndices: [0], publishedAt: publishedAt)
        }
        for continuation in subscribers.values {
            continuation.yield(fired)
        }
    }

    /// Independent stream per call. Each subscriber receives enriched events.
    ///
    /// Ownership contract:
    /// 1. The returned stream keeps a strong reference to the bus via the
    ///    continuation cleanup — the bus must outlive all active streams.
    /// 2. When a stream is cancelled, the cleanup task removes the subscriber
    ///    asynchronously on the bus actor via `removeSubscriber(_:)`.
    /// 3. The `[weak self]` capture in `onTermination` prevents the cleanup from
    ///    blocking deallocation — if the bus is already gone when the stream
    ///    terminates, the subscriber slot is simply not cleaned up, which is a
    ///    non-issue since the bus (and its `subscribers` dictionary) is already
    ///    deallocated.
    public func subscribe() -> AsyncStream<FiredReaction> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FiredReaction>.makeStream(
            bufferingPolicy: .bufferingNewest(ReactionsConfig.busBufferDepth)
        )
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeSubscriber(id) }
        }
        return stream
    }

    public func close() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    #if DEBUG
    /// Test seam — exposes the live count of registered subscriber slots so
    /// stress / leak tests can verify cleanup of dropped streams.
    public func _testSubscriberCount() -> Int { subscribers.count }
    #endif
}
