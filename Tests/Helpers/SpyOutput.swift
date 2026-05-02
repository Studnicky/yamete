import Foundation
@testable import YameteCore
@testable import ResponseKit

/// Phase of a recorded ReactiveOutput call.
enum SpyPhase: String, Sendable {
    case pre
    case action
    case post
    case reset
}

/// Deterministic gate used by `MatrixSpyOutput.pauseUntil`. The spy's
/// `action()` loops on `released` and only returns once the test calls
/// `release()`. Replaces wall-clock `actionDuration` races for cells that
/// need A's lifecycle pinned in flight while B publishes.
///
/// MainActor-isolated so the bool is read/written on the same actor as
/// the spy that polls it — no cross-actor send, no atomics needed.
@MainActor
final class PauseToken {
    private(set) var released: Bool = false
    func release() { released = true }
}

/// One recorded lifecycle call.
struct SpyCall: Sendable {
    let phase: SpyPhase
    let kind: ReactionKind?
    let multiplier: Float
    let timestamp: Date
}

/// Records every ReactiveOutput lifecycle call with phase, kind, multiplier
/// and timestamp. `shouldFire` returns the public mutable `allow` (default `true`).
///
/// Named `MatrixSpyOutput` to avoid colliding with the file-private `SpyOutput`
/// in `ReactiveOutputTests.swift` — Swift's name resolution picks up the
/// internal one in this test target across files even though theirs is
/// `private` to the file.
@MainActor
final class MatrixSpyOutput: ReactiveOutput {
    private(set) var calls: [SpyCall] = []
    var allow: Bool = true
    var actionDuration: Duration = .milliseconds(2)

    /// Optional gate that, when non-nil, causes `action()` to poll until
    /// the gate flips to `true` BEFORE returning — independent of
    /// `actionDuration`. Lets tests pin A's lifecycle "in flight" for as
    /// long as they need to publish B and assert drop-not-cancel
    /// semantics deterministically, instead of racing wall-clock sleeps
    /// against slow CI hardware.
    ///
    /// Usage:
    ///   let token = PauseToken()
    ///   spy.pauseUntil = token
    ///   // publish A → action() begins, records the .action phase, then blocks
    ///   // poll spy until .action observed for A
    ///   // publish B → guaranteed in-flight, must be dropped
    ///   token.release()              // releases A
    ///
    /// When `pauseUntil` is `nil` (the default), `action()` falls back to
    /// the legacy `actionDuration` sleep — no behaviour change for cells
    /// that don't opt in.
    var pauseUntil: PauseToken?

    override func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        allow
    }

    override func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        calls.append(.init(phase: .pre, kind: fired.kind, multiplier: multiplier, timestamp: Date()))
    }

    override func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        calls.append(.init(phase: .action, kind: fired.kind, multiplier: multiplier, timestamp: Date()))
        if let token = pauseUntil {
            // Poll until released. 5 ms poll matches awaitUntil cadence and
            // keeps idle wakeups cheap; the loop yields cooperatively so
            // cancellation still propagates.
            while !token.released {
                try? await Task.sleep(for: .milliseconds(5))
            }
        } else {
            try? await Task.sleep(for: actionDuration)
        }
    }

    override func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        calls.append(.init(phase: .post, kind: fired.kind, multiplier: multiplier, timestamp: Date()))
    }

    override func reset() {
        calls.append(.init(phase: .reset, kind: nil, multiplier: 0, timestamp: Date()))
    }

    func actions() -> [SpyCall] { calls.filter { $0.phase == .action } }
    func actionKinds() -> [ReactionKind] { actions().compactMap { $0.kind } }
}

/// Variant that gates `shouldFire` on the audioConfig perReaction matrix.
/// Tests use this with `MockConfigProvider.block(kind:)` to verify matrix
/// blocking prevents action delivery.
@MainActor
final class GatedSpyOutput: ReactiveOutput {
    private(set) var calls: [SpyCall] = []
    var actionDuration: Duration = .milliseconds(2)

    override func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        provider.audioConfig().perReaction[fired.kind] != false
    }

    override func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        calls.append(.init(phase: .action, kind: fired.kind, multiplier: multiplier, timestamp: Date()))
        try? await Task.sleep(for: actionDuration)
    }

    func actionKinds() -> [ReactionKind] {
        calls.filter { $0.phase == .action }.compactMap { $0.kind }
    }
}
