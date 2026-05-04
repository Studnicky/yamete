# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Four new sensor surfaces, each with full menu controls and per-reaction
  matrix integration.** Following gap analysis against four reference repos
  (`olvvier/apple-silicon-accelerometer`, `pirate/mac-hardware-toys`,
  `harttle/macbook-lighter`, `vlasvlasvlas/spank`), Yamete now publishes:
  - **Gyroscope spikes** (`.gyroSpike`) — lid yank, laptop spin, rotation
    transients. Same Apple Silicon SPU HID device as the BMI286 accelerometer,
    different HID usage (9 vs 3). Six-gate consensus pipeline (`GyroDetector`)
    tuned for deg/s magnitude with separate spike threshold, rise rate,
    crest factor, confirmation count, warmup, and cooldown.
  - **Lid angle state transitions** (`.lidOpened`, `.lidClosed`, `.lidSlammed`)
    via SPU HID usage 8. State machine (closed/opening/open/closing) with
    EMA smoothing on Δangle/Δt to suppress jitter. The slam gate fires when
    rate-of-change crosses a configurable negative threshold while the angle
    approaches zero.
  - **Ambient light step changes** (`.lightsOff`, `.lightsOn`, `.alsCovered`)
    via SPU HID usage 7. Two-second ring buffer + step detector with separate
    percent and floor/ceiling gates per direction. The `.alsCovered` path
    has its own faster rate constraint so a hand over the sensor reads
    distinctly from gradual room dimming.
  - **Thermal pressure transitions** (`.thermalNominal`, `.thermalFair`,
    `.thermalSerious`, `.thermalCritical`) via `NSProcessInfo
    .thermalStateDidChangeNotification`. Cold-start suppression: the initial
    state captured at start does not publish. Per-state dedup. No tunable
    thresholds — the levels are OS-defined.
- **AppleSPUDevice broker.** Refactored the previously-direct accelerometer
  IOHID handle into a ref-counted multiplexer with a single input-report
  callback that fans out to every subscriber regardless of `(usagePage,
  usage)` — gyroscope, lid, and ambient-light sources subscribe alongside
  the accelerometer and decode their own byte offsets from the shared
  report. Phase 0 of the v2.1.0 plan. The activation/deactivation
  three-phase teardown invariant is preserved verbatim from the previous
  implementation; only the LAST subscriber's release closes the device.
- **Two emission patterns documented.** Continuous-stream sources (accel,
  microphone, gyroscope, ambient light) run a detector pipeline over a
  high-frequency sample stream and emit one Reaction on threshold cross;
  discrete state-transition sources (USB, power, audio, BT, Thunderbolt,
  display, sleep/wake, lid, thermal) observe an OS notification surface
  and emit one Reaction per user-meaningful state change. Both feed the
  same bus.

### Changed
- Event source count documented as **eleven** (was: seven).
- Mutation catalog grew from 111 → 130 entries (5 gyro, 5 lid, 5 ALS, 4
  thermal). All caught.

## [2.0.0] - 2026-05-02

### Added
- **Reaction Bus architecture.** Single multi-subscriber `ReactionBus` actor
  in `YameteCore` with `bufferingNewest(8)` per subscriber. Sources publish
  onto the bus; outputs subscribe independently and pattern-match the unified
  `Reaction` envelope. `Reaction.impact(FusedImpact)` is just one case
  alongside cable/power/device events — the case IS the contract, no nested
  payload type, no dispatch table, no event-router. Adding a new event class
  is one new `Reaction` case + one new source class + the compiler tells
  every output what it now needs to handle.
- **LED flash output.** New `LEDFlash` (`Sources/ResponseKit/LEDFlash.swift`)
  pulses the keyboard's Caps Lock LED on every reaction the user has enabled,
  gated through the same intensity envelope as `ScreenFlash`. Brightness is
  PWM-dithered at 60Hz against the shared `Envelope` since Caps Lock is
  binary on/off. Caps Lock state is captured before the pulse and restored
  after — there is a brief window during which Caps Lock toggles rapidly.
  Joke app, accept the inaccuracy. Toggleable in the new LED Flash menu bar
  section with brightness min/max sliders. No new entitlements required
  (uses existing `com.apple.security.device.usb`).
- **Cable / power / device event sources.** Seven new IOKit / CoreAudio /
  IOPS notification sources publishing onto the bus:
  - `USBSource` — IOServiceMatching `kIOUSBDeviceClassName`, suppresses
    initial replay burst, debounces vendor/product 50ms.
  - `PowerSource` — `IOPSNotificationCreateRunLoopSource`, edge-triggered on
    AC connect / disconnect transitions.
  - `AudioPeripheralSource` — `AudioObjectAddPropertyListener` on
    `kAudioHardwarePropertyDevices` with set diffing for per-device events.
  - `BluetoothSource` — IOServiceMatching `IOBluetoothDevice` (pure IOKit
    path, avoids private `IOBluetooth.framework` symbols).
  - `ThunderboltSource` — IOServiceMatching `IOThunderboltPort`.
  - `DisplayHotplugSource` — `CGDisplayRegisterReconfigurationCallback`,
    debounced 200ms to collapse macOS's 3–4 callbacks per real change.
  - `SleepWakeSource` — `IORegisterForSystemPower` for `willSleep` /
    `didWake` (same API the sensor-kickstart helper uses to re-warm the
    BMI286 on wake).
  Per-event default intensities live in `ReactionsConfig` (single tuning
  surface). All seven sources ship enabled by default; user toggles each
  on/off in the new Cable & Power Events menu bar section.
- **Per-(output × event) toggle matrix.** Each of the four configurable
  outputs (sound, screen flash, notification, LED) has an independent
  per-`ReactionKind` enable/disable toggle persisted as a JSON-encoded
  `ReactionToggleMatrix`. The user can have sound-only on USB attach,
  flash-only on AC unplug, notification-only on display reconfiguration,
  etc. — fully orthogonal across outputs.
- **`Events.strings` notification table.** New
  `App/Resources/en.lproj/Events.strings` with `title_<kind>_<n>` /
  `body_<kind>_<n>` pools per reaction kind, mirroring the existing
  `Moans.strings` numbered-suffix convention. Loader caches the table
  separately so impact-pool clears don't blow it away.
- **`com.apple.security.device.bluetooth` entitlement** added to the App
  Store build for `IOBluetoothDevice` IOService matching.

- **`FiredReaction` enriched event envelope.** `ReactionBus` now resolves
  `clipDuration`, `soundURL`, `faceIndices` (one per connected display), and
  `publishedAt` exactly once before fan-out via a registered `ReactionEnricher`
  closure. All subscribers receive identical pre-resolved values — no per-output
  duration math, no duplicate face/clip selection. Enricher has a 0.5 s timeout
  with a safe fallback and a set-once precondition to prevent post-bootstrap
  replacement.
