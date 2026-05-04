#if !RAW_SWIFTC_LUMP
import YameteCore
#endif

private let log = AppLog(category: "ReactiveOutput")

/// Abstract base class for all bus-consuming outputs.
///
/// ## Stimulus lifecycle
///
/// When a `FiredReaction` (stimulus) arrives:
///   1. `shouldFire` gates it — output-specific enable/kind checks.
///   2. If an action is already in flight the stimulus is **dropped** — the
///      in-flight action takes precedence. No pre-emption.
///   3. Simultaneous stimuli that arrive within the coalesce window (16 ms)
///      before the action fires **stack a multiplier**. A smack coinciding with
///      a cable-plug or a trackpad stimulus produces a proportionally stronger
///      reaction.
///   4. After the window closes: `preAction` → `action` → `postAction` fire in
///      sequence, all async. The multiplier is passed through every hook.
///
/// ## Shutdown
/// `cancelAndReset()` cancels the lifecycle task and calls `reset()` — an
/// unconditional state restore used by `Yamete.shutdown()`.
@MainActor
open class ReactiveOutput {
    private var lifecycleTask: Task<Void, Never>?

    // Coalesce accumulator: pending stimulus + stacked multiplier.
    private var pendingFired: FiredReaction?
    private var pendingMultiplier: Float = 1.0
    private var coalesceTask: Task<Void, Never>?

    // MARK: - Lifecycle hooks (all async)

    /// Capture system state before firing (brightness, volume, gamma, etc.)
    open func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async { }

    /// Execute the reaction. Runs for ~`fired.clipDuration`.
    /// Check `Task.isCancelled` in animation loops — `cancelAndReset()` on shutdown
    /// will cancel this task.
    open func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async { }

    /// Restore system state. Called only on natural completion — never after a
    /// `cancelAndReset()` call so it does not race with `reset()`.
    open func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async { }

    /// Unconditional state restore called by the orchestrator at shutdown.
    open func reset() { }

    // MARK: - Gating

    open func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool { false }

    // MARK: - Shutdown

    public final func cancelAndReset() {
        coalesceTask?.cancel()
        coalesceTask = nil
        pendingFired = nil
        pendingMultiplier = 1.0
        lifecycleTask?.cancel()
        lifecycleTask = nil
        reset()
    }

    // MARK: - Bus consumption

    public final func consume(from bus: ReactionBus, configProvider: OutputConfigProvider) async {
        let stream = await bus.subscribe()
        for await fired in stream {
            // Reactions master kill switch overrides every per-output gate
            // when the user has flipped it off in the menu. The override is
            // checked here (not in each subclass's `shouldFire`) so every
            // output respects it without per-class wiring.
            guard configProvider.reactionsMasterIsOn() else { continue }
            guard shouldFire(fired, provider: configProvider) else { continue }

            // Drop-not-cancel: if a lifecycle is already running (preAction/action
            // /postAction sequence in flight), drop the new stimulus. The running
            // action takes precedence; no pre-emption.
            guard lifecycleTask == nil else { continue }

            if pendingFired != nil {
                // Another stimulus already queued in the coalesce window — stack.
                pendingMultiplier = min(2.0, pendingMultiplier + fired.intensity * 0.5)
                log.debug("activity:Coalesce stacked multiplier=\(String(format:"%.2f", pendingMultiplier))")
            } else {
                pendingFired = fired
                pendingMultiplier = 1.0
            }

            // (Re)schedule the coalesce fire after 16 ms.
            coalesceTask?.cancel()
            let snapshot = fired   // capture current stimulus for the closure
            coalesceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }

                guard let pending = self.pendingFired else { return }
                let multiplier = self.pendingMultiplier
                self.pendingFired = nil
                self.pendingMultiplier = 1.0
                self.coalesceTask = nil
                _ = snapshot  // keep snapshot alive through the sleep

                self.lifecycleTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.preAction(pending, multiplier: multiplier, provider: configProvider)
                    await self.action(pending, multiplier: multiplier, provider: configProvider)
                    guard !Task.isCancelled else { return }
                    await self.postAction(pending, multiplier: multiplier, provider: configProvider)
                    self.lifecycleTask = nil
                }
            }
        }
    }
}
