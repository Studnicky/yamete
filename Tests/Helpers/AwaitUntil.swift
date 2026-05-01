import Foundation

/// Test-only timing helpers that harden async assertions against slow CI
/// hardware. Two complementary patterns:
///
/// 1. `awaitUntil(...)` polls a predicate every ~10 ms until it goes true or
///    the timeout elapses. Replaces the brittle "sleep N ms then assert"
///    pattern that breaks under load.
/// 2. `CITiming.scaled(_:)` multiplies a millisecond constant by an envelope
///    factor when running under `CI=true` (GitHub Actions sets this for
///    every step). Local runs see the original value; CI runs get a 3x
///    headroom so coalesce windows and lifecycle waits don't trip on the
///    slower x86_64 macos-15 runner.
///
/// Neither helper relaxes any test assertion — they only widen the wait
/// window the test is willing to tolerate before declaring failure.
enum CITiming {
    /// Multiplier applied on CI hosts. Computed once on first access.
    /// 3x chosen empirically: GitHub Actions macos runner is ~2-3x slower
    /// on async scheduling than an Apple Silicon dev box.
    static let envelopeMultiplier: Double = {
        ProcessInfo.processInfo.environment["CI"] == "true" ? 3.0 : 1.0
    }()

    /// Scale a millisecond constant for the current environment.
    static func scaledMs(_ ms: Int) -> Int {
        Int(Double(ms) * envelopeMultiplier)
    }

    /// Convenience: produce a `Duration` from a millisecond constant scaled
    /// for the current environment.
    static func scaledDuration(ms: Int) -> Duration {
        .milliseconds(scaledMs(ms))
    }
}

/// Polls `predicate` every `pollInterval` until it returns `true` or
/// `timeout` elapses. Returns `true` if the predicate was satisfied,
/// `false` if the timeout fired first. Caller decides whether the false
/// path is a failure or a permitted outcome.
///
/// The timeout is automatically scaled by `CITiming.envelopeMultiplier`,
/// so callers can pass local-tuned values (e.g. `1.0`) and still get
/// 3x headroom under CI.
///
/// Both the helper and the predicate are `@MainActor`-isolated. Every
/// caller in the test suite is `@MainActor`, and the predicates touch
/// MainActor-isolated spies/drivers; isolating the helper keeps the
/// closure on the main actor and avoids cross-actor sending diagnostics
/// under Swift 6 strict concurrency.
@MainActor
@discardableResult
func awaitUntil(
    timeout: TimeInterval = 1.0,
    pollInterval: Duration = .milliseconds(10),
    predicate: @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout * CITiming.envelopeMultiplier)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    // One last check after the final sleep — the predicate might have
    // become true during the trailing sleep.
    return await predicate()
}