- **`FaceLibrary` shared face cache.** Centralized face image cache and
  per-event recency dedup scoring (`selectIndices(count:)`). Called once by the
  enricher; `ScreenFlash` and `MenuBarFace` both look up by index. Appearance-
  aware (reloads on dark/light mode change). Replaces the two independent caches
  that were in `ScreenFlash` and `MenuBarFace`.
- **Per-display face matching.** `FiredReaction.faceIndices[i]` maps to
  `NSScreen.screens[i]`. `ScreenFlash` shows a different scored face on each
  display; `MenuBarFace` shows `faceIndices[0]` (primary display). Added
  `faceIndex(for:)` bounds-safe accessor to handle display count changes between
  enrichment and rendering.
- **Keyboard brightness spring animation in `LEDFlash`.** `KeyboardBrightnessClient`
  (CoreBrightness private framework) controls keyboard backlight. Animation uses
  a damped spring centred on the user's current brightness level so it never
  drives the backlight to zero. Includes: idle-dimming suspension, launch-time
  brightness snapshot with crash-recovery sentinel file (`kb_dirty`), and
  `validateArgCount` guard on every `unsafeBitCast` dispatch to
  `KeyboardBrightnessClient` selectors.
- **`EventSource` protocol.** Separate from `SensorSource` — the seven
  infrastructure event sources (`USBSource`, `PowerSource`, etc.) now conform to
  `EventSource` rather than the impact-sensor `SensorSource`.
- **`ImpactFusionConfig` rename.** `FusionConfig` renamed to `ImpactFusionConfig`
  for naming consistency with `ImpactFusion` and the `*OutputConfig` family.
- **`Yamete.shutdown()` and app-quit cleanup.** `applicationWillTerminate(_:)`
  calls `yamete.shutdown()`, which cancels all output tasks, stops the fusion
  pipeline, closes the bus, and calls `ledFlash.resetHardware()` to restore
  keyboard brightness before process exit.
- **Canonical docs source system.** `docs/_includes/what-it-does.md` and
  `docs/_includes/under-the-hood.md` are the canonical prose for the project
  description; HTML pages and README reference them. `make docs-check` validates
  all source file references in `docs/*.html` at lint time. `docs/_config.yml`
  enables Jekyll on GitHub Pages without changing the visual design.
- **New test files.** `FiredReactionTests`, `BusEnricherTests`,
  `ReactionsConfigTests` (exhaustiveness check for `eventIntensity` map).

- **Haptic feedback output.** New `HapticResponder` fires rapid Force Touch
  haptic pulses on each reaction. Pulse density scales with the `Envelope`
  level — dense at the attack peak, sparse through the decay tail. Intensity
  is a user-adjustable multiplier (0.5×–3.0×). Works on any Mac with a Force
  Touch trackpad. No entitlements required.
- **Display brightness flash output.** New `DisplayBrightnessFlash` spikes
  the main display's brightness above the user's current level on hard
  impacts, then restores it over the `Envelope` fade window. Peak = current +
  user-configured boost × intensity. Uses `DisplayServicesGetBrightness` /
  `DisplayServicesSetBrightness` loaded at runtime via `dlopen` (private
  framework, no entitlements required). Gated by a minimum-intensity threshold.
- **Screen tint output.** New `DisplayTintFlash` briefly tints the display
  pink by crushing the green and blue gamma channels via
  `CGSetDisplayTransferByTable` (public CoreGraphics). Tint depth scales with
  `Envelope` level. Automatically skipped on macOS 26+ where the gamma table
  path is unreliable. No entitlements required.
- **Volume spike output (Direct build only).** New `VolumeSpikeResponder`
  temporarily raises system output volume to a target level on hard impacts,
  then restores the original volume after the reaction window. Uses
  `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` via AudioObjectAPI.
  Gated by a minimum-intensity threshold. Compiled only with `#if DIRECT_BUILD`.
- **Trackpad activity event source.** New `TrackpadActivitySource` (`EventSource`,
  not part of impact fusion) uses `NSEvent.addGlobalMonitorForEvents` with a
  sliding RMS window to detect two patterns: `trackpadTouching` (sustained
  scroll/gesture activity) and `trackpadSliding` (high-velocity scrolling).
  Both publish directly to the `ReactionBus`, independent of the impact
  pipeline. Configurable window duration and activity threshold. Enabled by
  default. Tunable via the new Trackpad Tuning accordion in the menu bar.
- **Per-(output × event) matrix for new outputs.** Haptic, display brightness,
  display tint, and volume spike each have their own `ReactionToggleMatrix`
  persisted in UserDefaults. Event matrix rows in the menu bar UI now show two
  rows of output toggles: core (audio, flash, notification, LED) and hardware
  (haptic, brightness, tint, volume spike).
- **Trackpad Tuning section.** New collapsible accordion in the menu bar (shown
  when Trackpad Activity source is enabled) with sliders for activity window
  duration, sensitivity threshold, and intensity scale.
