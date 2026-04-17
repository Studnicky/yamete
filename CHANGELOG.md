# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

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
