# Test Infrastructure Phase Plan

Order of execution. Each phase commits independently; each must pass
`swift test` (default + DIRECT_BUILD), `make lint`, and `make mutate`
(where applicable) before moving on. Findings discovered during a
phase are addressed inline before continuing.

## Phase 4 — AccelerometerReader kernel-result-fidelity coverage

**Problem.** 19 Degenerate gates in `Sources/SensorKit/AccelerometerReader.swift`
all wrap real IOKit calls (`IOServiceGetMatchingServices`, `IOHIDManagerOpen`,
`IOHIDDeviceOpen`, `IOIteratorNext`, `kIOHIDMaxInputReportSizeKey > 0`,
`IOServiceClose`, etc.). Tests can't fault them today because the calls
go straight to the kernel.

**Approach.** Add an `AccelerometerKernelDriver` protocol with a default
`RealAccelerometerKernelDriver` (calls real IOKit) and a
`MockAccelerometerKernelDriver` for tests. The protocol exposes:
- `getMatchingServices(matching: CFDictionary) -> KernResult<IteratorRef>`
- `iteratorNext(_:) -> IOServiceRef`
- `serviceClose(_:) -> kern_return_t`
- `hidManagerCreate() -> IOHIDManager`
- `hidManagerOpen(_:) -> IOReturn`
- `hidDeviceOpen(_:) -> IOReturn`
- `hidDeviceMaxReportSize(_:) -> Int`

Inject via init param defaulting to `RealAccelerometerKernelDriver()`.
Add catalog entries that mock failure for each call site, asserting
the source enters its failure-path branch.

**Deliverables.**
- `Sources/SensorKit/AccelerometerReader.swift` — DI seam wired through
- `Tests/Mocks/MockAccelerometerKernelDriver.swift` — fault-injecting double
- `Tests/MatrixAccelerometerKernelDriver_Tests.swift` — cells anchoring
  each fidelity gate
- `Tests/Mutation/mutation-catalog.json` — promote 19 Degenerate gates
  to CAUGHT entries

**Estimated production diff.** ~150 lines protocol + impl + DI rewiring.

## Phase 8 — Cross-boundary fault injection

**Problem.** Existing `_force*` seams test single-source kernel failures
in isolation. Real systems fail across boundaries simultaneously
(USB hot-unplug while microphone is starting; sleep mid-IOHIDManager
open). No coverage today.

**Approach.** Build a `Tests/CrossBoundaryFaultInjection_Tests.swift`
suite that:
- Drives 2+ `_force*` seams concurrently via TaskGroup.
- Asserts no source crashes, no leaked monitors, bus stays sane.
- Cells include: USB-fail-during-Bluetooth-fail; AccelerometerOpen-fail
  during MicrophoneStart; SleepWake-fail during IOHID-register;
  AudioPeripheral-listener-install-fail during USB-attach-flood.

**Deliverables.**
- New test file with ≥6 cross-boundary cells.
- Catalog entries where appropriate.

## Phase 7 — Mutation testing on `YameteApp/` UI code

**Problem.** Catalog covers SensorKit + ResponseKit. Bindings, animation
timing formulas, layout, settings persistence — all UI/glue code in
`Sources/YameteApp/` — has no mutation coverage.

**Approach.**
- Run `scripts/mutation-test.sh --coverage` with broadened source-tree
  scope (currently SensorKit-only).
- Identify behavioral gates in `AccelTuningSection`, `MicTuningSection`,
  `TrackpadTuningSection`, `Theme.animationDuration(forRows:)`,
  `SettingsStore.didSet` clamps, `FlowLayout`, `RangeSlider`,
  `SensitivityRuler`.
- Add catalog entries pointing at existing `BindingIntegrityTests`,
  `MatrixSettingsToConfig_Tests`, `MatrixSettingsRoundTrip_Tests`,
  `MatrixAccordionExpansionSize_Tests`, etc.

**Deliverables.**
- Updated `scripts/mutation-test.sh --coverage` to walk
  `Sources/YameteApp/` too.
- ≥10 new catalog entries covering UI behavioral gates.
- New cells where existing coverage doesn't anchor a mutation.

## Phase 6 — Performance baseline regression detection