- **Test infrastructure overhaul.** Multi-layer test suite landed alongside
  the reactive-output pipeline:
  - **Onion-skin Ring 1 / Ring 2 architecture** for the matrix bus tests.
    Ring 1 cells exercise pure logic with mock outputs; Ring 2 cells round-trip
    through a real `ReactionBus` with `MatrixSpyOutput` fixtures and assert
    cross-source interleavings, drop-not-cancel semantics, and coalesce
    fan-out invariants.
  - **Mutation runner with 111 catalog entries.** `make mutate` walks
    `Tests/Mutation/mutation-catalog.json`, applies each mutation to its
    target source file in-place, runs the suite, and asserts the mutation
    is caught by at least one failing test. Per-target slice runner
    (`scripts/mutation-test-slice.sh`) drives the GitHub Actions
    `Mutation catalog (PR slice)` lane.
  - **Property-based fuzz cells** (`Tests/Property_*Tests.swift`) — bus
    invariants over randomised stimulus streams, locale × plural fuzz
    against the localisation matrix, settings-corruption fuzz against
    `SettingsStore`, and state-machine model checks for the lifecycle
    state transitions.
  - **Concurrent-interleaved fuzz** that publishes from multiple sources
    on overlapping timelines and asserts no double-action / no missed
    drop / no leaked task across a randomised interleave space.
  - **~28 SwiftUI snapshot baselines per build variant** across four
    variants (`AppStore`, `Direct`, `HostApp`, `CI`) covering header,
    device, response, footer, accordion-card row counts, theme palette
    swatches, trackpad-tuning expand/collapse, and (Direct) headphone /
    accel tuning. Records via `SNAPSHOT_RECORD_MODE=true`; reads via
    `precision: 0.99 / perceptualPrecision: 0.98` to tolerate antialiasing
    drift.
  - **Performance baselines** (`Tests/Performance/baselines.json`) with
    absolute thresholds and a `make perf-baseline` regression gate
    (`tolerance_factor: 2.0×` default).
  - **Driver Real-vs-Mock parity tests** that run the same matrix
    against the production driver and the mock and assert byte-equal
    outputs.
  - **Crash-handling boundary audit** and **cross-boundary fault
    injection** cells that verify each Source / Bus / Output boundary
    surfaces typed errors rather than silently swallowing them.
  - **CI-tolerance helpers** (`Tests/Helpers/AwaitUntil.swift`) with
    `CITiming.envelopeMultiplier` (3× under CI), `awaitUntil(...)`
    polling primitive, and `skipIfCIBaselineMissing(...)` snapshot
    bootstrap. Detects CI via either the `CI=true` env var or a
    `/Users/runner/` bundle-path prefix (xcodebuild does not always
    propagate the env var into the test bundle).
  - **Host-app xcodebuild lane** (`make test-host-app`,
    `.github/workflows/host-app-test.yml`) that runs the YameteHostTest
    scheme inside a real `Yamete.app` bundle so cells gated on UN
    center, full Haptic engine, CGEvent.post under Accessibility, and
    Force-Touch trackpad probes execute their Real-driver halves
    rather than skipping under SPM `xctest`.
  - **Snapshot-baseline-seed workflow** (`.github/workflows/snapshot-baseline-seed.yml`)
    — workflow_dispatch helper that records macos-15-runner-rendered
    baselines under `Tests/__Snapshots__/CI/` and opens a PR adding
    them, addressing runner-vs-developer-host pixel drift.

### Changed
- **`SensorAdapter` protocol → `SensorSource` protocol.** Three concrete
  implementations renamed: `SPUAccelerometerAdapter` → `AccelerometerSource`,
  `MicrophoneAdapter` → `MicrophoneSource`, `HeadphoneMotionAdapter` →
  `HeadphoneMotionSource`. Public surface preserved.
- **`ImpactFusionEngine` → `ImpactFusion`.** Now owns the multi-source task
  fan-in lifecycle (start/stop) and publishes `Reaction.impact` onto the
  bus. The old `ingest(_:activeSources:)` API is preserved for tests;
  runtime path uses the engine's internal `activeSources` state.
- **`ImpactController` deleted.** The router-style controller dissolved into
  three pieces: sensor lifecycle moved into each `*Source` class, fusion is
  now `ImpactFusion`, response dispatch became per-output
  `consume(from:configProvider:)` loops on each `ResponseKit` output. The
  new `Yamete` orchestrator (`Sources/YameteApp/Yamete.swift`) owns the
  bus, sources, fusion, outputs, and lifecycle wiring — no routing.
- **`AudioResponder` / `VisualResponder` protocols deleted.** Outputs are
  now concrete classes with `consume(from: ReactionBus, configProvider:)`
  methods — no shared protocol because there's no polymorphic dispatch
  surface.
- **Menu bar reaction face moved to `MenuBarFace`**
  (`Sources/YameteApp/MenuBarFace.swift`), an `@Observable` class that
  subscribes to the bus and updates its own `reactionFace` /
  `lastImpactTier` / `impactCount` state. `StatusBarController` reads from
  `yamete.menuBarFace.reactionFace` instead of `controller.reactionFace`.
- **Sensitivity gate is now `FusedImpact.applySensitivity(...)`** (a static
  method in `YameteCore`). The orchestrator installs it on
  `ImpactFusion.intensityGate` so the bus pipeline applies the user's
  sensitivity band before any output sees the impact.

### Fixed
- **`NSSound` lifetime.** `AudioPlayer` retains `NSSound` instances in
  `activeSounds: [NSSound]` and releases them only in
  `sound(_:didFinishPlaying:)`. Previously sounds were deallocated immediately
  after `.play()`, silently truncating playback.
- **IOKit NULL device guard in `LEDFlash.writeLED`.** `IOHIDElementGetDevice`
  can return nil when the keyboard disconnects mid-animation. Added a service-
  port validity check before calling `IOHIDDeviceSetValue`.
- **`IOHIDManager` closed on deallocation.** `LEDFlash.deinit` now calls
  `IOHIDManagerClose` so the kernel-side manager reference is released promptly
  rather than waiting for process exit.
- **`IONotificationPort` iterator cleanup on partial setup failure.** USB,
  Bluetooth, and Thunderbolt event sources now release any already-created
  IOKit iterators in the failure branch of `start()` before destroying the port.
- **IOKit context lifetime in event sources.** USB, Bluetooth, and Thunderbolt
  sources switched from `passUnretained` to `passRetained` context pointers,
  with explicit `release()` in `stop()` after iterator release, matching the
  accelerometer pattern.
- **`ReactionBus` enricher set-once precondition.** `setEnricher(_:)` now
  asserts `self.enricher == nil`; calling it twice is a programmer error.
- **`LogStore` file I/O errors surfaced.** `createDirectory`, `createFile`, and
  `FileHandle(forWritingTo:)` failures now log to `os.Logger` directly rather
  than silently no-op.
- **`ReactionToggleMatrix` encode/decode failures logged.** Previously returned
  empty data / empty matrix silently; now logs at `.error` level.
- **Consensus clamping logged.** When `consensusRequired` exceeds active source
  count, the effective value and reason are now logged at `.info`.
- **`HeadphoneMotionAdapter` probe timeout weak capture.** Changed from strong
  `[self]` to `[weak self]` in the `asyncAfter` closure, preventing the adapter
  from outliving its expected lifetime if deallocated before the 0.4 s probe
  fires.

## [1.3.2] - 2026-04-17

No source-code changes since 1.3.1 — the shipped app binary is behaviorally identical. This release cuts a tag so the accumulated docs, Pages, and CI-hygiene work reaches the Pages site and the repo's default-facing README.

