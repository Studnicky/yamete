# Mutation Test Catalog

This directory holds the declarative catalog used by `make mutate`
(`scripts/mutation-test.sh`) to mechanically re-verify that every
production gate in `Sources/SensorKit/` has a behavioural test cell that
catches its removal.

## Why this exists

Mutation pairs ("remove guard X → assert cell Y fails") were previously
embedded only in agent narration / PR descriptions and forgotten the
moment the agent ended. This catalog makes them executable, repeatable,
and CI-targetable. Every release should be able to run `make mutate`
and confirm `total == caught`.

## Files

- `mutation-catalog.json` — single source of truth. Each entry pairs a
  production gate (encoded as a literal `search` / `replace` snippet)
  with the XCTest method that must fail when the gate is removed.
- `README.md` — this file.

The runner is `scripts/mutation-test.sh`; the Make target is
`make mutate`.

## Catalog entry shape

```json
{
  "id": "trackpad-gesture-recency-gate",
  "targetFile": "Sources/SensorKit/TrackpadActivitySource.swift",
  "search":  "guard sinceGesture <= tapAttributionWindow else {",
  "replace": "guard sinceGesture >= -1 else {",
  "expectedFailingTest": "MatrixDeviceAttributionTests/testExternalMouseClick_doesNotFireTrackpadTap",
  "expectedFailureSubstring": "[scenario=external-mouse-click]",
  "description": "..."
}
```

Field rules:

- `id` — unique slug, kebab-case, used as a stable handle in reports.
- `targetFile` — repo-relative path under `Sources/`.
- `search` — literal byte-exact string that MUST appear exactly once in
  the target file. The runner validates uniqueness before applying the
  mutation. Line numbers are intentionally NOT used — they drift the
  moment formatting changes; a search/replace pair stays valid as long
  as the gate's surface text is preserved.
- `replace` — literal replacement string. Must keep the file
  syntactically valid Swift (the runner reports a build failure as an
  infrastructure failure, not as a caught mutation).
- `expectedFailingTest` — `XCTestClass/testMethod` form, exactly as
  passed to `swift test --filter YameteTests.<expectedFailingTest>`.
- `expectedFailureSubstring` — literal substring that MUST appear in
  the captured XCTest output for the runner to count the mutation as
  CAUGHT. Anchors the runner to the specific assertion, not just any
  failure (a build error, an unrelated XCTSkip, etc., would otherwise
  masquerade as a catch).
- `description` — one-line rationale. Shown in reports.

## Adding a new mutation

1. Pick a production guard / threshold / debounce / phase gate in
   `Sources/SensorKit/*.swift` that has no catalog entry yet. The
   stretch coverage helper (`scripts/mutation-test.sh` → see runner
   header) can identify candidates that match `guard|if|threshold|
   debounce|gate` keywords without coverage.
2. Find (or write) a matrix test cell that asserts the behaviour the
   gate enforces. The assertion message MUST contain a stable
   substring you can pin in `expectedFailureSubstring`.
3. Append an entry to `mutation-catalog.json`. Run `make mutate` and
   confirm the new entry reports CAUGHT.
4. Commit catalog and (if you wrote one) test changes. Never commit a
   mutation applied to `Sources/`.

## What the runner does

For each entry, on a clean working tree:

1. Validates that `search` is present exactly once in `targetFile`.
2. Applies the mutation via Python literal `str.replace(..., 1)`.
3. Runs `swift test --filter YameteTests.<expectedFailingTest>`.
4. Reverts via `git checkout -- <targetFile>`.
5. Asserts the test exited non-zero AND the captured output contains
   `expectedFailureSubstring`.

Outcomes:

- **CAUGHT** — exit non-zero AND substring matched. Good.
- **ESCAPED** — test passed despite mutation, or failed without the
  expected substring (catalog drift), or test wasn't found. Bad — the
  gate is unverified.
- **INFRA** — search pattern missing/non-unique, or mutated code did
  not compile. Bad — catalog must be updated.

The runner refuses to start if any `targetFile` has uncommitted
changes; the revert path would otherwise clobber unstaged work.

## Why JSON, not Swift

