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
`IOHIDDeviceRegisterInputReportCallback`, and runs a `ReportContext`
that consumes the callback.

The 19 gates flagged by `--coverage` now split as **18 catalogued / 1
degenerate** after the Phase 4 kernel-driver seam was added on top of
the original `Tests/MatrixAccelerometerReader_Tests.swift` seam. The
seam comprises four production changes:

- `ReportContext` (and its `init`, `handleReport`, `invalidate`,
  `surfaceStall`, `watchdogSnapshot`) was raised from `private` to
  `internal`. Cells can now construct a context, build a synthetic HID
  payload (24 bytes with `Int32` axes at offsets 6/10/14), and drive
  `handleReport` directly, which makes every gate inside `handleReport`
  observable from a unit test.
- The watchdog's per-tick decision was extracted into the pure helper
  `AccelHardware.evaluateWatchdogTick(snapshot:now:stallThreshold:)`,
  isolating the `running` gate from the surrounding `Task.detached`.
- The activity probe's per-service decision (the `dispatchAccel`
  filter and the `now > lastTs` monotonicity check) was extracted into
  `AccelHardware.evaluateActivity(...)`, replacing the inline
  IORegistry-coupled iterator body. The wrapping subtraction in that
  helper uses `&-` so a mutation that removes the monotonicity guard
  decodes deterministically as `.stale` instead of trapping the
  process on `UInt64` underflow — this keeps the gate observable from
  a unit test without a SIGTRAP signal escaping the harness.
- **Phase 4** added an `AccelerometerKernelDriver` protocol with a
  default `RealAccelerometerKernelDriver` (forwards 1:1 to IOKit) and
  a `MockAccelerometerKernelDriver` (`Tests/Mocks/`) that lets cells
  force per-call failure codes (`forceMatchingFailureKr`,
  `forceManagerOpenFailure`, `forceDeviceOpenFailure`,
  `forceMaxReportSizeZero`, etc.). `AccelerometerSource` got a public
  convenience init plus an internal designated init that accepts the
  driver injection; `SensorActivation`, `AccelHardware.isSPUDevicePresent`,
  `AccelHardware.isSensorActivelyReporting`, `AccelHardware.openStream`,
  and `AccelHardware.findSPUDevice` all accept a `driver:` parameter
  with a default `RealAccelerometerKernelDriver()`, so existing
  default-arg callers (`AccelerometerSource()` in `YameteApp/Yamete.swift`
  and the lifecycle stress tests) produce byte-identical kernel
  traffic. Cells live in `Tests/MatrixAccelerometerKernelDriver_Tests.swift`.

These changes are scoped to internal access for the seam parameter
threading; the public `AccelerometerSource` API and the file's IOKit
lifecycle are unchanged for default-arg callers.

Per-gate disposition:

| Line | Gate | Disposition |
|------|------|-------------|
| 152  | `if !activated { log.info(...) }` | **Degenerate** — bare logging branch with no observable side effect. Not a behavioural gate — the body only writes a single info log. Mutating the predicate cannot be detected without parsing log files, and either branch produces a valid stream because `openStream` is invoked unconditionally on the next line. |
| 174  | `guard ... == KERN_SUCCESS` (`SensorActivation.activate`) | **Catalogued (Phase 4)** as `accel-kernel-activate-matching-gate`. The cell `testActivate_matchingFailure_shortCircuitsBeforeRegistryWrites` injects `MockAccelerometerKernelDriver` with `forceMatchingFailureKr=KERN_FAILURE` and asserts both `activate=false` AND `registrySetCFProperty` was never called — removing the gate would let the loop body run on the mock's next-yielded synthetic service. |
| 180  | `guard service != 0 else { break }` (activate loop) | **Catalogued (Phase 4)** as `accel-kernel-activate-iterator-sentinel-gate`. The cell `testActivate_iteratorYieldsOneService_loopBodyExecutesThreeWrites` runs the happy-path mock (one service yielded, then 0). With the gate intact the loop body executes its three `registrySetCFProperty` writes; the mutation flips `!= 0` to `== 0` so the loop breaks before the body and the counter stays at 0. |
| 203  | `guard ... == KERN_SUCCESS` (`SensorActivation.deactivate`) | **Catalogued (Phase 4)** as `accel-kernel-deactivate-matching-gate`. Symmetric to gate 174 in the deactivate path. |
| 208  | `guard service != 0 else { break }` (deactivate loop) | **Catalogued (Phase 4)** as `accel-kernel-deactivate-iterator-sentinel-gate`. Symmetric to gate 180 in the deactivate path. The mutation flips the sentinel to `== 0`, breaking before the registry-write body runs. |
| 238  | `guard IOHIDManagerOpen(...) == kIOReturnSuccess` (`isSPUDevicePresent`) | **Catalogued (Phase 4)** as `accel-kernel-isSPUDevicePresent-managerOpen-gate`. The cell `testIsSPUDevicePresent_managerOpenFailure_returnsFalseShortCircuit` injects `forceManagerOpenFailure=kIOReturnNotPermitted`, asserts `isSPUDevicePresent=false`, and pins `hidDeviceTransportCalls=0` so a mutation that drops the gate (which would let the synthetic device pass through `findSPUDevice`) is observable. |
| 270  | `guard ... == KERN_SUCCESS` (`isSensorActivelyReporting`) | **Catalogued (Phase 4)** as `accel-kernel-isSensorActivelyReporting-matching-gate`. Mock forces `KERN_FAILURE`; cell asserts both `reporting=false` and `iteratorNextCalls=0`. |
| 277  | `guard service != 0 else { break }` (probe loop) | **Catalogued (Phase 4)** as `accel-kernel-isSensorActivelyReporting-iterator-sentinel-gate`. Mock yields one synthetic service then 0; with the gate intact the loop body's two `registryCreateCFProperty` calls (`dispatchAccel`, `DebugState`) execute. The mutation breaks early and the counter stays at 0. |
| 286  | `guard dispatchAccel else { return .skip }` (now in `AccelHardware.evaluateActivity`) | **Catalogued** as `accel-activity-dispatchAccel-gate`. The gate moved from inline-iterator into the pure helper `evaluateActivity`; the cell `testEvaluateActivity_dispatchAccelFalse_returnsSkip` calls the helper directly and pins the `.skip` decode. |
| 297  | `guard now > lastTs else { return .clockNonMonotonic }` (now in `AccelHardware.evaluateActivity`) | **Catalogued** as `accel-activity-clock-monotonicity-gate`. The cell `testEvaluateActivity_clockNotMonotonic_returnsClockNonMonotonic` synthesises a non-monotonic snapshot directly. The wrapping `&-` subtraction in the helper means a mutation that removes the gate decodes as `.stale` (huge wrapped delta past `stalenessNs`), avoiding a SIGTRAP that would mask the catch as INFRA. |
| 319  | `guard openResult == kIOReturnSuccess` (`openStream` IOHIDManagerOpen) | **Catalogued (Phase 4)** as `accel-kernel-openStream-managerOpen-gate`. The cell `testOpenStream_managerOpenFailure_surfacesIoKitErrorShortCircuit` injects `forceManagerOpenFailure=kIOReturnNotPermitted`, asserts the stream throws `SensorError.ioKitError`, and pins `hidDeviceOpenCalls=0` so a mutation that drops the gate (and lets execution continue past the failure) is observable. |
| 336  | `guard devOpenResult == kIOReturnSuccess` (`openStream` IOHIDDeviceOpen) | **Catalogued (Phase 4)** as `accel-kernel-openStream-deviceOpen-gate`. The cell `testOpenStream_deviceOpenFailure_surfacesIoKitErrorShortCircuit` injects `forceDeviceOpenFailure=kIOReturnNotPermitted` and pins `hidDeviceMaxReportSizeCalls=0`. |
| 346  | `guard maxSize > 0` | **Catalogued (Phase 4)** as `accel-kernel-openStream-maxSize-gate`. The cell `testOpenStream_maxSizeZero_surfacesIoKitError` injects `forceMaxReportSizeZero=true` and asserts the surfaced error message exactly equals `String(format: "0x%08x", kIOReturnInternalError)` — pinning the gate-thrown error rejects the watchdog-stall fall-through path that a mutation removing the gate would otherwise produce after the 5s watchdog threshold. |
| 407  | `guard snapshot.running else { return .invalidated }` (now in `AccelHardware.evaluateWatchdogTick`) | **Catalogued** as `accel-watchdog-running-gate`. The watchdog poll body's running check moved from inline-Task into the pure helper `evaluateWatchdogTick`; the cell `testWatchdogTick_invalidatedSnapshot_returnsInvalidated` calls the helper directly and pins the `.invalidated` decode. |
| 622  | `guard s.running else { return nil /* already-stalled */ }` (`surfaceStall`) | **Catalogued** as `accel-surfaceStall-running-gate`. The cell `testSurfaceStall_afterInvalidate_yieldsNothing` invalidates the context (running = false) and then calls `surfaceStall(error)`. With the gate, the consumer sees no error; without the gate, the spurious error reaches the consumer and the cell flags it. |
| 630  | `guard length >= minReportLength else { return }` (`handleReport`) | **Catalogued** as `accel-handleReport-length-floor`. The cell `testHandleReport_shortPayloadBelowMin_yieldsNothing` constructs `ReportContext` directly and calls `handleReport(report:length:)` with a payload one byte below the floor. Buffer is over-allocated to 18 bytes so a mutation that removes the gate does not segfault — instead it falls through to decimation + magnitude and yields a sample, which the cell pins. |
| 646  | `guard s.running else { return nil }` (handleReport) | **Catalogued** as `accel-handleReport-running-gate`. The cell `testHandleReport_afterInvalidate_yieldsNothing` invalidates the context and drives 4 reports. With the gate, no impacts yield; without it, decimation+magnitude let through 2 yields, which the cell pins. |
| 660  | `guard s.sampleCounter % decimationFactor == 0 else { return nil }` | **Catalogued** as `accel-handleReport-decimation-gate`. The cell `testHandleReport_decimation_yieldsEveryNthReport` drives 10 reports through a permissive detector and asserts exactly `10 / decimationFactor = 5` yields. Removing the gate yields on every report (10 yields), failing the equality assertion. |
| 664  | `guard rawMag > magnitudeMin && rawMag < magnitudeMax else { return nil }` | **Catalogued** as `accel-handleReport-magnitude-bounds-gate`. The cells `testHandleReport_belowMagnitudeMin_yieldsNothing` and `testHandleReport_aboveMagnitudeMax_yieldsNothing` synthesise sub-floor (each axis = 0.01 g, vector ≈ 0.017 g) and super-ceiling (each axis = 10 g, vector ≈ 17 g) payloads and assert no impacts yield. Removing the gate lets the bounded payload reach the detector. |