### Added
- **Dependabot config for GitHub Actions dependencies** — PR #40.
  `.github/dependabot.yml` schedules weekly action-version updates with
  minor + patch bumps grouped into a single PR. Swift Package Manager
  is not yet a Dependabot ecosystem (tracked upstream at
  dependabot/dependabot-core#7268) so SPM deps in `Package.swift` still
  require manual bumps.
- **Workflow-YAML linting via actionlint** — PR #40. New `actionlint`
  job in `ci.yml` using `raven-actions/actionlint@v2` catches syntax
  and shellcheck-level bugs in workflow YAML before a push lands on a
  runner. Caught a real SC2129 in `release.yml` on its first run.
- **App icon + an intentionally silly number of badges in the README**
  — PRs #43, #44. The `AppIcon.appiconset` 128x128 asset renders
  centered at the top of the README at 160px. Thirty-eight shields.io
  badges across six themed rows: ship status, platform + stack,
  what's inside, promises, flex, and a row of CI-shaped exclamation
  badges for things that are decidedly not CI status (current face,
  last impact tier, watchdog status, machine spirits, etc.).

### Changed
- **README redesigned: voice match Pages, link instead of duplicate**
  — PR #43. The README was repeating content that lives more
  comfortably on `studnicky.github.io/yamete` (How it works,
  Configuration, Distribution, Project structure, the ASCII detection
  diagram). The rewrite matches the project site's voice, sends
  visitors to the right Pages section via a link list at the top,
  and trims 157 lines down to ~70 + a badge wall. Single source of
  truth per topic lives on Pages; the README orients visitors.
- **User-facing docs refreshed to present tense** — PR #43. Scrubbed
  phrasing about what things "used to be", "was renamed", "now
  ships" across README, `docs/architecture.html`, `docs/support.html`,
  `docs/INSTALLATION.md`. Bumped `docs/assets/sidebar.js` version
  badge to 1.3.2 so every published page surfaces the current
  release consistently.
- **CI workflow concurrency groups** — PR #40. Rapid-fire pushes on
  non-`master` refs now cancel stale in-flight CI runs instead of
  stacking them behind each other. Release workflow uses the group
  for observability only (never cancels a tagged build mid-run).
- **Release workflow opted into Node.js 24** — PR #40. Node.js 20 is
  scheduled for removal from GitHub-hosted runners on 2026-09-16.
  `softprops/action-gh-release@v2` currently runs on Node 20; setting
  `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"` at the workflow env
  level migrates ahead of the forced cutover.

### Fixed
- **Release notes were three separate `echo >> file` appends instead
  of a grouped redirect** — PR #40 follow-up. actionlint/shellcheck
  flagged the pattern as SC2129 on its first run; consolidated the
  three appends and the `awk` invocation into a single `{ ...; ... }
  > file` block. Same output, one syscall instead of four.

## [1.3.1] - 2026-04-17

### Fixed
- **`MicrophoneAdapter` teardown crashed the test process under certain
  CoreAudio states (SIGSEGV)** — PR #38. Observed on CI run 24548266785
  on the 1.3.0-bound `develop`, but the underlying race was latent
  regardless of release.
  - Teardown order in `continuation.onTermination` was reversed:
    `inputNode.removeTap(onBus: 0)` ran BEFORE `engine.stop()`. Removing
    a tap while the engine is still running lets the audio thread fire
    one more buffer callback that dereferences state captured by the
    tap closure after it has been torn down. Correct order is stop
    first (blocks until pending audio-thread callbacks drain) then
    remove. Inline comment documents the invariant.
  - Added a format-validity gate on `inputNode.outputFormat(forBus: 0)`.
    Hosts with no real audio input (headless CI runners, containers,
    virtualized macOS) can return a format with zero channels or zero
    sample rate; `installTap` with such a format is undefined behavior
    in CoreAudio. The adapter now finishes the stream with
    `SensorError.deviceNotFound` up front so the manager falls through
    to other adapters cleanly instead of crashing.
  - The `engine.start()` failure branch now pairs its `continuation.finish`
    with `inputNode.removeTap(onBus: 0)` so a failed start doesn't leak
    an installed tap.

## [1.3.0] - 2026-04-17

### Changed
- **Swift 6 language mode + complete strict concurrency checking** — PR #34.
  `project.yml` now sets `SWIFT_VERSION: "6"` and
  `SWIFT_STRICT_CONCURRENCY: complete`; `Package.swift` declares
  `swiftLanguageModes: [.v6]`. The codebase was already clean under
  `-strict-concurrency=complete` (the Makefile's `lint` target has been
  running with that flag for some time), so the bump produced no new
  compiler diagnostics — but it locks the contract going forward.
- **`@unchecked Sendable` surface shrunk from five app-type-level sites
  to two narrow framework-handle wrappers** — PR #34.
  - `AccelResources` is now a real `Sendable`; the unavoidable IOKit
    handle escape is isolated in a tiny private `IOKitHandles` struct
    whose soundness is justified by the phased construction → single-move
    publish → once-teardown lifecycle enforced by `OnceCleanup`.
  - `ReportContext.State` is now genuinely `Sendable`: its contained
    `HighPassFilter` and `LowPassFilter` were converted from `final class`
    to `struct: Sendable` with `mutating process(_:)`.
  - `HeadphoneConnectionTracker` drops `@unchecked`; under Swift 6,
    `OSAllocatedUnfairLock<Bool>` in a final-class NSObject subclass
    synthesizes `Sendable` correctly when every field qualifies.
  - `LogStore.State` drops `@unchecked`; the culprit was
    `ISO8601DateFormatter` (still non-Sendable under Swift 6), replaced
    with a `DateFormatter` using `yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX` +
    `en_US_POSIX` + GMT that produces byte-identical output.
  - `HIDRunLoopThread.State` retains `@unchecked` because `Thread` and
    `CFRunLoop` handles cannot be escaped without redesigning the HID
    thread itself. The rationale comment now cites the concrete
    invariants (every access through `OSAllocatedUnfairLock<State>`,
    documented thread-safety of `Thread.cancel`/`CFRunLoopStop`,
    phased lifecycle) that make it sound.
- **`HighPassFilter` / `LowPassFilter` are now Sendable structs with
  `mutating process(_:)`** — PR #34. API note for any out-of-tree callers:
  these were previously final classes, so callers that held them by `let`
  must now use `var`. All in-tree call sites (AccelerometerReader + the
  test suite) have been updated.

### Fixed
- **`SensorManager` dropped terminal `adaptersChanged([])` snapshot under
  concurrent cancellation** — PR #33.
  `Sources/SensorKit/SensorAdapter.swift`'s per-adapter task body caught
  `CancellationError` and returned immediately, skipping the subsequent
  `activeTracker.remove(adapter) + adaptersChanged(...)` yield at the
  bottom of the task body. Under concurrent cancellation (two adapters
  terminating near-simultaneously) the tracker retained a stale active
  entry and the terminal empty-snapshot the consumer expects was never
  emitted. Surfaced by a flaky CI run on PR #30 where
  `SensorManagerTests.testEventsPublishesAdapterLifecycle` saw
  `snapshots.last == ["B"]` instead of `[]`. Cancellation is a normal
  adapter termination signal, not a failure, so it now falls through to
  the shared lifecycle emission.

## [1.2.0] - 2026-04-16

### Added
- **MicrophoneAdapter + HeadphoneMotionAdapter lifecycle test coverage** — PR #30.
  New `MicrophoneAdapterLifecycleTests` and `HeadphoneMotionAdapterLifecycleTests`
  cover open/close symmetry, repeated open/close cycles, mid-stream cancellation,
  and typed-error propagation. Hardware-unavailable paths skip gracefully via
  `XCTSkip` so the suite stays green on CI without real microphones or motion-
  capable headphones. Total test count 129 → 137.
- **Framework-list drift guard** — PR #29. `make lint-frameworks` diffs the
  framework list across `Makefile`, `Package.swift`, and `project.yml` and
  fails on divergence. Wired into `make lint` so CI catches any future drift.
  Caught real drift on first run: `IOKit` was missing from the Makefile's
  `FRAMEWORKS` variable, and `UserNotifications` was missing from both the
  Makefile and `project.yml`. All three sources are now aligned on the same
  eight frameworks.

### Changed
- **`MenuBarView.swift` split into per-section files** — PR #28. The 948-line
  composition root with 14 nested view structs now lives as a 199-line
  `MenuBarView.swift` (composition root + `HeaderSection` + a few shared
  helpers) plus 12 files under `Sources/YameteApp/Views/MenuBar/`. Extracted
  views flipped from `private` → `internal`; the public `MenuBarView` API
  is unchanged. No behavior change, no renames.
- **Version extraction via `yq` instead of `sed`** — PR #29. The Makefile and
  the release workflow now pull `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
  out of `project.yml` with `yq '.settings.base.…' project.yml` instead of a
  regex, removing the brittle dependency on a specific indent or quoting style.
  The Makefile errors out with an install hint if `yq` is missing; the release
  workflow installs it via `brew install yq` before the version check runs.
- **`SWIFT_ACTIVE_COMPILATION_CONDITIONS` quoting normalized in `project.yml`.**
  Debug, DebugDirect, and ReleaseDirect all now use double-quoted string
  values consistently (previously two were quoted and one was bare).
- **CI test job routed through `make test`** — PR #31. `.github/workflows/ci.yml`
  now invokes `make test` instead of `swift test`, keeping local and CI
  invocations in sync.
- **`StatusBarController.showPanel()` drops `DispatchQueue.main.async`** —
  PR #31. The class is already `@MainActor` so the dispatch hop was redundant.
  Replaced with `Task { MainActor in await Task.yield(); … }`, preserving the
  intentional deferral (letting SwiftUI re-layout after the
  `.menuBarPanelDidShow` notification) with one fewer scheduling primitive.

### Fixed
- **`SettingsStore.resetToDefaults()` force-cast crash risk and duplicate
  assignments** — PR #27. The method had 37 `as!` force-casts pulling values
  out of an `[String: Any]` defaults dict, and assigned `accelBandpassLowHz`
  and `accelBandpassHighHz` twice. Rewritten to assign every field directly
  from the typed `Defaults.*` constants in `Sources/YameteCore/Defaults.swift` —
  no `Any` round-trip, no duplicate assignments, no crash path if the defaults
  dict is ever mistyped. All 24 SettingsStore tests remain green.

### Documentation
- `project.yml` gains a YAML comment block above `SWIFT_INCLUDE_PATHS` /
  `HEADER_SEARCH_PATHS` explaining why both are required for the `IOHIDPublic`
  bridging module (the Swift driver locates `module.modulemap`, the C
  compiler resolves the headers it references — removing either breaks
  the bridging module).
- `project.yml` gains a comment above the `Yamete-AppStore:` scheme noting
  that its `run` config is `Debug`, so sandbox entitlements only apply via
  `make appstore` or archive, not via Xcode's Run button. A matching comment
  lives above the Makefile's `appstore:` target.

## [1.1.1] - 2026-04-16

### Fixed
- **Recursive lock crash on launch-at-login** — PR #23. `AccelerometerReader.surfaceStall()` and `handleReport()` called `AsyncThrowingStream.Continuation.finish()`/`yield()` while holding the `OSAllocatedUnfairLock`. `AsyncThrowingStream._Storage` acquires its own internal `os_unfair_lock` in those methods, causing a non-reentrant double-acquisition (abort cause 89859). Fixed by capturing the continuation reference (and the value to yield) as the lock's return value, releasing the lock, then calling the continuation method outside.

## [1.1.0] - 2026-04-15

### Added
- **Auto-update via GitHub Releases (Direct build only)** — PR #18.
  The previously stubbed `Updater` is now a full update lifecycle:
  checks GitHub Releases on launch (throttled to every 4 hours),
  downloads the signed+notarized DMG, installs, and relaunches. The
  menu bar footer surfaces live update state with contextual action
  buttons (check / download / install / restart). All update logic
  is gated behind `#if DIRECT_BUILD`; the App Store build keeps the
  stub because App Store Connect handles distribution there.

### Changed
- **Menu bar shell replaced: `MenuBarExtra` → directly-managed
  `NSStatusItem` + `NSPanel`** — PR #20, closes #19. SwiftUI's
  `MenuBarExtra(.window)` was rendering the popover with a blank gap
  above the content and letting the desktop wallpaper bleed through
  the background, making text unreadable on light wallpapers. The new
  `StatusBarController` manages an `NSStatusItem` directly and hosts
  the SwiftUI content inside an `NSPanel` backed by an
  `NSVisualEffectView` with `.menu` material, sized to the SwiftUI
  content before display. Icon reactivity is preserved via
  `withObservationTracking` rather than embedding `NSHostingView` in
  the status bar button. Escape and outside-click dismiss behavior
  are unchanged from user perspective.

### Fixed
- **Menu bar popover background transparency rendered content
  unreadable** — closes #19. See NSPanel migration above.

## [1.0.1] - 2026-04-10

### Fixed
- **Accelerometer not detected on M5 Macs (Direct build)** — closes #15.
  `SPUAccelerometerAdapter.isAvailable` was gating on
  `isSensorActivelyReporting()` for all build variants, creating a
  chicken-and-egg in the Direct build: the UI hid the accel toggle
  because the sensor wasn't reporting, `impacts()` was never called,
  and so the sensor never started reporting. Worked on M4 because
  the sensor happened to be warm at launch; broke on M5 because
  macOS apparently doesn't keep the SPU accel warm by default on
  that silicon. The runtime probe is now gated behind
  `#if !DIRECT_BUILD` — Direct checks only `isSPUDevicePresent()`
  (it has full IOKit write access and can always self-activate via
  `SensorActivation.activate()` at pipeline start), while the App
  Store build keeps the full probe because the sandbox constraint
  is real there.

### Changed
- **Sensor kickstart helper is now a long-lived daemon with a wake
  watcher.** `docs/sensor-kickstart/yamete-sensor-kickstart.swift` has
  a `daemon` subcommand that runs `kickstart()` once on startup, then
  subscribes to IOKit system power notifications via
  `IORegisterForSystemPower` and re-runs the kickstart on every
  `kIOMessageSystemHasPoweredOn` event. The shipping LaunchDaemon plist
  (`com.studnicky.yamete.sensor-kickstart.plist`) ships with `KeepAlive
  = true` + `ProcessType = Background` + `daemon` arg, and a
  `ThrottleInterval = 10` to rate-limit crash-loop respawns. Idle CPU
  cost is effectively zero (the daemon sits parked in `CFRunLoopRun`
  waiting for notifications). Motivation: on the hardware we have
  tested the sensor stays live across sleep/wake, but this is defense
  in depth for hardware or macOS revisions we have not verified — even
  if the driver cools the sensor during sleep, the daemon's wake
  handler re-runs the kickstart before the user notices.
- **Helper renamed** from `docs/community/yamete-accel-warmup` to
  `docs/sensor-kickstart/yamete-sensor-kickstart`. The old "community"
  directory name was a vague dumping-ground; the new name reflects what
  the thing actually does. Rename cascades across the directory, the
  Swift source, the LaunchDaemon plist label
  (`com.studnicky.yamete.sensor-kickstart`), the binary install path
  (`/usr/local/libexec/yamete-sensor-kickstart`), the log path
  (`/var/log/yamete-sensor-kickstart.log`), the Swift function
  (`warmup()` → `kickstart()`), the CLI subcommand (`warmup` →
  `kickstart`), and every prose reference in public docs.
- **GitHub Pages now serves only public content.** `docs/` was the
  publish root but had been used as a dumping-ground for internal
  planning docs. Removed: `APP_STORE_METADATA.md`,
  `APP_STORE_RELEASE.md`, `APP_STORE_REVIEW_CHECKLIST.md`,
  `CODEX_REVIEW_PLAN.md`. Moved to repo root: `ARCHITECTURE.md`. Kept
  in `docs/` as legitimate public content: `index.html`,
  `support.html`, `privacy.html`, `INSTALLATION.md`,
  `sensor-kickstart/`.
- **Published GitHub Pages refreshed with personality.** The three HTML
  pages (`index.html`, `support.html`, `privacy.html`) were rewritten
  to match the app's actual voice — confident self-awareness instead
  of dry marketing speak — while keeping every bit of genuinely useful
  content and adding cheeky-but-helpful FAQs ("Wait, what is this
  app?", "Is this a joke?", "Do I actually need this? — No.", "Can I
  use this as a drum machine?"). The support page's accelerometer FAQ
  walks users through the sandbox situation and links to the
  sensor-kickstart helper for opt-in power users.
- **`@MainActor` → `MainActor` in all prose, commit messages, CHANGELOG,
  and release bodies.** Source code `.swift` files intentionally keep
  the `@MainActor` attribute — it is a compiler-enforced Swift language
  construct and GitHub's @-mention parser does not index source code
  blobs. Prose was scrubbed because GitHub was resolving `@MainActor`
  in commit bodies to an unrelated GitHub user whose login happens to
  collide with the Swift concurrency attribute. Two `git filter-repo`
  passes + force-push on master/develop + v1.0.0 re-tag cleaned the
  history; this release is clean by construction.

### Added
- **CLAUDE.md + scratch-doc patterns** now in `.gitignore`. Project-
  specific Claude Code instructions live in a gitignored
  `CLAUDE.md` at the repo root with the project-specific hard rules
  (no `@MainActor` in prose, no author email anywhere, build system
  quick reference, branch protection convention, helper internals).
  Ad-hoc scratch docs (`*.scratch.md`, `*.tmp.md`, `.plans/`, `.dev/`,
  `scratch/`, `plans/`, etc.) are all gitignored so they never leak
  into the repo.
- **IOKit system power message constants** (`MsgCanSystemSleep`,
  `MsgSystemWillSleep`, `MsgSystemHasPoweredOn`) are defined
  numerically in the helper because Swift's C importer cannot
  translate the `iokit_common_msg(X)` macro expansion. Values are
  `0xe0000000 | X` per `IOKit/IOMessage.h` and are stable across
  every macOS release since IOKit was introduced.
- **CI workflow** now bumps `actions/checkout` from `v4` to `v5` to
  stay off the Node.js 20 deprecation treadmill.

### Removed
- **Email contact** (`support@studnicky.com`) removed from every
  published page. GitHub Issues is now the only support channel, and
  every page that would otherwise say "email X" now says "file an
  issue at github.com/Studnicky/yamete/issues" with the same
  friendliness. `docs/privacy.html` Contact section points at
  `issues/new` instead of a `mailto:` link, with a one-liner
  explaining that because the app collects nothing and sends nothing
  over the network, there's nothing to ask about privately — open
  issues make better documentation anyway.

## [1.0.0] - 2026-04-10

### Critical
- **App Store accelerometer: runtime availability probe replaces the
  unconditional passive-read assumption.** The prior "passive HID read
  always works because macOS warms the SPU sensor at boot" hypothesis
  was falsified by a cold-boot verification on a clean Mac with Yamete
  Direct uninstalled: `ioreg -rxc AppleSPUHIDDriver` showed the accel
  service (`dispatchAccel = Yes`, BMI286) with `ReportInterval = 0x0`,
  no `HIDEventServiceProperties` dict, and `DebugState._num_events = 0`.
  Two consecutive App Store launches (BTM auto + manual `open`) both
  produced `Watchdog staleness=5.0s sampleCount=0` — zero samples
  received, zero events in the driver. Conclusion: macOS does NOT
  independently warm the SPU accelerometer at cold boot; in prior
  observations the sensor was warm only because Yamete Direct (which
  *can* write to IORegistry from outside the sandbox) had run earlier
  in the session and left the sensor active.

  **Fix**: `SPUAccelerometerAdapter.isAvailable` now does a runtime
  probe via `AccelHardware.isSensorActivelyReporting()` that reads
  `DebugState._last_event_timestamp` on the `AppleSPUHIDDriver` service
  and compares against `mach_absolute_time()`. The adapter reports
  available only when the sensor has emitted a report within the last
  500ms (`AccelHardwareConstants.sensorActivityStalenessNs`). With this
  probe, `Migration.reconcileSensors` — which already runs on every
  launch and prunes unavailable adapters — correctly drops the
  accelerometer from the pipeline when the sensor is cold, letting the
  microphone + headphone-motion fallback path activate cleanly instead
  of letting the 5s watchdog fire on an empty stream while the user
  sees no impacts at all.

  **Driver internals discovered while building the probe**:
    - `IORegistryEntrySetCFProperty` with `ReportInterval`,
      `SensorPropertyReportingState`, `SensorPropertyPowerState` is a
      command channel, not a stored value. The driver's `setProperty`
      accepts the write, triggers the hardware, and returns
      `KERN_SUCCESS` without updating the IOKit property dict — so
      property read-back on the service always returns `0` regardless
      of whether the sensor is streaming.
    - `DebugState._num_events` is a monotonic counter that freezes at
      deactivation and doesn't reset until reboot — useless as a
      "currently active" signal on its own.
    - `DebugState._last_event_timestamp` (in `mach_absolute_time`
      units) is the only field that decays correctly when the sensor
      goes cold.
    - Sandbox rejection of `IORegistryEntrySetCFProperty` happens
      *before* the driver's `setProperty` is reached — the call
      returns `KERN_SUCCESS` to the client but the write never lands.
      This is why the App Store build cannot activate the sensor
      itself and depends on an external kickstart path.

  **External sensor kickstart for App Store users**: A minimal Swift
  helper (`docs/sensor-kickstart/yamete-sensor-kickstart.swift`) +
  LaunchDaemon plist is provided via support docs. Users who want the
  accelerometer in the App Store build compile it once with `swiftc`,
  install the LaunchDaemon to `/Library/LaunchDaemons/`, and reboot.
  The helper does the same three `IORegistryEntrySetCFProperty` writes
  that the Direct build's `SensorActivation.activate()` does, and
  since it runs outside App Sandbox its writes reach the driver. The
  sensor stays active across subscriber cycles and sleep/wake, and
  the daemon re-runs the kickstart on every wake as defense in depth.
  Verified empirically: after kickstart, the App Store build's probe
  returns true and `adapters=["Accelerometer", ...]` logs alongside
  `sampleCount=` entries at sustained 100Hz.

  **Sleep/wake verified (2026-04-10)**: The BMI286 is in Apple
  Silicon's always-on power domain. Verified empirically that once
  kickstarted, the sensor continues streaming at 100Hz across
  sleep/wake cycles without interruption — a 35-second sleep period
  advanced `_num_events` from 101 to 3615 (100.4 events/sec, exactly
  the awake rate), meaning the driver was emitting reports the entire
  time the lid was closed.

  **Still to verify on other Mac models and macOS revisions**:
  1. **Multiple Apple Silicon models.** All testing so far is on a
     single development MacBook. Should be re-verified on M1 / M2 /
     M3 / M4 across MacBook Air / MacBook Pro before submission to
     confirm `AppleSPUHIDDriver` / `dispatchAccel` / `DebugState` are
     present and behave identically on each generation.
  2. **macOS revisions.** `IORegistryEntrySetCFProperty` on
     `AppleSPUHIDDriver` with these specific property keys is an
     undocumented Apple-internal surface. A future macOS update could
     break it. Re-test before every App Store submission, and monitor
     reports via the support-docs helper link.

- **Accelerometer stream watchdog**: `SPUAccelerometerAdapter` now spawns
  a background `Task` per stream that polls `ReportContext.lastReportAt`
  every 1 second. If no reports arrive for 5 seconds, the watchdog calls
  `surfaceStall()` which terminates the stream with a recoverable
  `SensorError.ioKitError`. The controller's existing fusion path then
  falls back to microphone + headphone-motion automatically. The
  watchdog is cancelled in cleanup phase 0 so it cannot race with
  teardown. Polls do not race with `handleReport` — `lastReportAt` lives
  inside the same `OSAllocatedUnfairLock<State>` block.

- **HID teardown race fix**: `HIDRunLoopThread.join()` now blocks the cleanup
  path until the dedicated HID worker thread has fully exited. CF object
  mutations (`IOHIDManagerUnscheduleFromRunLoop`, `IOHIDManagerClose`) are
  reordered to run only after `join()`. ThreadSanitizer reproduced a SEGV
  in `CF_IS_OBJC` during cancel-before-first-report; the fix is TSAN-clean.
- **Unaligned `Int32` reads in accelerometer decoder**: Replaced
  `withMemoryRebound` (undefined behavior on misaligned offsets 6/10/14)
  with `UnsafeRawPointer.loadUnaligned(fromByteOffset:as:)`.
- **IOHIDEventSystemClient activation restored**: The C bridging header (IOHIDPublic.h) must declare `IOHIDEventSystemClientCreate` (full client). Using `IOHIDEventSystemClientCreateSimpleClient` silently fails to activate the SPU accelerometer — the sensor opens but delivers no reports. The full client is required to set ReportInterval on hardware services.

### Added
- **Dual-build resource architecture**: `App/Resources/{locale}.lproj/Moans.strings`
  ships tame App-Store-safe content; `App/Resources-Direct/{locale}.lproj/Moans.strings`
  overlays spicy content for the notarized direct-download build only. The
  Makefile rsync overlay step is gated on the directory's existence so the
  App Store build never sees the spicy strings. `appstore-lint` Makefile
  target greps the bundle for `daddy` as a leakage gate.
- **Notification mode** (Flash Mode = Notification): posts an impact banner
  with a tier-appropriate flirty title + reaction body. Runtime locale picker
  lets users select the notification language independently of system language.
  40 locales supported.
- **`NotificationPhrase` random pool loader**: parses `Moans.strings` for a
  given locale into prefix-grouped `[String]` arrays at first use, cached
  with `OSAllocatedUnfairLock`. Single-source-of-truth `resolveLocale`
  guarantees title and body always come from the same language per notification.
- **Always-on menu bar face reaction**: the menu bar icon swaps to a face
  image on every detected impact, independent of Flash Mode. Uses a cached
  face library rebuilt only on dark/light mode changes.
- **`AccelerometerLifecycleStressTests`**: 25-cycle repeated open/close +
  10-cycle cancel-before-first-report stress tests. Skips on hosts without
  an SPU device.
- **`NotificationResponderTests`**: 8 unit tests for `NotificationPhrase`
  resolveLocale fallback, pool selection, and random sampling. Uses an
  internal `_testInject` seam since `.lproj` resources are bundled by the
  Makefile, not the SPM test runner.
- **`Makefile lint` target**: `swiftc -typecheck -strict-concurrency=complete
  -warnings-as-errors`. Currently passes clean.
- **`Makefile appstore-lint` target**: bundle-content gate that fails if any
  shipped `Moans.strings` contains the substring `daddy`.

### Changed
- **Renamed `FlashResponder` → `VisualResponder`** to match current responsibilities
  (overlay AND notification both implement it).
- **Rewrote `APP_STORE_METADATA.md`**: age rating 12+, content descriptors
  reflect the dual-build distinction, App Review notes acknowledge that
  the accelerometer driver-property surface is undocumented and offer to
  remove the path entirely if Review prefers.
- **Rewrote `APP_STORE_RELEASE.md` BLOCKER-1**: removed the "Risk: Low"
  framing; now explicitly distinguishes public IOKit symbols (compliant)
  from undocumented driver behavior (gray area under 2.5.1).
- **`screenFlash` is now a computed proxy** over `visualResponseMode`.
  `Key.screenFlash` removed from `SettingsStore.Key`; the persisted
  `screenFlash` UserDefault is consumed once at init for legacy migration
  (`screenFlash == false` forces `visualResponseMode = .off`), then deleted.
- **`ImpactController.shouldBeEnabled`** reads `visualResponseMode != .off`
  directly instead of `screenFlash`.
- **`-strict-concurrency=complete` cleanup**: `FaceRenderer.Palette` is
  `Sendable`; `currentPalette` and `loadFaces(palette:)` are `MainActor`;
  `Fmt` slider formatters are `@Sendable` closures; `arrayToggleBinding`
  is `MainActor` and requires `T: Sendable`; `GateRows` is `MainActor`;
  `Toggle.themeMiniSwitch` is `MainActor`; `OnceCleanup` requires
  `T: Sendable`; `LogStore.State` is `@unchecked Sendable` (lock-protected).
- Removed the `import YameteApp` self-import from `YameteApp.swift` (was a
  Makefile-only no-op warning that became an error under `-warnings-as-errors`).

### Removed
- **`FaceRenderer.composeIcon`**: was used to render a 1024×1024 dock-icon
  variant of the face. Yamete is `LSUIElement` (no Dock icon at all), so
  the compose path was dead code.
- **All `NSApp.applicationIconImage` swap code**: same reason — no Dock.
- **All `moan_*` and `title_*` keys from `App/Resources/*.lproj/Localizable.strings`**.
  These now live in `Moans.strings` (tame) and the Direct overlay (spicy).
- **Editorialized translator comments** ("DDLG kink register", etc.) from
  the App-Store-bound `Localizable.strings` files. Spicy comments survive
  only in `App/Resources-Direct/`, never shipped to the Store.

### Fixed
- **Visual Response = Off no longer animates dock/menu bar in disallowed
  ways**: dock did not exist; menu bar always reacts (now documented).
  Setting renamed UI label to "Flash Mode".
- **Notification copy mismatch**: hint text no longer claims notifications
  "clear when the cooldown ends" — it now correctly says the entry is
  removed from Notification Center, with banner visibility controlled by
  macOS.
- **`notification_title` showing as a literal key**: `LocalizedStrings`
  helper falls back to the main bundle (which goes through
  `CFBundleDevelopmentRegion`) when a key is missing in the requested
  lproj. Title and body now both resolve correctly across locales.
- **Menu bar icon scaling during reaction**: SVG NSImage is resized to
  18pt logical size before storing in `reactionFace`. The menu bar honors
  intrinsic NSImage size, not SwiftUI `.frame()`, inside MenuBarExtra.
- Site, privacy, and support pages aligned with the dual-build reality
  and the actual (non-existent) Dock surface.

### Added
- ImpactTier enum (Tap/Light/Medium/Firm/Hard) with tier display in menu footer
- DetectionConfig struct for atomic configuration of detection parameters
- AudioResponder and VisualResponder protocols for dependency injection
- SensorID type-safe identifier newtype
- NSScreen.displayID extension replacing duplicated NSDeviceDescriptionKey usage
- AccordionCard and SettingHeader reusable UI components
- Per-setting SF Symbol icons with tappable inline help
- Collapsible Device Settings and Sensitivity Settings panels
- Crest factor gate with background RMS tracking (1-second EMA)
- Privacy policy (PRIVACY.md) and PrivacyInfo.xcprivacy manifest
- App Sandbox with device.usb entitlement for Mac App Store
- All user-facing strings wrapped in NSLocalizedString

### Changed
- Accelerometer: IOHIDEventSystemClient activation + IOHIDManager reading (public IOKit API)
- Detection: 4-algorithm voting → 6-gate pipeline (bandpass, spike, rise rate, crest factor, confirmations, rearm)
- Sensitivity renamed to Reactivity with inverted mapping (higher = more reactive)
- Assets loaded from sounds/ and faces/ folders recursively by extension
- Sound selection: pre-sorted by duration at startup, intensity maps to clip length
- ImpactController split into detect() → respond() with DetectedImpact struct
- Debounce merged with rearm into single Cooldown control
- SensorFusionEngine renamed to ImpactFusionEngine
- Frequency band: configurable bandpass (HP 20Hz + LP 25Hz default)
- All detection parameters exposed as user-configurable advanced settings
- Entitlements consolidated to single file (Yamete.entitlements)
- Makefile: hardened runtime, proper process kill cycle, release target cleanup
- Config push to detection engine cached (only on change, not per sample)
- HID thread init: DispatchSemaphore replaces spinlock
- LogStore graceful fallback when Application Support unavailable

### Fixed
- MainActor isolation on ImpactFusionEngine (was unconfined)
- ScreenFlash hide Task missing MainActor (AppKit thread safety)
- Updater Tasks missing MainActor (state mutation isolation)
- EventContext use-after-free on stream termination
- Force unwraps in AccelerometerReader run loop and mode resolution
- Rise rate gate checking instantaneous value instead of window peak
- Settings schema reset wiping all user preferences on every default change

### Removed
- ImpactDetector, SignalDetectors, DetectorConfig (replaced by ImpactFusionEngine)
- Self-updater (updates via Mac App Store)
- Licensing infrastructure (LicenseManager, LicenseStore, trial period)
- Schema version reset mechanism (UserDefaults.register handles new keys)
- Yamete-hardened.entitlements (consolidated into Yamete.entitlements)
- Prefix-based asset naming requirement (sound_*, face_*)
- Unused SliderRow view component and AudioDeviceUID type

## [0.0.0] - 2026-04-02

### Added
- Impact detection via BMI286 accelerometer on Apple Silicon Macs
- Menu bar UI with branded pink theme
- Audio and visual response to impacts
- Dual-sink logging with 24-hour retention
- Build via Makefile with swiftc
- MIT license

[Unreleased]: https://github.com/Studnicky/yamete/compare/v0.0.0...HEAD
[0.0.0]: https://github.com/Studnicky/yamete/releases/tag/v0.0.0
