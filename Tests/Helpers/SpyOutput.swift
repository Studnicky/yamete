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

    override func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        allow
    }

    override func preAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        calls.append(.init(phase: .pre, kind: fired.kind, multiplier: multiplier, timestamp: Date()))
    }

    override func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        calls.append(.init(phase: .action, kind: fired.kind, multiplier: multiplier, timestamp: Date()))
        try? await Task.sleep(for: actionDuration)
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