Summary: **18 catalogued / 1 degenerate / 19 total** after Phase 4.
The 8 originally-promoted entries (handleReport / watchdog / activity
helpers) are:

- `accel-handleReport-length-floor` (line 630)
- `accel-handleReport-running-gate` (line 646)
- `accel-handleReport-decimation-gate` (line 660)
- `accel-handleReport-magnitude-bounds-gate` (line 664)
- `accel-surfaceStall-running-gate` (line 622)
- `accel-watchdog-running-gate` (line 407)
- `accel-activity-dispatchAccel-gate` (line 286)
- `accel-activity-clock-monotonicity-gate` (line 297)

#### Now CAUGHT (Phase 4 — kernel-driver seam)

Phase 4 added the `AccelerometerKernelDriver` protocol (production
default `RealAccelerometerKernelDriver`, test double
`MockAccelerometerKernelDriver`) and threaded a `driver:` parameter
through `SensorActivation.activate`, `SensorActivation.deactivate`,
`AccelHardware.isSPUDevicePresent`, `AccelHardware.isSensorActivelyReporting`,
`AccelHardware.openStream`, and `AccelHardware.findSPUDevice`. With
the seam, the 10 kernel-result fidelity gates that were previously
Degenerate are now CAUGHT. Cells live in
`Tests/MatrixAccelerometerKernelDriver_Tests.swift`:

- `accel-kernel-activate-matching-gate` (line 174)
- `accel-kernel-activate-iterator-sentinel-gate` (line 180)
- `accel-kernel-deactivate-matching-gate` (line 203)
- `accel-kernel-deactivate-iterator-sentinel-gate` (line 208)
- `accel-kernel-isSPUDevicePresent-managerOpen-gate` (line 238)
- `accel-kernel-isSensorActivelyReporting-matching-gate` (line 270)
- `accel-kernel-isSensorActivelyReporting-iterator-sentinel-gate` (line 277)
- `accel-kernel-openStream-managerOpen-gate` (line 319)
- `accel-kernel-openStream-deviceOpen-gate` (line 336)
- `accel-kernel-openStream-maxSize-gate` (line 346)

Mock failure knobs: `forceMatchingFailureKr`,
`forceManagerOpenFailure`, `forceDeviceOpenFailure`,
`forceMaxReportSizeZero`, `forceCopyDevicesNil`, `forceIteratorEmpty`,
`forceTransportMismatch`, `forceRegistrySetFailureKr`. Each is a
single-shot or sticky override depending on the call (matching /
manager-open / device-open are single-shot so the mock can return to
happy-path on subsequent invocations within the same cell).

Production-behaviour guarantee: the public `AccelerometerSource()`
init defaults `kernelDriver` to `RealAccelerometerKernelDriver()`,
which forwards 1:1 to IOKit. Default-arg callers — including
`Sources/YameteApp/Yamete.swift` and `Tests/AccelerometerLifecycleStressTests.swift` —
produce byte-identical kernel traffic to the pre-seam build.

#### Residual Degenerate (1)

The bare logging branch at line 152 (`if !activated { log.info(...) }`)
remains Degenerate. It is not a behavioural gate — the body only
writes a single info log, and either branch produces a valid stream
because `openStream` is invoked unconditionally on the next line.
Mutating the predicate cannot be detected without parsing log files.

### `Sources/SensorKit/EventSources.swift`

`EventSources.swift` hosts seven IOKit / CoreAudio / CoreGraphics
sources (`USBSource`, `PowerSource`, `AudioPeripheralSource`,
`BluetoothSource`, `ThunderboltSource`, `DisplayHotplugSource`,
`SleepWakeSource`). The `_inject*` test seams give per-source debounce
/ dispatch coverage by yielding through the same `streamContinuation`
the IOKit callbacks yield to.

Each source's `start()` was extended with two `#if DEBUG`-only
internal seams that close the previously-degenerate idempotency and
kernel-success gates as CAUGHT mutations:

- `_testInstallationCount: Int` — bumped on every successful
  registration. Idempotency cells call `start()` twice and assert the
  counter stays at `1`. Mutation that drops `notifyPort==nil` (or
  `!listenerInstalled` / `!registered` / `rootPort==0`) makes the
  counter increment a second time.
- `_forceKernelFailureKr: kern_return_t?` (USB / Bluetooth /
  Thunderbolt) / `_forceListenerStatus: OSStatus?`
  (AudioPeripheralSource) / `_forceRegistrationFailure: Bool`
  (SleepWakeSource) — overrides the kernel-call return value AFTER
  the real call has been issued (and any allocated resources cleaned
  up under the override). Cells set the seam BEFORE `start()`,
  drive the failure path, and assert `installCount == 0`. Mutation
  that drops the kernel-success guard runs the post-cleanup body
  with bad state, advancing the counter.

Behavioural gates catalogued (14 total, all CAUGHT):

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `power-edge-trigger-gate` | `handlePowerChange(onAC:)` | `MatrixPowerSourceTests/testRepeatedSameState_publishesOnce` |
| `power-start-idempotency-gate` | `start` (`runLoopSource==nil`) | `MatrixPowerSourceTests/testStartIsIdempotent_preservesEdgeBaseline` |
| `display-hotplug-debounce-gate` | `dispatchDebounced` | `MatrixDisplayHotplugSourceTests/testRapidFourCallbacks_debouncedToOne` |
| `usb-start-idempotency-gate` | `USBSource.start` (`notifyPort==nil`) | `MatrixUSBSourceTests/testDoubleStart_doesNotDoubleInstallNotifications` |
| `usb-kernel-success-gate` | `USBSource.start` (`attachKr/detachKr==KERN_SUCCESS`) | `MatrixUSBSourceTests/testKernelFailure_doesNotInstall` |
| `audio-peripheral-start-idempotency-gate` | `AudioPeripheralSource.start` (`!listenerInstalled`) | `MatrixAudioPeripheralSourceTests/testDoubleStart_doesNotDoubleInstallListener` |
| `audio-peripheral-kernel-success-gate` | `AudioPeripheralSource.start` (`status==noErr`) | `MatrixAudioPeripheralSourceTests/testKernelFailure_doesNotInstall` |
| `bluetooth-start-idempotency-gate` | `BluetoothSource.start` (`notifyPort==nil`) | `MatrixBluetoothSourceTests/testDoubleStart_doesNotDoubleInstallNotifications` |
| `bluetooth-kernel-success-gate` | `BluetoothSource.start` (`attachKr/detachKr==KERN_SUCCESS`) | `MatrixBluetoothSourceTests/testKernelFailure_doesNotInstall` |
| `thunderbolt-start-idempotency-gate` | `ThunderboltSource.start` (`notifyPort==nil`) | `MatrixThunderboltSourceTests/testDoubleStart_doesNotDoubleInstallNotifications` |
| `thunderbolt-kernel-success-gate` | `ThunderboltSource.start` (`attachKr/detachKr==KERN_SUCCESS`) | `MatrixThunderboltSourceTests/testKernelFailure_doesNotInstall` |
| `display-hotplug-start-idempotency-gate` | `DisplayHotplugSource.start` (`!registered`) | `MatrixDisplayHotplugSourceTests/testDoubleStart_doesNotDoubleRegister` |
| `sleepwake-start-idempotency-gate` | `SleepWakeSource.start` (`rootPort==0`) | `MatrixSleepWakeSourceTests/testDoubleStart_doesNotDoubleRegister` |
| `sleepwake-kernel-success-gate` | `SleepWakeSource.start` (`connect!=0, let port`) | `MatrixSleepWakeSourceTests/testKernelFailure_doesNotInstall` |