**Problem.** `Tests/Performance_Tests.swift` asserts bounded ratios
(median(second_half) ≤ 3× median(first_half)) but doesn't track
absolute baselines over time. Slow drift goes undetected.

**Approach.**
- Add `Tests/Performance/baselines.json` — committed baseline file
  with absolute timing/memory samples per cell.
- Add `make perf-baseline` Make target that runs Performance_Tests,
  compares each cell's measurement against the committed baseline
  with a 2× tolerance, fails CI on regression.
- Add `make perf-baseline-record` to capture new baselines after a
  legitimate perf-improving change.

**Deliverables.**
- `Tests/Performance/baselines.json`
- `scripts/perf-baseline.sh`
- `Makefile` — new `perf-baseline` + `perf-baseline-record` targets.
- README updates documenting the workflow.

## Phase 5 — Snapshot tests for Direct-only response surface

**Problem.** `SnapshotUI_Tests` covers App Store build UI. The Direct
build adds `VolumeSpikeResponder` + accelerometer-driven response
section UI that never gets snapshot-locked.

**Approach.** Add a Direct-build-only snapshot suite under
`Tests/SnapshotUI_Direct_Tests.swift`, gated `#if DIRECT_BUILD`. Cells
cover the Direct-only sensitivity ruler config, accelerometer toggle
row, volume-spike threshold slider.

**Deliverables.**
- New `#if DIRECT_BUILD`-gated snapshot test file
- `Tests/__Snapshots__/SnapshotUI_Direct_Tests/*.png` baselines

## Phase 3 — Snapshot baselines under DIRECT_BUILD for shared UI

**Problem.** Existing snapshot baselines were captured under default
build. Direct build may produce subtly different layouts (different
`Updater.currentVersion`, different feature gates) for the same view.

**Approach.** Capture per-build snapshot baselines via separate
directories: `__Snapshots__/AppStore/` and `__Snapshots__/Direct/`.
Tests select the correct directory at runtime via `#if DIRECT_BUILD`.

**Deliverables.**
- Baseline directory split.
- Test helpers updated to pick the right baseline path per build.

## Phase 1 — End-to-end suite via `xcodebuild test`

**Problem.** SPM `swift test` skips Real driver paths that need a
proper app bundle (UN center, full Haptic engine, CGEvent.post under
Accessibility). Coverage is incomplete.

**Approach.**
- Add an Xcode test scheme targeting the host app bundle.
- Rewrite `make test-host-app` target invoking `xcodebuild test
  -scheme YameteHostTest`.
- Update test files that XCTSkip under SPM to NOT skip when running
  under the host-app scheme (detect via Bundle URL).

**Deliverables.**
- Xcode scheme JSON.
- Make target.
- Updated XCTSkipIf guards on the affected ~5 cells.

## Findings remediation

After phases 1, 5, and 8 complete, audit any test failures or new
production findings. Common pattern in this work: real bugs surface
when test coverage extends into a previously-unexercised area.
Every finding gets either (a) a production fix + a regression cell,
or (b) a documented Degenerate justification.

## Phase 2 — CI wiring (final)

**Problem.** All gates are local-only. PRs can land with regressions.

**Approach.**
- `.github/workflows/test.yml` — runs `make lint`, `swift test`,
  `swift test -Xswiftc -DDIRECT_BUILD`, `make mutate` on every PR.
- `.github/workflows/perf-baseline.yml` — runs `make perf-baseline`
  weekly; fails-loud on regression.
- `.github/workflows/host-app-test.yml` — runs `xcodebuild test`
  with the host-app scheme on macOS-latest runners.
- Branch protection on `master` and `develop` — required checks:
  lint, default test, DIRECT_BUILD test, mutate.

**Deliverables.**
- 3 GitHub Actions workflow YAML files.
- Branch protection rule guidance in `.github/RULESET.md`.
- README badge for CI status.

## Execution rules

- Each phase commits independently with a `test:` or `feat(test):`
  prefix per existing convention.
- After every phase: `swift test`, `swift test -Xswiftc -DDIRECT_BUILD`,
  `make lint`, `make mutate` must all be green.
- If a phase surfaces a real production bug, STOP, fix, regression-test,
  then continue.
- No phase skips a verification gate to "go faster."

## Status

- Plan written: 2026-04-29
- Phases complete: 0 / 9
