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

The 19 gates flagged by `--coverage` split as **8 catalogued / 11
degenerate** after the minimum-cost test seam introduced by
`Tests/MatrixAccelerometerReader_Tests.swift`. The seam comprises
three production changes:

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

These changes are scoped to internal access — the public
`AccelerometerSource` API and the file's IOKit lifecycle are
unchanged. The `RealKernelDriver`-shaped seam mentioned in the agent
brief was rejected as cost-disproportionate to the residual coverage
gain: the eleven gates that remain Degenerate would require a
parallel `RealAccelerometerKernelDriver` / `MockAccelerometerKernelDriver`
hierarchy plus all-call-site rewiring for ~150 lines of new code, and
all eleven are kernel-result fidelity guards that fire only when
IOKit returns a non-success code — failures that real-hardware boots
do not produce.

Per-gate disposition:

| Line | Gate | Disposition |
|------|------|-------------|
| 152  | `if !activated { log.info(...) }` | **Degenerate** — bare logging branch with no observable side effect. Not a behavioural gate — the body only writes a single info log. Mutating the predicate cannot be detected without parsing log files, and either branch produces a valid stream because `openStream` is invoked unconditionally on the next line. |
| 174  | `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS` (`SensorActivation.activate`) | **Degenerate** — wraps real `IOServiceGetMatchingServices` against `AppleSPUHIDDriver`. KERN_SUCCESS is the universal outcome on supported hardware; failure modes (kIOReturnNotReady, kIOReturnNoDevice) require a missing or torn-down kext that cannot be simulated. The strengthened justification: `IOServiceGetMatchingServices` is invoked with `kIOMainPortDefault` (the always-available default mach port) and a non-null `IOServiceMatching("AppleSPUHIDDriver")` dictionary, so the only failure modes the kernel can return are infrastructure-wide (kIOReturnError on out-of-resources, kIOReturnNoDevice on a torn-down `IOMainPort`) — both global host conditions that propagate as test-runner failures, not as gate-removable mutations. |
| 180  | `guard service != 0 else { break }` (activate loop) | **Degenerate** — iterator sentinel terminating a `while true` over `IOIteratorNext`. On real hardware the iterator yields N services and then 0; mutating to `service != -1` would loop forever (stuck test, not failing assertion). The `make mutate` runner has no per-test timeout; a stuck test wedges the whole runner, which is INFRA failure, not CAUGHT. Cannot be exercised without a fake `io_iterator_t`. |
| 203  | `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS` (`SensorActivation.deactivate`) | **Degenerate** — symmetric to gate 174, in deactivate. Same kernel-call infrastructure argument applies. |
| 208  | `guard service != 0 else { break }` (deactivate loop) | **Degenerate** — symmetric to gate 180. Iterator sentinel; mutation manifests as a stuck loop, not a failing assertion. |
| 238  | `guard IOHIDManagerOpen(...) == kIOReturnSuccess` (`isSPUDevicePresent`) | **Degenerate** — wraps `IOHIDManagerOpen` on a freshly-created manager. Failure (kIOReturnNotPermitted, kIOReturnExclusiveAccess) requires an entitlement / sandbox failure that cannot be forced from a test. Mutating to always-fail makes `hardwarePresent` return false; the lifecycle stress tests then skip via `XCTSkipUnless`, which is XCTSkip not XCTFail — mutation escapes. The new `MatrixAccelerometerReader_Tests` cells do not call `isSPUDevicePresent` (they construct `ReportContext` directly), so this gate is structurally outside the catalogued behavioural scope. |
| 270  | `guard IOServiceGetMatchingServices(...) == KERN_SUCCESS` (`isSensorActivelyReporting`) | **Degenerate** — symmetric to gate 174 in the read-only probe path. Probe is consumed only by `isAvailable` in the App Store build, and the test host runs the default (Direct) build path under `swift test`, so the probe is not on the executed code path during tests. |
| 277  | `guard service != 0 else { break }` (probe loop) | **Degenerate** — symmetric to gates 180 / 208 inside the probe iterator. |
| 286  | `guard dispatchAccel else { return .skip }` (now in `AccelHardware.evaluateActivity`) | **Catalogued** as `accel-activity-dispatchAccel-gate`. The gate moved from inline-iterator into the pure helper `evaluateActivity`; the cell `testEvaluateActivity_dispatchAccelFalse_returnsSkip` calls the helper directly and pins the `.skip` decode. |
| 297  | `guard now > lastTs else { return .clockNonMonotonic }` (now in `AccelHardware.evaluateActivity`) | **Catalogued** as `accel-activity-clock-monotonicity-gate`. The cell `testEvaluateActivity_clockNotMonotonic_returnsClockNonMonotonic` synthesises a non-monotonic snapshot directly. The wrapping `&-` subtraction in the helper means a mutation that removes the gate decodes as `.stale` (huge wrapped delta past `stalenessNs`), avoiding a SIGTRAP that would mask the catch as INFRA. |
| 319  | `guard openResult == kIOReturnSuccess` (`openStream` IOHIDManagerOpen) | **Degenerate** — same as gate 238: real `IOHIDManagerOpen` result. Mutating to always-fail surfaces a `SensorError.ioKitError` on the throwing stream, but the lifecycle stress test catches via `try?` and asserts only "did not crash", so the mutation escapes the existing assertion. The new `MatrixAccelerometerReader_Tests` does not call `openStream` (it builds `ReportContext` directly). |
| 336  | `guard devOpenResult == kIOReturnSuccess` (`openStream` IOHIDDeviceOpen) | **Degenerate** — same as gate 319 for the per-device open call. Real IOKit return; no mock surface; existing tests do not pin the error path. |
| 346  | `guard maxSize > 0` | **Degenerate** — reads `kIOHIDMaxInputReportSizeKey` from a real IOHIDDevice. Always positive on real hardware (BMI286 reports 24 bytes); mutation produces an unobservable identity branch. The strengthened justification: the only call site is inside `openStream`'s real-IOHIDDevice path, and `IOHIDDeviceGetProperty(_, kIOHIDMaxInputReportSizeKey, ...)` returns a UInt-shaped value the kernel reports from the device's HID descriptor — for the BMI286 this is 24, structurally non-zero. The `?? 64` fallback hides the gate from any test path that does NOT reach a real IOHIDDevice. |
| 407  | `guard snapshot.running else { return .invalidated }` (now in `AccelHardware.evaluateWatchdogTick`) | **Catalogued** as `accel-watchdog-running-gate`. The watchdog poll body's running check moved from inline-Task into the pure helper `evaluateWatchdogTick`; the cell `testWatchdogTick_invalidatedSnapshot_returnsInvalidated` calls the helper directly and pins the `.invalidated` decode. |
| 622  | `guard s.running else { return nil /* already-stalled */ }` (`surfaceStall`) | **Catalogued** as `accel-surfaceStall-running-gate`. The cell `testSurfaceStall_afterInvalidate_yieldsNothing` invalidates the context (running = false) and then calls `surfaceStall(error)`. With the gate, the consumer sees no error; without the gate, the spurious error reaches the consumer and the cell flags it. |
| 630  | `guard length >= minReportLength else { return }` (`handleReport`) | **Catalogued** as `accel-handleReport-length-floor`. The cell `testHandleReport_shortPayloadBelowMin_yieldsNothing` constructs `ReportContext` directly and calls `handleReport(report:length:)` with a payload one byte below the floor. Buffer is over-allocated to 18 bytes so a mutation that removes the gate does not segfault — instead it falls through to decimation + magnitude and yields a sample, which the cell pins. |
| 646  | `guard s.running else { return nil }` (handleReport) | **Catalogued** as `accel-handleReport-running-gate`. The cell `testHandleReport_afterInvalidate_yieldsNothing` invalidates the context and drives 4 reports. With the gate, no impacts yield; without it, decimation+magnitude let through 2 yields, which the cell pins. |
| 660  | `guard s.sampleCounter % decimationFactor == 0 else { return nil }` | **Catalogued** as `accel-handleReport-decimation-gate`. The cell `testHandleReport_decimation_yieldsEveryNthReport` drives 10 reports through a permissive detector and asserts exactly `10 / decimationFactor = 5` yields. Removing the gate yields on every report (10 yields), failing the equality assertion. |
| 664  | `guard rawMag > magnitudeMin && rawMag < magnitudeMax else { return nil }` | **Catalogued** as `accel-handleReport-magnitude-bounds-gate`. The cells `testHandleReport_belowMagnitudeMin_yieldsNothing` and `testHandleReport_aboveMagnitudeMax_yieldsNothing` synthesise sub-floor (each axis = 0.01 g, vector ≈ 0.017 g) and super-ceiling (each axis = 10 g, vector ≈ 17 g) payloads and assert no impacts yield. Removing the gate lets the bounded payload reach the detector. |