Truly unreachable (private static helpers — no DI seam, no public
caller path that fires the cleanup branch):

| Line | Gate | Reason |
|------|------|--------|
| `AudioPeripheralSource.snapshot:1` | `guard AudioObjectGetPropertyDataSize(...) == noErr else { return [] }` | `Self.snapshot()` is a private static helper called only from `start()`; the call hits the live system AudioObject and cannot be made to fail without a real CoreAudio fault. The empty-set fallback is structurally unreachable in the test environment. |
| `AudioPeripheralSource.snapshot:2` | `guard AudioObjectGetPropertyData(...) == noErr else { return [] }` | Same private-helper / system-call argument as above. |
| `AudioPeripheralSource.uid` | `guard AudioObjectGetPropertyData(...) == noErr, let value` | Private static helper invoked only from `snapshot()` / `name()`; no DI seam, no public caller. |
| `AudioPeripheralSource.name:1` | `guard AudioObjectGetPropertyDataSize(...) == noErr else { return nil }` | Same as `snapshot:1`. |
| `AudioPeripheralSource.name:2` | `guard AudioObjectGetPropertyData(...) == noErr else { return nil }` | Same as `snapshot:1`. |

Trace-log lines in EventSources.swift (USBSource:145
`log.debug("activity:USBGated kind=\(...) — debounce")`) are
suppressed by the `--coverage` heuristic's `LOG_RE` filter so they
no longer surface as gate candidates.

Summary: **14 catalogued / 5 truly unreachable / 19 total**. 0
Degenerate behavioural gates remain in EventSources.swift.

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
| `impact-fusion-stop-idempotency-gate` | 148 | `ImpactFusionStopIdempotencyGateTests/testStopWhenNotRunning_isNoOp` |

The `stop()` idempotency gate at line 148 was previously degenerate
(no externally-observable signal). Resolved by exposing
`ImpactFusion._testHooks` (`stopInvocationCount`,
`stopTeardownCount`, `lastStopWasNoOp`) — production updates the
counters on every invocation, the cell observes them. With the
guard removed, calling `stop()` against a not-running engine flips
`lastStopWasNoOp` from `true` to `false` and bumps
`stopTeardownCount` from 0 to 1, both of which the cell pins.

4 of 4 gates catalogued. 0 degenerate.

### `Sources/SensorKit/HeadphoneMotionAdapter.swift`

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `headphone-motion-framework-available-gate` | 133 | `HeadphoneMotionSourceLifecycleTests/testFrameworkUnavailableThrowsDeviceNotFound` |
| `headphone-motion-disconnect-prune-gate` | 150 | `HeadphoneMotionSourceLifecycleTests/testDisconnectMidStreamPrunes` |
| `headphone-probe-framework-available-gate` | 89 | `HeadphoneMotionSourceLifecycleTests/testProbeGate_frameworkUnavailable_doesNotStartUpdates` |
| `headphone-probe-stage-gate` | 73 | `HeadphoneMotionSourceLifecycleTests/testProbeStageGate_takenOver_deferredClosureIsNoOp` |

The probe-only gates at lines 89 / 73 (post-extract of the
`finishProbeIfRunning` helper) were previously degenerate. Resolved
by:

- Exposing `HeadphoneMotionSource._testCurrentProbeStage` for direct
  observation of the state machine (`pending → running → complete`
  or `running → takenOver`).
- Extracting the deferred probe-stop body into a `fileprivate`
  helper `finishProbeIfRunning()` so both the production
  `DispatchQueue.global().asyncAfter` closure and the test seam
  `_testRunDeferredProbeStop()` walk identical code. A mutation on
  the helper's guard is therefore observable from a synchronous
  test.

Cells:

- `testProbeGate_frameworkUnavailable_doesNotStartUpdates` — adapter
  init with a driver reporting `isDeviceMotionAvailable == false`
  must NOT call `driver.startUpdates`; observable as `mock.startUpdatesCalls == 0`.
- `testProbeStageGate_takenOver_deferredClosureIsNoOp` — drives
  probe → takeOver → deferred stop, asserts the closure does NOT
  re-`stopUpdates` and does NOT flip the stage to `.complete` when
  it is already `.takenOver`.
- `testProbeStageGate_running_deferredClosureStops` — companion cell
  that pins the true branch (`.running` → `.complete` + one
  stopUpdates).

4 of 4 gates catalogued. 0 degenerate.

### `Sources/SensorKit/MicrophoneAdapter.swift`

| Catalog id | Source line | Anchor cell |
|------------|-------------|-------------|
| `microphone-invalid-format-gate` | 91 | `MicrophoneSourceLifecycleTests/testInvalidInputFormat_throwsDeviceNotFound_doesNotInstallTap` |
| `microphone-frame-length-gate` | 104 | `MicrophoneSourceLifecycleTests/testFrameLengthGate_validBuffers_yieldImpact` |

The `frameLength > 0` gate at line 104 was previously degenerate via
"removing the guard with a zero-frame buffer is a no-op anyway".
Resolved by reframing the mutation: instead of removing the guard,
slam it shut (`frameLength <= 0` → "drop everything"). The cell
drives a sequence of strong-transient buffers (256-frame buffer with
amplitude-0.8 rising sine) through a permissive detector and
asserts at least one impact is yielded; with the gate inverted the
loop short-circuits before the peak / detector pipeline runs and
zero impacts are emitted.

2 of 2 gates catalogued. 0 degenerate.

### `Sources/SensorKit/HIDDeviceMonitor.swift`

No catalog entries. Both gate-shaped lines are **truly unreachable**
defensive guards on inputs that no caller can produce — see the
"Truly unreachable gates" section below for citations.

## Truly unreachable gates

A gate is **truly unreachable** when the input that would drive it to
the false branch cannot be produced by any caller in the production
graph. These are kept in production source as defense-in-depth, but
no behavioural cell can pin them because their false branch is not
reachable from the public API. They are explicitly NOT entered in
`mutation-catalog.json` (the runner only verifies CAUGHT gates) and
are listed here so reviewers can see the full population of gate
shapes and the citations justifying each unreachability claim.

### `Sources/SensorKit/HIDDeviceMonitor.swift:83`

```swift
public func queryDevices(matchers: [HIDMatcher]) -> [HIDDeviceInfo] {
    guard !matchers.isEmpty else { return [] }
    ...
}
```

**Citation — every caller passes a non-empty static matcher list:**

- `Sources/SensorKit/TrackpadActivitySource.swift:127` — `presenceMatchers`
  is a `nonisolated public static let` array literal with 2 entries
  (digitizer-touchpad usage page + Magic Trackpad product). Construction
  is at module-load time, immutable.
- `Sources/SensorKit/TrackpadActivitySource.swift:139` — call site:
  `monitor.queryDevices(matchers: presenceMatchers)`.
- `Sources/SensorKit/MouseActivitySource.swift:59` — `presenceMatchers`
  is a static let with 1 entry (GenericDesktop mouse, usage 0x02).
  Call site at `:69`.
- `Sources/SensorKit/KeyboardActivitySource.swift:55` — `presenceMatchers`
  is a static let with 1 entry (GenericDesktop keyboard, usage 0x06).
  Call site at `:62`.
- `Tests/Integration/HIDPresenceRealDriverTests.swift` — every test
  call passes one of the static matcher lists above.

The gate's false branch (`matchers.isEmpty`) is therefore unreachable
from any production or test caller. Removing the gate would call
`IOHIDManagerSetDeviceMatchingMultiple` with an empty CFArray, which
IOKit treats as "match nothing" and returns an empty device set —
identical observable result to the gate being present. The gate
exists as defense-in-depth against future callers but cannot be
exercised today.

### `Sources/SensorKit/HIDDeviceMonitor.swift:102`

```swift
public func hasBuiltInDisplay() -> Bool {
    var onlineCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &onlineCount)
    guard onlineCount > 0 else { return false }
    ...
}
```

**Citation — `CGGetOnlineDisplayList` returns >= 1 on every supported host:**

- macOS WindowServer-backed processes (every `swift test` host, including
  GitHub Actions `macos-14` / `macos-15` runners and the project's
  hosted self-runners) always have at least one online display. CoreGraphics
  populates `onlineCount` with the number of currently-online displays;
  zero implies WindowServer is not running, which a Swift unit test
  process cannot reach.