Co-locating the catalog as `MutationCatalog.swift` would force the
runner to spawn `swift run` (slow + circular: the runner mutates the
same package) or to parse Swift literals via fragile regex. JSON is
shell-friendly via `jq`, language-agnostic, and trivially extensible.

## Degenerate gates (intentionally un-mutated)

The `--coverage` heuristic flags every line whose surface text matches
`(guard|threshold|debounce)|^\s*if\s+!`. Some flagged lines do not
admit a meaningful mutation in the test environment — removing them
either crashes immediately, runs into a downstream gate that shadows
the deletion, or fires only on a code path the harness cannot drive
deterministically. They are listed here so reviewers can confirm none
of them is a missed coverage opportunity.

Each entry uses the form `<file>:<line>  reason`.

### `Sources/SensorKit/KeyboardActivitySource.swift`

- **`:78  guard hidManager == nil else { return }`** — Idempotency
  gate against double-init. In every test-reachable configuration,
  callers construct the source with `enableHIDDetection: false` (the
  test seam at `:91` short-circuits before HID open). Removing the
  `:78` guard therefore has no observable side effect in the harness:
  the second `start()` call falls into the next gate and returns. In
  production (`enableHIDDetection: true`) a double-init would attempt
  to re-open the IOHIDManager, but `swift test` cannot exercise that
  path without TCC Input Monitoring grant.
- **`:91  guard enableHIDDetection else { ... return }`** — Test-seam
  kill switch. The whole reason this gate exists is to let tests skip
  the IOKit hop deterministically; removing it makes the test seam
  ineffective but produces no behaviour delta unless TCC Input
  Monitoring is also granted to the swift-test runner. On unattended
  CI the next gate (`:96 IOHIDCheckAccess`) catches the same case
  silently. No clean cell can pin this gate without TCC.
- **`:96  guard IOHIDCheckAccess(...) == kIOHIDAccessTypeGranted`** —
  Kernel-permission fidelity. With TCC denied (the standard CI
  configuration), removing the gate causes `IOHIDManagerOpen` to
  fail with a non-success result and the `startHID` tail bails out
  cleanly. No behaviour delta visible to tests. With TCC granted,
  removing the gate would let the source consume ambient typing —
  but ambient input is exactly what cells take pains to keep out
  via the `enableHIDDetection: false` seam, so any cell that
  required granted TCC to drive a delta would fail closed in CI.
- **`:142  log.debug("activity:KeyPress ...")`** — Trace log line
  flagged by the coverage heuristic because it contains
  "threshold". Not a gate.
- **`:194  guard result == kIOReturnSuccess, let context else { ... }`** —
  Inside the C-shaped `keyboardHIDCallback`. Reachable only from a
  real `IOHIDManager` input-value callback, which the test harness
  cannot synthesize without the same TCC grant noted above. Removing
  the guard with a non-success result or nil context would either
  return early via the `let context` binding failing, or trap on the
  unsafe pointer access — i.e. crashes immediately rather than
  producing a behaviour delta.
- **`:197  guard IOHIDElementGetUsagePage(element) == 0x07, ...`** —
  Type/payload predicate inside the same C callback. Same access-path
  argument as `:194`: cannot be driven from a test without a real
  IOHIDManager event, and the matcher set installed at `:161`
  guarantees only keyboard usage-page elements arrive at the
  callback in production, so a wrong-page event is unreachable in
  the test environment.

### `Sources/SensorKit/MouseActivitySource.swift`

- **`:84  guard scrollMonitor == nil else { return }`** — Idempotency
  gate. Removing it lets a second `start()` install a duplicate
  scroll-monitor closure in `MockEventMonitor.installed`. Both copies
  receive every emit and append to the source's `scrollWindow`, but
  the production RMS computation `sqrt(sum(v²)/n)` is invariant under
  sample duplication (the same value appearing twice yields the same
  RMS as appearing once). The click-detection path is independent of
  `scrollMonitor` and unaffected by the duplicate. Result: no
  behaviour delta is reachable for this gate via the harness.