Summary: **8 catalogued / 11 degenerate / 19 total**. The 8 promoted
entries are:

- `accel-handleReport-length-floor` (line 630)
- `accel-handleReport-running-gate` (line 646)
- `accel-handleReport-decimation-gate` (line 660)
- `accel-handleReport-magnitude-bounds-gate` (line 664)
- `accel-surfaceStall-running-gate` (line 622)
- `accel-watchdog-running-gate` (line 407)
- `accel-activity-dispatchAccel-gate` (line 286)
- `accel-activity-clock-monotonicity-gate` (line 297)

The 11 residual Degenerate gates are all kernel-result fidelity
guards (KERN_SUCCESS / kIOReturnSuccess / iterator sentinels /
`maxSize > 0`) and the bare logging branch at line 152. Closing them
as CAUGHT would require a `RealAccelerometerKernelDriver` /
`MockAccelerometerKernelDriver` protocol pair that wraps every
`IOServiceMatching` / `IOIteratorNext` / `IOHIDManagerOpen` /
`IOHIDDeviceOpen` / `IOHIDDeviceGetProperty` / `IORegistryEntry*`
call site — roughly 150 lines of new types plus rewiring for two
public entry points (`isSPUDevicePresent`, `isSensorActivelyReporting`)
and one private entry point (`openStream`). The cost is
disproportionate to the residual catch budget because every one of
these guards fires only when IOKit returns a non-success code, which
real-hardware boots do not produce — the gates exist to make
sandbox-rejected paths safe, not to enforce behaviour the test
harness can validate.

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