- Apple's `CGGetOnlineDisplayList` documentation: "An online display is
  attached, awake, and available for drawing operations. ... There is
  always at least one display online."
  (https://developer.apple.com/documentation/coregraphics/1455522-cggetonlinedisplaylist)
- Sandboxed virtualised macOS (the App Store build's runtime) and the
  Direct build's runtime both run inside Aqua, which guarantees a
  WindowServer connection. A test process running outside Aqua (e.g. via
  `launchd` user-domain agent during boot) is the only known scenario
  with `onlineCount == 0`, and that scenario cannot host an `XCTest`
  invocation — `XCTest` requires `NSApplication` initialization which
  itself bootstraps Aqua.
- The `Tests/Integration/HIDPresenceRealDriverTests.swift` cells call
  `monitor.hasBuiltInDisplay()` and gate the assertion via `guard ...`
  / `XCTSkip`, which would correctly skip if `onlineCount == 0` ever
  did occur — but it does not.

The gate's false branch is therefore structurally unreachable from
the test harness. Removing the gate still falls through to the
`prefix(0).contains` check on an empty array (which returns false),
so the observable result matches the gate's true branch. The gate
exists as defense-in-depth for the rare boot-time scenario but
cannot be exercised by `swift test`.

### Tally

- `Sources/SensorKit/ImpactDetection.swift` — 0 truly unreachable.
- `Sources/SensorKit/HeadphoneMotionAdapter.swift` — 0 truly unreachable.
- `Sources/SensorKit/MicrophoneAdapter.swift` — 0 truly unreachable.
- `Sources/SensorKit/HIDDeviceMonitor.swift` — 2 truly unreachable
  (lines 83, 102).

Total: 2 truly unreachable gates across the four files in scope. 0
degenerate gates remain.

## Property-based cells

`Tests/PropertyBased_Tests.swift` complements the example-based matrix
cells with eight invariant cells driven by a hand-rolled deterministic
xorshift64 generator (`SeededGenerator`). Every cell loops over a fixed
seed range, constructs a random input within the property's domain
from the seed, and asserts the post-condition. Failure messages cite
the seed + observed values so any regression is locally reproducible:
`swift test --filter PropertyBased_Tests/test_property_<name>` plus the
emitted `seed=N` reproduces the exact failure.

| Cell | Invariant | Trials |
|------|-----------|--------|
| `test_property_keyboard_rate_debounce_invariant` | rate < 3.0/s → 0 fires; rate ≥ 3.0/s → ≤ ⌈duration / debounce⌉ + 1 fires | 200 |
| `test_property_mouse_scroll_rms_invariant` | RMS far below threshold → 0 fires; RMS far above → ≥ 1 fire (CGEvent quantization tolerated as a documented synthetic-event limitation) | 50 below × 50 above |
| `test_property_trackpad_attribution_invariant` | clicks WITHOUT a recent trackpad gesture (lastTrackpadGestureAt = .distantPast) → never fire `.trackpadTapping` regardless of click count / spacing | 200 |
| `test_property_usb_debounce_per_key_invariant` | for distinct (vendor, product) pairs interleaved with repeats: distinctCount ≤ fires ≤ totalCalls (every distinct key fires at least once; debounce never synthesizes fires beyond injections) | 200 |
| `test_property_bus_delivery_order_invariant` | for a single producer's `_injectAttach` / `_injectDetach` sequence with distinct keys: bus delivery order matches publish order | 200 |
| `test_property_bus_delivery_completeness_invariant` | for accept-by-gate sequences with distinct keys: bus emissions == issued publishes | 200 |
| `test_property_coalesce_window_monotonicity_invariant` | for same-key bursts within debounce: emissions ≤ injections AND ≥ 1 | 200 |
| `test_property_per_mode_disabled_invariant` | for each disabled trackpad mode (touching/sliding/contact/tapping/circling): no fires of that kind under any random input shape | 40 outer × 5 modes |

Determinism: the generator is hand-rolled xorshift64 with seed-as-state
(no `SystemRandomNumberGenerator`, no `arc4random`, no `Foundation`
random APIs). Same seed N produces the same sequence on every host,
every run, every CI shard.

The existing 69 catalog entries already pin the gates these properties
exercise (see e.g. `keyboard-rate-threshold-default`,
`trackpad-gesture-recency-gate`, `usb-debounce` family). Property
cells are kept out of the catalog because each one runs 50–200 trials
per invocation; co-opting them as mutation anchors would inflate
`make mutate` runtime without adding catch-coverage beyond the
example-based cells already linked from the catalog.

## Concurrent / interleaved cells

`Tests/MatrixConcurrentInterleaved_Tests.swift` complements the
serial example-based matrix and the loop-based property suite with
eight cells that drive ≥ 2 production paths CONCURRENTLY via plain
`Task` spawning, then assert cross-source invariants on the resulting
bus traffic. The bug class addressed: existing matrix cells exercise
ONE source at a time. Real users drive many at once — typing while
plugging USB while the system goes to sleep. Concurrency-related
races (cross-source state corruption, debounce gate bleed-through,
bus-publish ordering under contention, close-during-publish crashes,
fan-out skew across subscribers) cannot be exercised by serial cells.

Each cell asserts a SPECIFIC invariant tagged with a
`[concurrent-cell=<name>]` substring anchor for grep-friendly
failure triage. Each cell is budgeted at ≤ 200 ms wallclock.

| Cell | Invariant |
|------|-----------|
| `test_concurrent_cell_cross_source_debounce_sanity` | concurrent USB attach + BT connect → both fire exactly once on the bus, total = 2 deliveries |
| `test_concurrent_cell_trackpad_gesture_during_external_click_burst` | 5 USB-mouse clicks debounce to 1 `.mouseClicked`; interleaved phased trackpad scrolls fire `.trackpadTouching` ≥ 1; no cross-source pollination |
| `test_concurrent_cell_usb_attach_mid_keyboard_burst` | 10 above-threshold key injects fire ≥ 1 `.keyboardTyped`; mid-burst USB attach fires exactly 1 `.usbAttached`; no cross-source pollination |
| `test_concurrent_cell_sleep_mid_trackpad_tap` | sleep injection mid-trackpad-gesture emits exactly 1 `.willSleep` and does not crash the trackpad pipeline |
| `test_concurrent_cell_bus_close_mid_publish_race` | 100 mixed injects raced against `bus.close()` produce no crash, exactly one stream terminator per subscriber, and bounded delivery (≤ 100, never duplicated) |
| `test_concurrent_cell_coalesce_window_stress` | 50 same-key `_injectClick` calls back-to-back collapse to exactly 1 `.mouseClicked` (within debounce window) |
| `test_concurrent_cell_multi_output_fanout_under_producer_race` | 5 independent subscribers attached to the SAME bus see identical per-kind multisets when concurrent producers (USB / BT / keyboard) drive injects in parallel — no fan-out skew across subscribers |
| `test_concurrent_cell_stable_interleaving_fuzz` | for seeds 42 / 7 / 31 (200 random injects each across 5 sources): no crash, no kind cross-pollination, deliveries upper-bounded by injections (no amplification), and every producer that fired ≥ 1 inject delivers ≥ 1 event (no total starvation) |

Determinism: the fuzz cell uses the same hand-rolled xorshift64
generator pattern as the property suite. Same seed N produces the
same inject plan on every host, every run, every CI shard. The
inject plan is pre-rolled BEFORE the concurrent task spawn so the
expected counts are derived from the plan, not from the race.

Concurrency strategy: plain `Task { @MainActor in ... }` spawning
plus `await task.value` per child. `withTaskGroup` was tried first
but the strict-concurrency region-based isolation checker rejects
the pattern when `addTask` closures re-enter `@MainActor` and
capture source variables — see the matching pattern in
`Tests/MatrixMultiOutputConcurrentFire_Tests.swift`. The plain-Task
pattern compiles clean against `-strict-concurrency=complete`
`-warnings-as-errors`.

Why `≤ injections` (not strict equality) on the fuzz cell: under
200-burst pressure, the `ReactionBus` subscriber buffer
(`bufferingNewest(8)`) and the upstream source streams
(`bufferingNewest(32)` for USB / BT / SleepWake) legitimately drop
oldest entries — this is the documented backpressure policy, not a
bug. The cell asserts `delivered ≤ injected` (no amplification) and
liveness (every producer that fired delivers ≥ 1) without committing
to strict equality the buffer policy explicitly does not promise.

These cells are NOT in `mutation-catalog.json` for the same reason
property cells aren't: they are integrative invariants that span
multiple gates simultaneously, so a single mutation typically
manifests as a SUBSET of cells failing — which would produce
catalog-anchor drift under `make mutate`'s strict
`expectedFailureSubstring` matching. The existing 69 catalog
entries already pin the per-gate behaviour; the concurrent suite is
a regression net for cross-gate races, not a per-gate anchor.

## Cross-boundary fault cells

`Tests/CrossBoundaryFaultInjection_Tests.swift` complements the
per-source `_force*` mutation cells with eight cells that drive ≥ 2
production fault paths SIMULTANEOUSLY. Bug class addressed: existing
seams (USB / Bluetooth / Thunderbolt `_forceKernelFailureKr`,
AudioPeripheral `_forceListenerStatus`, SleepWake
`_forceRegistrationFailure`, AccelerometerKernelDriver
`setForceManagerOpenFailure`, etc.) drive ONE source's failure path
in isolation. Real systems fail across boundaries simultaneously
(USB hot-unplug while microphone is starting; sleep
mid-`IORegisterForSystemPower`; AudioPeripheral listener install
rejected during a USB attach storm). A regression where one source's
failure path corrupts a sibling's state would slip through the
per-source cells.

Each cell asserts a SPECIFIC invariant tagged with a
`[crossfault-cell=<name>]` substring anchor. Each cell is budgeted
at ≤ 500ms wallclock.

| Cell | Invariant |
|------|-----------|
| `test_crossfault_cell_usb_fail_during_bt_fail_simultaneous` | concurrent USB + BT kernel-failure injection → both `_testInstallationCount` stay 0; bus has no emissions; neither source crashes |
| `test_crossfault_cell_accel_open_fail_during_mic_start` | `MockAccelerometerKernelDriver.setForceManagerOpenFailure` while `MicrophoneSource` starts → 0 accelerometer impacts, microphone tap installed exactly once independent of accelerometer fault |
| `test_crossfault_cell_sleepwake_fail_during_iohid_flood` | 100 USB attaches concurrent with `SleepWakeSource._forceRegistrationFailure` → SleepWake installCount=0, no `.willSleep` / `.didWake`, USB attaches still publish |
| `test_crossfault_cell_audio_listener_fail_during_usb_flood` | AudioPeripheral `_forceListenerStatus` non-noErr during 30-attach USB burst → AudioPeripheral installCount=0, no audio emissions, USB attaches still publish |
| `test_crossfault_cell_all_iokit_sources_fail` | every IOKit source (USB / BT / TB / Audio / SleepWake) faulted simultaneously → all installCount=0, bus total=0, no crash |
| `test_crossfault_cell_recovery_after_fault` | source faulted then knob cleared then restarted → installCount=1 after recovery, follow-up `_injectAttach` lands at the bus |
| `test_crossfault_cell_concurrent_fault_during_in_flight_subscription` | 3 subscribers attached, healthy injects flow, faults flipped during in-flight subscription → all subscribers see identical per-kind multisets (no fan-out skew under fault) |
| `test_crossfault_cell_stable_interleaved_fault_fuzz` | for seeds 42 / 7 / 31: 2-5 random IOKit faults from the 5-source pool with 30 random injects → no crash, no kind cross-pollination, delivered ≤ injected (no amplification) |

These cells are NOT in `mutation-catalog.json` for the same reason
the concurrent / property cells aren't: they are integrative
invariants that span multiple gates simultaneously, so a single
mutation typically manifests as a SUBSET of cells failing — which
produces catalog-anchor drift under strict
`expectedFailureSubstring` matching. The existing per-source
`_force*` catalog entries already pin per-gate behaviour; the
cross-boundary suite is a regression net for cross-source state
corruption under simultaneous fault, not a per-gate anchor.

## Settings fuzz cells

`Tests/SettingsFuzz_Tests.swift` complements the example-based
`Tests/MatrixSettingsMigration_Tests.swift` matrix with eight cells
that generate arbitrary plist shapes and corrupted settings inputs,
asserting `SettingsStore.init()` survives them without throwing,
crashing, or handing back NaN. Bug class addressed: the migration
matrix only covers the *known* type-mismatch paths the example
author thought of; a fuzzer that generates random key shapes
catches the boot-time crash classes that random user upgrades —
including version skew across multiple major releases — can
produce.

| Cell | Inputs | Trials |
|------|--------|--------|
| `test_fuzz_cell1_emptyDictPlist_usesDefaults` | empty `[String: Any]()` plist (every key missing) | 1 |
| `test_fuzz_cell2_typeMismatchAllKeys_usesDefaults` | every `Key.allCases` entry written with the wrong type (Bool→String, Double→String, Int→String, Array→Int, Data→String, String→Int) | 1 |
| `test_fuzz_cell3_truncatedPlist_partialKeys_useDefaultsForMissing` | first half of `Key.allCases` written with type-correct sentinels, second half absent | 1 |
| `test_fuzz_cell4_randomBlobPlist_200trials_noCrash` | per-trial random `[String: Any]` of 0..N real keys + 0..10 garbage keys with type-roulette values (String, Int, Double incl. NaN/±∞, Bool, Array, Data) | 200 |
| `test_fuzz_cell5_migrationFromFutureVersion_doesNotCrash` | `version: 99` + `settingsSchemaVersion: 99` + `schemaVersion: "99.0.0-future"` markers under the current schema (no version field) | 1 |
| `test_fuzz_cell6_migrationFromCorruptVersion_doesNotCrash` | corrupt version markers: `-1`, `"broken"`, `""`, `Double.nan`, `[1,2,3]` | 5 |
| `test_fuzz_cell7_serializationRoundTrip_100trials` | per-trial coherent in-band settings configuration; assert write→fresh-store→read round-trip is bijective for the in-clamp domain | 100 |
| `test_fuzz_cell8_maliciousMatrixData_doesNotCrash` | 6 garbage `Data` blobs (empty, 1-byte, 4 KiB zeros, broken JSON, fake bplist magic, pseudo-random) driven through every `*ReactionMatrix` key plus the throwing `NSKeyedUnarchiver.unarchivedObject(ofClasses:from:)` API | 6 |

Determinism: the random-blob and round-trip cells use the same
hand-rolled xorshift64 `SeededGenerator` pattern as the property
suite, inlined locally to keep the file self-contained. Same seed
N produces the same plist shape on every host, every run, every CI
shard. Failure messages cite `seed=N` so any regression is locally
reproducible: `swift test --filter SettingsFuzz_Tests/test_fuzz_cell4_*`
plus the emitted seed reproduces the exact failure.

Isolation: SettingsStore reads only from `UserDefaults.standard`
(no suiteName injection in production), so each cell wipes every
`Key.allCases` entry plus the legacy `screenFlash`, `version`, and
`settingsSchemaVersion` aliases before running. Mirrors the wipe
pattern from `MatrixSettingsMigration_Tests`.

SIGSEGV note: `XCTest` cannot trap SIGSEGV in-process — the runner
reports "test crashed" rather than a failed assertion. Cell 8
asserts only that `ReactionToggleMatrix.decoded(from:)` and
`NSKeyedUnarchiver.unarchivedObject(ofClasses:from:)` return
nil-or-throw on garbage bytes, both of which ARE catchable. A
genuine SIGSEGV-class regression in the JSON / NSKeyedUnarchiver
path would surface as a CI crash report, not a per-assertion
failure.

These cells are NOT in `mutation-catalog.json` because they are
boot-time / corruption-resistance regression nets, not per-gate
anchors — the catalog's `expectedFailureSubstring` machinery
matches against single-gate mutations on `Sources/SensorKit/*`,
and `SettingsStore` lives in `Sources/YameteApp/`.

## State-machine cells

`Tests/StateMachine_Tests.swift` is a model-based companion to the
example-by-example lifecycle tests scattered across the matrix /
lifecycle suites. Each cell encodes the production state machine
exactly (states + reachable transitions), drives every transition
in a small table, asserts the post-state with a coordinate-tagged
message (`[state-machine=<Name>] from=... action=... expected=... got=...`),
and — critically — asserts that *illegal* transitions are rejected
(state unchanged, no extra side-effect counter increments).

| Cell | Production type | Transitions covered | Counters / observables |
|---|---|---|---|
| 1 | `HeadphoneMotionSource.ProbeStage` | pending → running, running → complete, running → takenOver | `_testCurrentProbeStage`, `MockHeadphoneMotionDriver.stopUpdatesCalls` |
| 2 | `HeadphoneMotionSource.ProbeStage` (illegal) | complete →* (no-op), takenOver →* (no-op) — terminal states | same |
| 3 | `ImpactFusion` | start@stopped, start@running (re-entrant), stop@running, stop@stopped (idempotent), interleaved | `isRunning`, `_testHooks.{stopInvocationCount, stopTeardownCount, lastStopWasNoOp}` |
| 4 | `ReactionBus` | open(0) → open(1) → open(2) → closed → open(1); publish-before-subscribe (no replay), close-then-publish (no-op), close-then-subscribe (re-open) | `_testSubscriberCount()` |
| 5 | `MicrophoneSource.OnceCleanup` (per-stream) | open / cancel / re-open across 5 cycles; AT MOST ONCE invariant | `MockMicrophoneEngineDriver.{stopCalls, removeTapCalls, installTapCalls}` |
| 6 | `TrackpadActivitySource` | start@stopped, double-start@running (no-op via `guard monitor == nil`), stop@running, double-stop@stopped, restart | `MockEventMonitor.{installCount, removalCount}` |

These cells are NOT in `mutation-catalog.json` because they are
model-check regression nets — they exercise transition graphs as
a whole rather than individual `guard` clauses. A specific gate
within a state-machine type (e.g., the `guard stage == .running`
in `finishProbeIfRunning`) still gets its own per-gate entry in
the catalog when one is added; the model-check cell catches the
broader "transition graph regressed" failure mode.

## Locale rendering cells

`Tests/LocaleRendering_Tests.swift` complements the existing
`MatrixLocalization_Tests` (pool injection + fallback) /
`MatrixLocalizationKeyCoverage_Tests` (key parity per locale) /
`MatrixLocalizationFormatSpecifiers_Tests` (format-specifier shape
parity per locale) with eight cells that actually RENDER strings
under each locale's CLDR plural-rule and number / date-formatter
context. The bug class addressed: a `Localizable.stringsdict`
regression that drops a CLDR plural category (e.g., Polish loses
its `few` or `many` form) would slip through the existing key /
specifier coverage tests because they never resolve a count
through Foundation's plural machinery.

Strategy:

- Discover locales from `App/Resources/*.lproj/`, same convention
  as the other matrix-localization cells. Yamete ships 40 locales,
  each with `Localizable.stringsdict`.
- Load each locale's stringsdict via `NSDictionary(contentsOf:)`
  directly (the SPM test bundle does NOT include `App/Resources/*.lproj`
  strings — those are bundled into the `.app` only by the Makefile,
  same constraint `MatrixLocalization_Tests` documents).
- Resolve the CLDR plural category for `count` ∈ {0, 1, 2, 17}
  using a hand-coded CLDR 44 rule table (Foundation does not expose
  plural rules as public API on `Locale`). The table covers every
  Yamete-supported language family.
- For RTL: probe `Locale.characterDirection(forLanguage:)` for
  `ar` / `he` / `en` and assert correct direction. Glyph probe:
  the Arabic stringsdict's `one` form must contain Arabic Unicode
  (U+0600..U+06FF) and the Hebrew form must contain Hebrew Unicode
  (U+0590..U+05FF); English form must contain neither (guards
  against bundle-load mixup).
- Date / numeric: drive `DateFormatter` (`.full` style, UTC TZ,
  fixed instant 2026-01-15 10:30 UTC) and `NumberFormatter`
  (`.decimal`, value 1234.56) under each locale; assert non-empty,
  cross-locale divergence (≥ 25 of 40 must differ from en-US),
  must-diverge-set (`ja`, `zh_CN`, `zh_TW`, `ko`, `ar`, `he`, `ru`,
  `th`, `hi` MUST differ from en-US — different scripts), and
  per-locale glyph signatures (German `1.234,56`, French `1 234,56`,
  English `1,234.56`).

| Cell | Axis tested |
|------|-------------|
| `testPluralRenderingCountZeroForEveryLocale` | plural count=0 |
| `testPluralRenderingCountOneForEveryLocale` | plural count=1 |
| `testPluralRenderingCountTwoForEveryLocale` | plural count=2 (pins Slovenian/Arabic `two`, Polish/Russian `few`) |
| `testPluralRenderingCountManyForEveryLocale` | plural count=17 (pins Polish/Russian/Ukrainian/Arabic `many`) |
| `testPolishPluralCategoriesReachableAndCorrect` | Polish-specific: drives counts 0/1/2/3/5/12/22/25 across all 4 CLDR categories (one/few/many/other); asserts category resolution AND on-disk stem (uderzenie / uderzenia / uderzeń) |
| `testRTLLocaleLayoutAndGlyphs` | RTL: `Locale.characterDirection(forLanguage:)` + Arabic/Hebrew glyph presence + LTR-locale negative |
| `testDateFormatRenderingForEveryLocale` | `DateFormatter` `.full` style under every locale; non-empty + cross-locale divergence + must-diverge set |
| `testNumericFormatRenderingForEveryLocale` | `NumberFormatter` `.decimal` under every locale; decimal separator parity + per-locale German/French/English signatures |

These cells are NOT in `mutation-catalog.json` because they
exercise CLDR-rule + Foundation-formatter behaviour, not a Yamete
production guard — there is no `Sources/SensorKit/*.swift` gate to
mutate. They are a regression net for resource-file drift
(stringsdict losing categories, locale dirs disappearing) and
Foundation API drift (plural rule selection changing across
macOS releases), not a per-gate anchor.

## Performance / soak cells

`Tests/Performance_Tests.swift` is a soak / leak / throughput
regression net that complements the functional matrix. The functional
suite asserts that the right reaction fires for the right input;
none of those cells assert anything about *cost*. A regression that
re-installed an `EventMonitor` on every gesture, leaked a `Task` per
`_injectClick`, or grew the bus subscriber dictionary without bound
would pass the functional suite for hours and only show up as
degraded user experience after sustained use.

Each cell runs lifecycle / fan-out / inject loops at counts large
enough to surface unbounded growth, then asserts:

- process resident-set size (`task_info` with `MACH_TASK_BASIC_INFO`,
  the macOS-supported equivalent of iOS's `os_proc_available_memory`)
  stays within a documented byte envelope
- mock counters (e.g. `MockEventMonitor.installCount` /
  `removalCount`) stay balanced — every install matched by a removal
- second-half-median wallclock per chunk stays within 3x first-half
  median (catches per-iter cost growing with iteration index)

| Cell | Invariant | Counters / observables |
|---|---|---|
| 1 | `TrackpadActivitySource` 1000 start/stop cycles: `installCount == removalCount` per cycle, RSS delta < 5 MB | `MockEventMonitor.installCount`, `removalCount`, `task_info.resident_size` |
| 2 | `MouseActivitySource` 1000 start/stop cycles: same balance + RSS bound | same as cell 1 |
| 3 | `ReactionBus` 10,000 publishes: `delivered <= published` (no fan-out amplification), RSS delta < 10 MB (busBufferDepth caps retention) | subscriber drain count, `task_info.resident_size` |
| 4 | Per-source `_inject*` 5,000 calls (USB / Power / Bluetooth / SleepWake / AudioPeripheral), 10 chunks of 500: second-half median <= 3x first-half median (catches sustained per-iter cost drift). Identities cycle modulo 50 because production diff-state sets are bounded by physical hardware (~5-20), not by call count | per-chunk `ProcessInfo.systemUptime` deltas |
| 5 | 20,000 `_injectClick` calls with debounce coalesce: RSS delta < 20 MB (catches orphan Task accumulation per call) | `task_info.resident_size` |
| 6 | `ReactionBus` 500 open/subscribe/close cycles: max live `_testSubscriberCount() <= 1`, RSS delta < 10 MB | `ReactionBus._testSubscriberCount()`, `task_info.resident_size` |
| 7 | `USBSource._injectAttach` x 1000 in tight loop: completes in < 5 s (10x of ~700 ms baseline catches gross regression without flaking on slower hosts) | `ProcessInfo.systemUptime` |

These cells are NOT in `mutation-catalog.json`. A mutation that
introduces a leak or a quadratic regression typically manifests as
a subset of cells failing on different hosts (cell 5's RSS bound is
sensitive to scheduler load; cell 4's median ratio is sensitive to
a single GC pause), so anchor matching against
`expectedFailureSubstring` would drift across CI hosts. The cells
are a **regression net** — they catch catastrophic divergence from
the documented baselines, not per-mutation single-gate failures.

A NOTE on cell 4 calibration: an earlier draft used unique UIDs per
inject and produced clean monotonic slowdown (`[0.09, 0.27, 0.52,
0.46, 0.94, 0.92, 0.91, 1.55, 1.99, 2.43]` seconds) for
`AudioPeripheralSource`. This was NOT a production bug — the test
seam's `_injectAttach` does `var nextSet = knownDevices;
nextSet.insert(uid); handleChange(newDevices: nextSet, ...)` which
is O(n) per call where n = accumulated device count. In production
n is bounded by physical hardware (~10); the test's 5000 unique
UIDs created an artificial O(n^2) the test seam was not designed
for. Cycling identity modulo 50 mirrors the real-world bound while
still hammering the hot path 5000 times. The same pattern applies
to USBSource's `lastEvent` debounce dictionary and BluetoothSource's
`knownDevices` set.

## Crash handling cells

`Tests/CrashHandling_Tests.swift` is the arithmetic-trap /
divide-by-zero / NaN-propagation / out-of-bounds-pointer audit
suite. None of the example-based or matrix tests exercised the
SIGSEGV / SIGTRAP / SIGABRT-adjacent paths before this file
landed; every cell here pins a *guard* whose removal would surface
as a process crash that takes the whole test runner down rather
than a per-assertion failure.

| Cell | Trap class | Boundary input | Pinned guard |
|---|---|---|---|
| 1 (cold-boot) | UInt64 underflow on `now &- lastTs` | `lastTsRaw=0, now=0` | `AccelHardware.evaluateActivity` `raw > 0` gate |
| 1 (clock-equal) | UInt64 underflow → wrap interpreted as fresh | `lastTs=now=1000` | `now > lastTs` gate → `.clockNonMonotonic` |
| 1 (clock-backwards) | UInt64 underflow on `now &- lastTs` | `lastTs=2e9, now=1e9` | `now > lastTs` gate → `.clockNonMonotonic` |
| 2 (trackpad NaN) | NaN propagation from `atan2(0,0)` / `hypot(0,0)` into `circleAngleAccum` | `dx=0, dy=0` × 100 samples | `evaluateCircle` `mag > 2.0` gate |
| 3 (mic zero-frame) | OOB pointer read on `channelData[i]` for empty buffer | `AVAudioPCMBuffer` with `frameLength == 0` | `installTap` closure `frameLength > 0` gate |
| 4 (impact zero-mag) | Float divide-by-zero → Inf crest poisoning gate cascade | sustained `magnitude=0.0` × 100 samples | `ImpactDetector.process` `spikeThreshold` gate (short-circuits before crest) |
| 4 (impact zero-bg) | Float divide-by-zero on first spike with empty EMA history | `intensityFloor=0`, single `magnitude=1.0` spike | `if backgroundRMS > 0` gate around `windowPeak / backgroundRMS` |
| 5 (HID 1k matchers) | Int iteration overflow / CFArray bridge cost | 1000-element matcher list | per-matcher `for` loop bounds (Int domain) |
| 6 (bus post-close) | Use-after-finish on `AsyncStream.Continuation` | `publish` after `close()` | `close()` clears subscriber dict; `publish` walks empty set |
| 7 (UInt64 wrap) | Overflow on `(now &- lastTs) &* numer` at near-max boundary | `lastTs=Int.max, now=Int.max+1, stalenessNs=UInt64.max` | `&-` / `&*` wrap-arithmetic operators |
| 8 (watchdog distant times) | TimeInterval → Int64 conversion overflow | `lastReportAt=Date.distantPast, now=Date.distantFuture` | `evaluateWatchdogTick` Double-domain math + `running` short-circuit |

Degenerate cells (proposed in the original audit but not
realisable in-process):

- "Settings UInt64 overflow" — there are no UInt64-typed Settings
  fields. All numeric Settings are `Double` (TimeInterval /
  threshold) or `Int` (count). The wraparound arithmetic that
  does exist lives in `AccelHardware.evaluateActivity` and is
  covered by Cell 7.
- "AccelerometerReader watchdog `mach_absolute_time` wraparound"
  in-process — production watchdog uses `Date` (TimeInterval /
  Double), not `mach_absolute_time`. `mach_absolute_time` rollover
  is itself unreachable in-process (~584 years to wrap on
  post-Big-Sur Apple silicon). Cell 8 pins the Date-domain
  extreme reachable in this codebase.
- Out-of-process SIGSEGV / SIGTRAP fault injection — XCTest cannot
  trap SIGSEGV in-process; testing that a force-unwrap actually
  traps requires `XCUIApplication` to spawn a child target, which
  `swift test` does not configure here. Each cell pins the *guard*
  that prevents the trap; the absence-of-trap assertion is the
  test runner not crashing.

These cells are NOT in `mutation-catalog.json` because the catalog
matches single-gate mutations on `Sources/SensorKit/*` against
`expectedFailureSubstring` — the crash-handling cells either span
multiple files (Cell 7 hits both `&-` and `&*`) or pin idiomatic
patterns (Cell 6's "no replay" is intrinsic to `AsyncStream`,
not a single guard). Mutation pairs for the per-gate guards
(`raw > 0`, `now > lastTs`, `frameLength > 0`, `backgroundRMS > 0`,
`mag > 2.0`) are eligible for catalog entries when added; the
crash-handling suite is the integrative regression net.

## Driver parity cells

`Tests/DriverParity_Tests.swift` complements the per-driver
lifecycle / mock tests (e.g. `MicrophoneAdapterLifecycleTests`,
`HeadphoneMotionAdapterLifecycleTests`,
`NotificationResponderTests`, etc.) with eight cells that exercise
each driver protocol's `Real*` and `Mock*` implementations through
the SAME call sequence and assert the protocol's CONTRACT holds on
both sides. Bug class addressed: every other test in the suite
talks to ONE side of the protocol — Mocks for fast deterministic
paths, Real impls only inside lifecycle tests gated on hardware /
TCC. A divergence between the two (e.g. Real returns `nil` where
Mock simulates a value, or Real adds a side effect Mock never
records) would surface as a production-only bug the test suite
cannot catch because no cell ever observes them under the same
input.

| Cell | Driver pair | Assertion shape |
|------|-------------|-----------------|
| `test_eventMonitor_parity_installAndRemove` | `RealEventMonitor` vs `MockEventMonitor` | install returns non-nil token (Mock unconditionally; Real iff Accessibility granted), remove cleans up; `XCTSkipUnless` on TCC for Real half |
| `test_hidDeviceMonitor_parity_emptyMatcherAlwaysEmpty` | `RealHIDDeviceMonitor` vs `MockHIDDeviceMonitor` | empty matcher returns `[]` on both (CONTRACT); non-empty matcher: shape parity only (`[HIDDeviceInfo]` on both) — value diverges (Real reflects connected hw, Mock reflects test state) |
| `test_microphoneEngineDriver_parity_installRemoveTapSymmetry` | `RealMicrophoneEngineDriver` vs `MockMicrophoneEngineDriver` | install/remove tap call sequence symmetric on both; `XCTSkipUnless` on Real input format validity |
| `test_headphoneMotionDriver_parity_contractShape` | `RealHeadphoneMotionDriver` vs `MockHeadphoneMotionDriver` | `isDeviceMotionAvailable` and `isHeadphonesConnected` return Bool on both; `startUpdates` / `stopUpdates` call-counting symmetry on Mock; Real start/stop must not throw or crash |
| `test_hapticEngineDriver_parity_startPlayStop` | `RealHapticEngineDriver` vs `MockHapticEngineDriver` | `start` → `playPattern` → `stop` succeeds on Mock unconditionally and on Real iff Force Touch hardware present (`XCTSkipUnless`) |
| `test_hapticEngineDriver_parity_playWithoutStartThrows` | same | typed-throwing parity: Mock with `shouldFailPlay` throws; Real `playPattern` without prior `start` throws `HapticDriverError.engineNotStarted` |
| `test_displayBrightnessDriver_parity_getSetShape` | `RealDisplayBrightnessDriver` vs `MockDisplayBrightnessDriver` | `get` returns `Float?` on both; Mock seeded set→get round-trips exactly; Real round-trip restores original (non-destructive) |
| `test_systemVolumeDriver_parity_captureSetRestore` | `RealSystemVolumeDriver` vs `MockSystemVolumeDriver` | capture → set → restore round-trips on Mock; Real captures original and restores within tolerance (no-op for user); `XCTSkipUnless` when no default audio output |
| `test_systemNotificationDriver_parity_authorizationShape` | `RealSystemNotificationDriver` vs `MockSystemNotificationDriver` | `currentAuthorization` returns `NotificationAuth` enum on both; `remove` does not throw on either; posting NOT asserted on Real (would surface a banner) |

Skipped halves (Real-side only — Mock half always runs):
- EventMonitor: skipped when Accessibility / TCC not granted to
  the test runner (NSEvent's add returns nil in that case).
- MicrophoneEngineDriver: skipped when no audio input device
  (input format reports zero channels / sample rate).
- HapticEngineDriver: skipped when host has no Force Touch trackpad
  (Mac mini, headless CI).
- DisplayBrightnessDriver: skipped when DisplayServices.framework
  symbols cannot be resolved, or when the active display does not
  report a brightness value (some external monitors).
- SystemVolumeDriver: skipped when host has no default audio output
  device (headless CI).

These cells are NOT in `mutation-catalog.json` because parity is
an INTEGRATIVE invariant across two implementations of the same
protocol — a single-gate mutation in either Real or Mock would
manifest as one half failing while the other passes, which is
already caught by the per-side lifecycle / mock tests already in
the catalog. The parity suite is a regression net for "the two
implementations of this protocol have drifted apart", not a
per-gate anchor.

Divergences documented (not bugs — observed-and-captured contract
differences):
- `RealHIDDeviceMonitor.queryDevices` reflects connected hardware;
  `MockHIDDeviceMonitor` reflects test-injected state. Equality of
  return value is intentionally NOT asserted for non-empty
  matcher lists.
- `RealHeadphoneMotionDriver.isHeadphonesConnected` reflects
  paired AirPods (delegate-driven); `MockHeadphoneMotionDriver` is
  test-controlled. Real's `isDeviceMotionAvailable` returns true
  on every Apple Silicon Mac independent of paired devices.
- `RealSystemVolumeDriver.getVolume` reflects the host's audio
  device state; `MockSystemVolumeDriver` reflects test seed. The
  Real round-trip is restore-only (sets back the captured
  original) so tests do not change the user's volume.
- `RealSystemNotificationDriver.currentAuthorization` reflects the
  test runner's notification grant state (any of the six
  `NotificationAuth` cases is valid); `MockSystemNotificationDriver`
  defaults to `.authorized`. Only enum-shape parity is asserted.

## Snapshot UI cells

Pixel-baseline snapshots in `Tests/SnapshotUI_Tests.swift` cover the
menu UI's structural composition. These cells render real SwiftUI
views into `NSHostingView`, capture the bitmap via the
`pointfreeco/swift-snapshot-testing` `image` strategy, and compare
against committed PNG baselines under
`Tests/__Snapshots__/SnapshotUI_Tests/`.

The bug class targeted: regressions in `AccordionCard` row-height
geometry, `PillButton` framing, accordion expand/collapse layout,
`Theme` color-token additions/removals/edits — all of which compile
clean and pass `MatrixViewLabelCoverage_Tests` (string presence) and
`MatrixAccordionExpansionSize_Tests` (numeric height deltas) but
visually drift.

Cells (14 baseline PNGs total):

| Test | View rendered | Baselines |
|------|---------------|-----------|
| `test_cell_headerSection_lightScheme` | `HeaderSection` | 1 |
| `test_cell_headerSection_darkScheme` | `HeaderSection` (.dark) | 1 |
| `test_cell_deviceSection_collapsed` | `AccordionCard` wrapping `DeviceSection`, `isExpanded=false` | 1 |
| `test_cell_deviceSection_expanded` | `AccordionCard` wrapping `DeviceSection`, `isExpanded=true` | 1 |
| `test_cell_trackpadTuning_expanded_lightScheme` | `AccordionCard` wrapping `TrackpadTuningContent`, `isExpanded=true` | 1 |
| `test_cell_trackpadTuning_expanded_darkScheme` | as above (.dark) | 1 |
| `test_cell_responseSection_lightScheme` | `ResponseSection` (4-card variant, all-hardware-off) | 1 |
| `test_cell_responseSection_darkScheme` | as above (.dark) | 1 |
| `test_cell_footerSection` | `FooterSection` (App Store build only — DIRECT_BUILD skips) | 1 |
| `test_cell_accordionCard_rowCounts` | `AccordionCard` with 1, 3, 5, 7 rows | 4 |
| `test_cell_themeColorPaletteSwatches` | every `Theme.*` named color in declaration order | 1 |

Determinism strategy:

1. **Locale**: cells that render `NSLocalizedString`-backed Section
   views skip via `XCTSkipUnless` when the host's preferred
   localization is non-English. Synthetic-content cells inject
   literal English strings.
2. **Date / clock**: no view in scope formats a `Date()`. The
   `MenuBarFace.impactCount` defaults to `0` and is never mutated by
   the snapshot fixtures.
3. **System fonts**: `precision: 0.99` and `perceptualPrecision:
   0.98` tolerate sub-pixel hinting drift between minor macOS
   versions. The bug classes targeted shift pixels by ≥ 4pt — well
   outside the perceptual band.
4. **Color schemes**: rendered explicitly via
   `.preferredColorScheme(.light)` / `.dark` — never inherits the
   host's appearance.
5. **NSApplication / Bundle.main**: the FooterSection cell is
   skipped under `#if DIRECT_BUILD` because `Updater.currentVersion`
   reads `Bundle.main.infoDictionary`, which differs between
   `swift test` (xctest bundle) and the shipped app.

To regenerate baselines locally: flip `recordMode` in
`SnapshotUI_Tests.swift` from `.missing` to `.all`, run
`swift test --filter SnapshotUI_Tests`, commit the resulting
`Tests/__Snapshots__/SnapshotUI_Tests/*.png`, then revert
`recordMode` back to `.missing`.

These cells are NOT in `mutation-catalog.json`. They are visual
regression nets, not per-gate behaviour anchors — a single mutation
typically perturbs more than one cell at once, which would create
catalog-anchor drift under `make mutate`'s strict
`expectedFailureSubstring` matching.

## UI gate cells (Phase 7)

Phase 7 extended the catalog from SensorKit + ResponseKit into
`Sources/YameteApp/`. The UI / settings / animation surfaces have
behavioural gates that are NOT visual (snapshot tests cover those)
but live in plain Swift control flow:

- `Theme.AccordionCard.animationDuration(forRows:)` — three formula
  clamps: 0.30s upper cap, 0.10s + (rows × 0.025) per-row scale, and
  the `max(1, rows)` floor.
- `Theme.SensorAccordionCard.animationDuration(forRows:)` — duplicate
  formula on the sensor card surface; both must agree so mixed-card
  panels animate consistently.
- `SettingsStore.didSet` blocks across paired settings — the
  recursive-clamp-and-return pattern for unit-range fields, plus the
  pair-fixup gates that drag the partner up/down when the (min, max)
  ordering invariant is violated. Cells anchor sensitivityMin clamp,
  sensitivity / flashOpacity / volume pair invariants, the bandpass
  pair-fixup, the `flashEnabled` ↔ `visualResponseMode` legacy sync,
  plus the `sanitizeNonFiniteAndPairings` cold-load fixups (NaN
  recovery + cold-load bandpass pair fixup).

Anchors live in `Tests/SettingsStoreTests.swift` and
`Tests/Integration/PanelLayoutTests.swift` under the `testUIGate_`
prefix; each carries a stable `[ui-gate=<id>]` substring in its
assertion message so the runner matches deterministically. The
mutation catalog uses `id` prefix `ui-` for these entries.

Coverage scan: `bash scripts/mutation-test.sh --coverage` walks both
`Sources/SensorKit/` and `Sources/YameteApp/` (recursively, including
`Views/`, `Views/MenuBar/`, `Views/Components/`) and emits the
un-covered punch-list. Trace-log lines (`log.{debug,info,warning,
error,trace,notice}`) are skipped — keywords like `threshold` /
`debounce` appear in log format strings, not in control flow.

## Performance baseline (Phase 6)

Functional pass/fail in `Tests/Performance_Tests.swift` already asserts
RATIO bounds inside each cell (e.g. second-half median wallclock ≤ 3×
first-half median; resident-set delta < N MB). What it could not catch
on its own: a uniform 2× CPU regression that stays within the per-cell
internal ratio, or slow drift across releases. Phase 6 adds an
absolute-baseline layer on top.

### Files

- `Tests/Performance/baselines.json` — committed per-cell baselines
  (wallclock seconds, memory delta bytes, host arch, ISO 8601 capture
  timestamp, tolerance factor). Schema:

  ```json
  {
    "cells": {
      "<test_method_name>": {
        "wallclock_seconds": 0.0,
        "memory_delta_bytes": 0,
        "captured_at": "2026-04-29T00:00:00Z",
        "host_arch": "arm64",
        "tolerance_factor": 2.0
      }
    }
  }
  ```

- `scripts/perf-baseline.sh` — runs `swift test --filter
  Performance_Tests`, parses the `PERFMETRIC: cell=… wallclock=…
  memory=…` lines each cell prints, compares each measurement against
  the baseline file with that cell's `tolerance_factor` (default 2.0×).
  Pre-flight refuses a dirty `Sources/` tree (uncommitted production
  edits would muddy a measurement) and verifies `swift build` succeeds
  before the run. Reports per-cell PASS / FAIL plus an aggregate
  `total / passed / regressed / missing` summary.

- `scripts/perf-baseline-record.sh` — overwrites `baselines.json` with
  fresh measurements. Foot-gun guarded behind `YAMETE_BASELINE_RECORD=1`
  so a dropped tolerance can't silently re-bless a regression.

### Make targets

```
make perf-baseline                                   # check vs baselines.json
YAMETE_BASELINE_RECORD=1 make perf-baseline-record   # capture fresh
```

### Cell wiring

Each cell in `Performance_Tests.swift` calls `emitPerfMetric(cell:
wallclock: memory:)` once at the end of its measurement block. The
helper prints a single stable line:

```
PERFMETRIC: cell=<test_method_name> wallclock=<seconds> memory=<bytes>
```

The driver greps these lines from `swift test` stdout — XCTest pass /
fail is independent of baseline comparison. A cell that fails its
internal ratio assertion still emits the line, which lets the perf
driver report both signals separately.

### Workflow

1. Land a perf-relevant change. Run `make perf-baseline`.
2. If the script reports PASS for every cell → no action.
3. If it reports a regression → diagnose: real regression in your
   change, host noise, or a legitimate methodology change.
   - Real regression → fix the production code.
   - Host noise → re-run; if persistent, investigate environment.
   - Legitimate improvement (cell got faster or uses less memory) →
     run `YAMETE_BASELINE_RECORD=1 make perf-baseline-record`,
     review `git diff Tests/Performance/baselines.json`, commit the
     update alongside the change.
4. CI runs `make perf-baseline` on every PR (Phase 2 wiring).

### Per-cell tolerance overrides

The default `tolerance_factor` is 2.0× (a 2× drift fires). Cells that
are inherently noisy (e.g. ones dominated by `Task.yield()` cost) can
have their factor bumped per-entry in `baselines.json` — the recorder
preserves any non-default value when re-writing.
