# Yamete test suite

Two tiers of tests, both run by default on every `swift test` invocation.

## Test tiers

- **Unit** (`Tests/`): default `swift test`. Mocked drivers, no hardware. Fast.
- **Integration** (`Tests/Integration/`): default `swift test`. Cross-layer
  with mocks (binding ↔ store, view layout, source ↔ bus ↔ output flow).
  Some integration tests use REAL drivers and self-skip via `XCTSkip` when
  the specific hardware isn't present on the running machine.

CI runs both tiers on every push. Hardware-dependent tests self-skip on
cloud Mac runners that lack a built-in display, keyboard backlight,
accessible audio output device, etc.

To force-fail the suite when a hardware test is skipped, run with the
explicit assertion:

```sh
swift test --package-path .
```

and verify "skipped" count is what you expect for your machine.

## Base classes

- `IntegrationTestCase` — `@MainActor`, no environment flag required by
  default. Subclasses can override `requiresEnvironmentFlag` to gate a
  specific test class on an env var. Real-driver tests inherit this class
  and self-skip via `XCTSkip` when the specific hardware isn't present.

## When to add a test where

| Test scenario | Tier |
|---|---|
| Pure function with no side effects | Unit |
| Mock-driven driver behavior, single layer | Unit |
| SwiftUI binding → SettingsStore writes a specific keyPath | Integration |
| Layout invariants under presence-flag combinations | Integration |
| Source → ReactionBus → Output through real types (mock drivers) | Integration |
| Real CoreAudio / CoreBrightness / IOHIDManager round-trip | Integration (real-driver, self-skip on absent hardware) |
| Bundle resource discovery against the running process | Integration (real-driver, self-skip in SPM context) |

## Running locally

```sh
# Full suite (unit + integration, hardware tests self-skip when absent):
swift test

# Integration tier only:
swift test --filter Integration

# Direct-build-only suite (Volume Override + Updater paths):
swift test -Xswiftc -DDIRECT_BUILD
```

## Test seams worth knowing

- `Yamete._testSetHardwarePresence(...)` — drives every IOKit /
  DisplayServices presence flag without touching real hardware. Used by
  `PanelLayoutTests` to assert layout invariants under every combination
  of haptic / brightness / tint / trackpad / mouse / keyboard presence.
- `AudioPlayer._testInjectSoundLibrary(_:duration:)` — synthetic sound
  library for `peekSound` tests; the SPM test bundle has no `sounds/`
  directory so the production preload path leaves the player empty.
- `*Section.*KeyPaths` static helpers — single source of truth between
  view rendering and binding-integrity assertions. See
  `BindingIntegrityTests` for usage.