- **`:229  guard result == kIOReturnSuccess, let context else { ... }`** —
  Inside the C-shaped `mouseClickHIDCallback`. Same access-path
  argument as the keyboard callback at `:194`: not driveable from
  tests without TCC and a real HID event source. Removing the guard
  would crash on the `let context` unwrap or the pointer
  dereference, not produce a clean behaviour delta.
- **`:232  guard IOHIDElementGetUsagePage(element) == 0x09, ...`** —
  Same C callback. Wrong-usage-page events cannot arrive in
  production because the matcher list at `:197` restricts the
  IOHIDManager to GenericDesktop-mouse pages (0x01) plus button-1
  filtering. The harness cannot drive a wrong-page event without the
  TCC grant the rest of the click pipeline needs.

### `Sources/SensorKit/TrackpadActivitySource.swift`

- **`:139  if !monitor.queryDevices(matchers: presenceMatchers).isEmpty {`** —
  Inside the static `isPresent(monitor:)` availability check, not a
  runtime gate. Removing it lets the function fall through to the
  built-in display fallback. The full presence matrix lives in
  `Tests/MatrixHardwarePresence_Tests.swift` (out of scope for this
  agent's edits) and uses `XCTAssertTrue/False` without anchor
  substrings, so no cell here can pin the gate via a catalog
  substring without modifying that file.
- **`:331  guard dur <= maxDur else { return }`** — Inside the
  contact-detection timer closure. The behaviour delta only manifests
  when `dur > contactMax`, which requires holding `phase=.mayBegin`
  past `contactMin` and reading the elapsed time. The `.mayBegin`
  phase bit does not survive the CGEvent → NSEvent bridge reliably
  on all hosts (see `testContact_mayBeginThenHeldFires`'s soft
  fallback), so any cell that depended on the timer firing would
  flake on the same hosts.
- **`:370  log.debug("activity:TrackpadScrollRMS ...")`** — Trace log
  line flagged because it contains "threshold". Not a gate.
- **`:390  guard mag > 2.0 else { return }`** — Inside
  `evaluateCircle`, gating tiny movements out of the angle-integration
  path. Catchable only via a circle-detection cell that reliably
  drives ≥15 events at smoothly varying angles through the
  CGEvent → NSEvent bridge — exactly the scenario the existing
  `testCircling_fullRevolutionFires` documents as host-fragile.
- **`:404  guard abs(circleAngleAccum) > 2 * .pi, circleEventCount >= 15 else { return }`** —
  Same circle-detection path. Removing the gate fires
  `.trackpadCircling` on partial sweeps, but the harness cannot drive
  a clean partial sweep deterministically (CGEvent quantization
  makes the integrated angle path-dependent on the host).
- **`:405  guard circlingEnabled, now >= circlingGate else { ... }`** —
  Per-mode enable + debounce gate, gated by the same circle-detection
  delivery problem as `:390` and `:404`.
- **`:425  guard !values.isEmpty else { return 0 }`** — Empty-array
  safety in `rms(_:)`. Removing it produces a divide-by-zero
  (`sqrt(0 / 0) = NaN`) which the production code then compares
  against thresholds (NaN comparisons are false), so the failure
  mode is "no reactions ever fire" — undistinguishable from
  legitimate below-threshold input. In hostile mutation conditions
  the NaN may also taint downstream RMS computations, but a clean
  cell cannot pin the gate without contriving an empty `scrollWindow`
  call site, which the public API does not admit.

## Degenerate gates

A gate is **degenerate** for mutation testing when no behavioural cell
can deterministically observe its removal from outside the production
module. Common reasons:

- The gate wraps a kernel / IOKit / CoreFoundation call whose result
  cannot be forced from a unit test (no DI seam, no protocol surface,
  no mock).
- The gate is reached only via a private C-callback (e.g. an
  IOHIDDeviceRegisterInputReportCallback handler) that cannot be
  invoked synthetically without modifying production source.
- The gate's "false" branch is structurally unreachable on real
  hardware (e.g. `mach_absolute_time` monotonicity) and the "true"
  branch is the always-taken path, so mutation produces no observable
  divergence.
- The gate is a per-iteration sentinel inside a loop over a real OS
  iterator (`IOIteratorNext` returning 0); mutating it would break
  loop termination but cannot be observed without running against the
  real driver, which the test cannot drive.

Document each degenerate gate inline below with the exact source
location and the reason no catalog entry exists. The `make mutate`
runner does not consult this section — it is a rationale anchor for
auditors and future contributors who run `--coverage` and want to
know why these gate-shaped lines are not in the JSON catalog.

### `Sources/SensorKit/AccelerometerReader.swift` — entire module

`AccelerometerReader.swift` is a self-contained IOKit / IOHIDManager
adapter for the BMI286 accelerometer on Apple Silicon. It builds its
own `IOHIDManager`, registers a C-level
`IOHIDDeviceRegisterInputReportCallback`, and runs a private
`ReportContext` that consumes the callback. Every gate listed below
sits inside one of:

- a `private enum` (`SensorActivation`, `AccelHardware`),
- a `private final class` (`ReportContext`), or
- the IOHIDManager open / iterator path that is only reachable when a
  real `AppleSPUHIDDriver` service exists in IORegistry.

There is no DI seam (the adapter takes no driver / monitor / clock
parameter), no protocol abstraction over IOHIDManager, and no
project-level mock for the IOKit surface. The closest sibling
abstraction in the codebase, `HIDDeviceMonitor`, is used by other
sources but is not threaded through `AccelerometerReader` — the file
calls IOKit directly. This makes every gate listed below degenerate
unless and until a future refactor introduces a mockable boundary.

The existing `Tests/AccelerometerLifecycleStressTests.swift` exercises
the open / close lifecycle on real hardware via
`AccelerometerSource.impacts()`, but it skips on hosts without a SPU
device (`XCTSkipUnless(adapter.hardwarePresent)`) and asserts only
that repeated open/close converges without crashing — it does not
assert any specific gate's branch was taken, so it cannot serve as
the `expectedFailingTest` for any catalog entry.

Per-gate justifications:

| Line | Gate | Degenerate because |
|------|------|--------------------|
| 152  | `if !activated { log.info(...) }` | Bare logging branch with no observable side effect. Not a behavioural gate — the body only writes a single info log. Mutating the predicate cannot be detected without parsing log files, and either branch produces a valid stream because `openStream` is invoked unconditionally on the next line. |
| 174  | `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS` (`SensorActivation.activate`) | Wraps real `IOServiceGetMatchingServices` against `AppleSPUHIDDriver`. KERN_SUCCESS is the universal outcome on supported hardware; failure modes (kIOReturnNotReady, kIOReturnNoDevice) require a missing or torn-down kext that cannot be simulated. No DI seam to inject a fake matching dictionary. |
| 180  | `guard service != 0 else { break }` (activate loop) | Iterator sentinel terminating a `while true` over `IOIteratorNext`. On real hardware the iterator yields N services and then 0; mutating to `service != -1` would loop forever (stuck test, not failing assertion). Cannot be exercised without a fake `io_iterator_t`. |
| 203  | `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS` (`SensorActivation.deactivate`) | Symmetric to gate at 174, in deactivate. Same reasoning: real IOKit call with no inject point. |
| 208  | `guard service != 0 else { break }` (deactivate loop) | Symmetric to gate at 180. Iterator sentinel; mutation manifests as a stuck loop, not a failing assertion. |
| 238  | `guard IOHIDManagerOpen(...) == kIOReturnSuccess` (`isSPUDevicePresent`) | Wraps `IOHIDManagerOpen` on a freshly-created manager. Failure (kIOReturnNotPermitted, kIOReturnExclusiveAccess) requires an entitlement / sandbox failure that cannot be forced from a test. Mutating to always-fail makes `hardwarePresent` return false; the lifecycle stress tests then skip via `XCTSkipUnless`, which is XCTSkip not XCTFail — mutation escapes. |
| 270  | `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS` (`isSensorActivelyReporting`) | Symmetric to gate 174 in the read-only probe path. Probe is consumed only by `isAvailable` in the App Store build, and the test host runs the default (Direct) build path under `swift test`, so the probe is not on the executed code path during tests. |
| 277  | `guard service != 0 else { break }` (probe loop) | Symmetric to gates 180 / 208 inside the probe iterator. |
| 286  | `guard dispatchAccel else { continue }` | Filters SPU services to the one with `dispatchAccel = Yes` (vs. gyro / temp / hinge siblings). Property is read directly from IORegistry; cannot be injected. On real hardware the gate matters (multiple SPU services exist; only one has dispatchAccel), but it's only invoked from `isSensorActivelyReporting` which is unused in the Direct build that tests run against. |
| 297  | `guard now > lastTs else { return false }` | `mach_absolute_time()` is documented monotonic, and `lastTs` is sampled from the same clock domain (`_last_event_timestamp`), so `now > lastTs` is structurally true for any in-bounds report. The `else` branch is unreachable on real hardware and mutation does not change observable output. |
| 319  | `guard openResult == kIOReturnSuccess` (`openStream` IOHIDManagerOpen) | Same as gate 238: real `IOHIDManagerOpen` result. Mutating to always-fail surfaces a `SensorError.ioKitError` on the throwing stream, but the lifecycle stress test catches via `try?` and asserts only "did not crash", so the mutation escapes the existing assertion. |
| 336  | `guard devOpenResult == kIOReturnSuccess` (`openStream` IOHIDDeviceOpen) | Same as gate 319 for the per-device open call. Real IOKit return; no mock surface; existing tests do not pin the error path. |
| 346  | `guard maxSize > 0` | Reads `kIOHIDMaxInputReportSizeKey` from a real IOHIDDevice. Always positive on real hardware (BMI286 reports 24 bytes); mutation produces an unobservable identity branch. |
| 407  | `guard snapshot.running else { return }` (watchdog) | Watchdog poll loop bail. The cleanup closure cancels the watchdog Task before invalidating the context, so by the time `running == false` could be observed, the Task is already cancelled and `Task.isCancelled` exits the outer `while`. Mutating the gate produces no observable divergence because the cancellation path wins the race. |
| 622  | `guard s.running else { return nil }` (`surfaceStall`) | Double-stall guard. Only reachable if `surfaceStall` is called twice; the watchdog calls it at most once per stream (then returns) and cleanup never calls it. Mutating to always-pass would re-finish the continuation, but `AsyncThrowingStream.Continuation.finish` is documented idempotent — the second call is a no-op — so mutation produces no observable behavioural change. |
| 630  | `guard length >= minReportLength else { return }` (`handleReport`) | Reachable only via the `IOHIDDeviceRegisterInputReportCallback` C-callback; the report buffer and length come from the kernel and cannot be synthesised from a Swift test without modifying production source to expose `handleReport` or the `ReportContext` constructor. Even on a real-hardware host with a warm sensor, the only externally-observable effect of dropping all reports is the watchdog firing after the 5 s stall threshold, which (a) is environment-dependent (cold sensors stall on un-mutated source too) and (b) requires a 7+ s wait per cell — not deterministic enough for `make mutate`. |
| 646  | `guard s.running else { return nil }` (handleReport) | Same private-callback reachability as gate 630. The lifecycle stress tests rely on this gate's "false" branch (after `ctx.invalidate()`, late-arriving callbacks must no-op), but they assert "did not crash", not "no reports were yielded after invalidate". Without a synthetic-callback seam there is no way to anchor a behavioural cell. |
| 660  | `guard s.sampleCounter % decimationFactor == 0 else { return nil }` | Same private-callback reachability as gate 630. Decimation is positionally AFTER the watchdog `lastReportAt` bump, so mutating it does not affect the watchdog at all — mutation is invisible to every external observer of `impacts()` because the only externally-visible outputs are (a) `SensorImpact` events (which require a real impact spike, untestable in a static lab) and (b) the watchdog stall (insensitive to decimation). |
| 664  | `guard rawMag > magnitudeMin && rawMag < magnitudeMax else { return nil }` | Same reasoning as gate 660. Magnitude bounds run after the `lastReportAt` bump and produce no externally-observable signal under mutation. The accelerometer at rest reads ~1 g, which is inside `[0.3, 4.0]`, so the gate is silently true on every real-hardware report and the only observable downstream effect (`SensorImpact` emission) requires an actual impact spike that cannot be staged from a static unit test. |

Summary: 19 / 19 gates in `AccelerometerReader.swift` are degenerate.
Closing them as CAUGHT requires either a refactor that exposes
`ReportContext.handleReport` for direct-call testing (or routes
through a mockable `HIDDeviceMonitor`-style seam) or an integration
harness that injects synthetic IOHIDDeviceRegisterInputReportCallback
events. Both are out of scope for the current pass — the constraint
"May NOT touch any `Sources/` file" rules out option 1, and option 2
is not feasible without first introducing a callback-injection point
that is itself a `Sources/` change.

### `Sources/SensorKit/EventSources.swift`

`EventSources.swift` hosts seven IOKit / CoreAudio / CoreGraphics
sources (`USBSource`, `PowerSource`, `AudioPeripheralSource`,
`BluetoothSource`, `ThunderboltSource`, `DisplayHotplugSource`,
`SleepWakeSource`). The `_inject*` test seams added in commit
`f21586a` give per-source debounce / dispatch coverage by yielding
through the same `streamContinuation` the IOKit callbacks yield to.
Three behavioural gates ARE catalogued (`power-edge-trigger-gate`,
`power-start-idempotency-gate`, `display-hotplug-debounce-gate`).
The remaining gate-shaped lines fall into three structurally
non-coverable buckets.

Per-gate justifications:

| Line | Gate | Source | Degenerate because |
|------|------|--------|--------------------|
| 52   | `guard notifyPort == nil else { return }` | USBSource (idempotency) | The `_injectAttach` / `_injectDetach` seams write to the latest `streamContinuation`; a leaked first stream / drainer task is invisible to the inject path. Detecting double IOKit registration requires a real-hardware fixture or a new internal seam exposing `notifyPort`; per scope rules, no `Sources/` changes. |
| 115  | `guard attachKr == KERN_SUCCESS, detachKr == KERN_SUCCESS else { ... }` | USBSource (kernel-success) | `IOServiceAddMatchingNotification` is called directly; no DI seam to make it return non-zero from a unit test. |
| 145  | `log.debug("activity:USBGated kind=\(...) — debounce")` | USBSource (trace) | Observability line in `publishTask`'s drainer; no control-flow effect, mutating the literal cannot regress behaviour. |
| 397  | `guard !listenerInstalled else { return }` | AudioPeripheralSource (idempotency) | A second start re-snapshots `knownDevices` from the host (clobbering `_testSeedKnownDevices`), making any follow-on inject diff host-dependent and non-deterministic. The seam yields to the latest `stream`, so single-publish counts match between guarded and unguarded cases. |
| 420  | `guard status == noErr else { ... }` | AudioPeripheralSource (kernel-success) | `AudioObjectAddPropertyListenerBlock` non-mockable here. |
| 537  | `guard AudioObjectGetPropertyDataSize(...) == noErr else { return [] }` | AudioPeripheralSource.snapshot | Private static helper; CoreAudio system call cannot fail without a real CoreAudio fault, which the test environment cannot inject. |
| 540  | `guard AudioObjectGetPropertyData(...) == noErr else { return [] }` | AudioPeripheralSource.snapshot | Same as line 537. |
| 552  | `guard AudioObjectGetPropertyData(...) == noErr, let value` | AudioPeripheralSource.uid | Same as line 537. |
| 564  | `guard AudioObjectGetPropertyDataSize(...) == noErr else { return nil }` | AudioPeripheralSource.name | Same as line 537. |
| 567  | `guard AudioObjectGetPropertyData(...) == noErr else { return nil }` | AudioPeripheralSource.name | Same as line 537. |
| 607  | `guard notifyPort == nil else { return }` | BluetoothSource (idempotency) | Same shape as USB line 52. |
| 659  | `guard attachKr == KERN_SUCCESS, detachKr == KERN_SUCCESS` | BluetoothSource (kernel-success) | Same shape as USB line 115. |
| 777  | `guard notifyPort == nil else { return }` | ThunderboltSource (idempotency) | Same shape as USB line 52 / Bluetooth line 607. |
| 827  | `guard attachKr == KERN_SUCCESS, detachKr == KERN_SUCCESS` | ThunderboltSource (kernel-success) | Same shape as USB line 115 / Bluetooth line 659. |
| 930  | `guard !registered else { return }` | DisplayHotplugSource (idempotency) | Second start replaces the unfair-locked `stream` reference; `_testDispatchDebounced` / `_injectReconfigure` yield to the latest, so the leaked first drainer task is invisible. `lastFire` lives at instance scope (not start-scope), so debounce state is preserved either way. |
| 1034 | `guard rootPort == 0 else { return }` | SleepWakeSource (idempotency) | Same shape; `_injectWillSleep` / `_injectDidWake` yield through `handleWillSleep` / `handleDidWake` to the latest `stream`. |
| 1061 | `guard connect != 0, let port else { ... }` | SleepWakeSource (kernel-success) | `IORegisterForSystemPower` is called directly; failure path requires kernel registration to fail, not faultable in unit tests. |

`PowerSource`'s `runLoopSource == nil` guard at line 278 is the lone
catalogued idempotency entry — PowerSource is the one source whose
`start` re-seeds an edge-trigger baseline (`lastWasOnAC = currentlyOnAC()`),
which IS observable through the inject path (see
`testStartIsIdempotent_preservesEdgeBaseline`).

These gates remain enforced in production and are exercised on real
hardware every time the app launches; they are intentionally not
included in `make mutate`'s caught-count budget.

Summary: 17 of 20 gate-shaped lines in `EventSources.swift` are
degenerate per the table above; 3 are catalogued
(`power-edge-trigger-gate`, `power-start-idempotency-gate`,
`display-hotplug-debounce-gate`). 0 behavioural gates remain
un-mutated.

### `Sources/SensorKit/ImpactDetector.swift`

The five threshold gates in `ImpactDetector.process` (warmup, spike,
rise rate, crest factor, confirmations) are ALL behavioural and ALL
catalogued. Each has a dedicated cell in
`Tests/MatrixImpactDetector_Tests.swift` that calibrates every other
gate permissively so the gate under test is the sole decider of the
outcome:

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `impact-detector-warmup-gate` | 129 | `testWarmupGate_belowSampleCount_returnsNil` |
| `impact-detector-spike-threshold-gate` | 132 | `testSpikeGate_belowThreshold_returnsNil` |
| `impact-detector-rise-rate-gate` | 141 | `testRiseRateGate_gradualRamp_returnsNil` |
| `impact-detector-crest-factor-gate` | 150 | `testCrestFactorGate_elevatedBackground_returnsNil` |
| `impact-detector-confirmations-gate` | 158 | `testConfirmationsGate_singleSample_returnsNil` |

No degenerate gates. 5 / 5 gates catalogued.

### `Sources/SensorKit/ImpactDetection.swift`

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `impact-fusion-empty-available-gate` | 85 | `ImpactFusionAvailabilityGateTests/testStartWithNoAvailableSources_invokesOnError_doesNotMarkRunning` |
| `impact-fusion-rearm-gate` | 161 | `ImpactFusionTests/testFusionRearmGate_withinRearm_returnsNil` |
| `impact-fusion-consensus-gate` | 168 | `ImpactFusionTests/testFusionConsensusGate_singleSource_belowRequired_returnsNil` |

Per-gate degenerate justifications:

| Line | Gate | Degenerate because |
|------|------|--------------------|
| 135  | `guard isRunning else { return }` (`stop()`) | Idempotency gate. `stop()` is a void function with no return value; removing the guard re-runs `task.cancel()` / `continuation.finish()` on already-finished tasks, which Swift Concurrency documents as no-ops. There is no externally-observable signal — the test would have to assert "stop did not double-invalidate", which the harness cannot prove without exposing private state. |

3 of 4 gates catalogued (3 behavioural + 1 degenerate idempotency).

### `Sources/SensorKit/HeadphoneMotionAdapter.swift`

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `headphone-motion-framework-available-gate` | 133 | `HeadphoneMotionSourceLifecycleTests/testFrameworkUnavailableThrowsDeviceNotFound` |
| `headphone-motion-disconnect-prune-gate` | 150 | `HeadphoneMotionSourceLifecycleTests/testDisconnectMidStreamPrunes` |

Per-gate degenerate justifications:

| Line | Gate | Degenerate because |
|------|------|--------------------|
| 89   | `guard driver.isDeviceMotionAvailable else { return }` (`startConnectionProbe`) | Probe-only gate. The probe runs once at adapter construction and only logs / flips a private `probeStage`. With no real headphones the probe stops itself silently after 400 ms. Removing the gate calls `driver.startUpdates` on a framework that reports motion unavailable; the mock driver's `startUpdates` is unconditional, so observable state (`isAvailable`, `impacts()` outcome) is unchanged because the downstream gate at line 133 still throws on the actual stream open. |
| 104  | `guard stage == .running else { return false }` (probe stop closure, inside `withLock`) | Internal state-machine guard inside the deferred probe-stop closure. Removing it lets the closure call `driver.stopUpdates()` even after `impacts()` took the manager over (`stage == .takenOver`), but `stopUpdates` on a mock that's already been re-driven by the impact handler installs a fresh handler-nil and the impact stream simply re-engages on the next sample. No externally-observable behaviour delta from a synthetic test — the timing window between probe-end and impacts() takeover is ~400 ms, and the mock driver does not model the race. |

2 of 4 gate-shaped lines catalogued; 2 are degenerate per the table.

### `Sources/SensorKit/MicrophoneAdapter.swift`

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `microphone-invalid-format-gate` | 91 | `MicrophoneSourceLifecycleTests/testInvalidInputFormat_throwsDeviceNotFound_doesNotInstallTap` |

Per-gate degenerate justifications:

| Line | Gate | Degenerate because |
|------|------|--------------------|
| 104  | `guard frameLength > 0 else { return }` (tap callback) | Defensive zero-frame guard inside the `installTap` callback. The mock microphone driver's `emit(buffer:)` is the only path that delivers buffers in tests; an `AVAudioPCMBuffer` with `frameLength == 0` has nothing to read, so removing the gate falls into the empty `for i in 0..<0` loop with `peak == 0`. The downstream HP filter on `peak == 0` still produces ~0, the detector rejects it (sub-threshold), and no impact is yielded — the gate's removal is observationally identical to the gate's presence. |

1 of 2 gate-shaped lines catalogued; 1 is degenerate per the table.

### `Sources/SensorKit/HIDDeviceMonitor.swift`

No behavioural gates catalogued. Both gate-shaped lines in
`RealHIDDeviceMonitor` are degenerate because the file's only consumers
are static `isPresent(monitor:)` helpers on the activity sources, and
those helpers always pass non-empty matcher lists and run on hosts
where `CGGetOnlineDisplayList` returns ≥ 0.

Per-gate degenerate justifications:

| Line | Gate | Degenerate because |
|------|------|--------------------|
| 83   | `guard !matchers.isEmpty else { return [] }` (`queryDevices`) | Defensive empty-input gate. Every production caller (`TrackpadActivitySource.presenceMatchers`, etc.) is a non-empty static array — the empty-matchers branch is structurally unreachable from the production graph. Removing the guard with an empty matcher array would call `IOHIDManagerSetDeviceMatchingMultiple` with an empty CFArray, which IOKit treats as "match nothing" and returns an empty device set anyway. No externally-observable delta. |
| 102  | `guard onlineCount > 0 else { return false }` (`hasBuiltInDisplay`) | Defensive zero-display fast-path. CoreGraphics's `CGGetOnlineDisplayList(0, nil, &onlineCount)` populates `onlineCount` with the number of online displays. On every test host (real Mac, headless CI runner with synthetic display, sandboxed virtualized macOS) this is ≥ 1, so the `else` branch is unreachable. Removing the gate still falls through to the `prefix(0).contains` check on an empty array, which returns false — same observable result. The gate exists for hosts that genuinely report zero displays (rare), which the harness cannot synthesize without modifying CoreGraphics. |

0 of 2 gate-shaped lines catalogued; both are degenerate per the
table. There are no behavioural gates in `HIDDeviceMonitor.swift` —
the file is a thin IOKit shim with no thresholds, debounces, or
attribution decisions.
