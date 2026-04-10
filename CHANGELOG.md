# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Critical
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
  `Sendable`; `currentPalette` and `loadFaces(palette:)` are `@MainActor`;
  `Fmt` slider formatters are `@Sendable` closures; `arrayToggleBinding`
  is `@MainActor` and requires `T: Sendable`; `GateRows` is `@MainActor`;
  `Toggle.themeMiniSwitch` is `@MainActor`; `OnceCleanup` requires
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
- @MainActor isolation on ImpactFusionEngine (was unconfined)
- ScreenFlash hide Task missing @MainActor (AppKit thread safety)
- Updater Tasks missing @MainActor (state mutation isolation)
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
