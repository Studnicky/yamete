# App Store Connect Metadata

## App Identity

- **App Name**: Yamete
- **Subtitle**: Desk Impact Reactions
- **Bundle ID**: com.studnicky.yamete
- **SKU**: YAMETE001
- **Category**: Entertainment
- **Secondary Category**: Utilities
- **Price**: Tier 3 ($2.99 USD)
- **Availability**: All territories
- **Age Rating**: 12+ (see Content Rating section below)
- **Copyright**: 2026 Studnicky

> **Build distinction**: this metadata applies to the App Store build only.
> Two builds exist: the **App Store build** (rated 12+, ships with the tame
> `App/Resources/.../Moans.strings`) and a separate **Direct build** (notarized
> direct download, ships with the spicy `App/Resources-Direct/.../Moans.strings`
> overlay added by the `Direct` Makefile target). The Direct build is **not**
> submitted to the App Store.

## Description

### Promotional Text (170 chars, can be updated without review)

Slap your desk, tap your laptop, get a reaction. Multi-sensor impact detection with audio and visual feedback. Fully configurable, fully private.

### Full Description (4000 chars max)

Yamete is a macOS menu bar app that detects physical impacts on your MacBook and responds with sound effects and animated screen flashes.

Three sensors work together to detect impacts: the built-in accelerometer reads physical vibrations, the microphone picks up desk impact sounds, and AirPods/Beats headphone motion sensing adds a third input channel. Each sensor runs its own detection pipeline with configurable sensitivity, and a consensus engine fuses their results before triggering a response.

When an impact is confirmed, the app selects a sound clip scaled to impact intensity (harder hits play longer, louder sounds) and flashes an animated overlay on your selected monitors. Every parameter is tunable from the menu bar dropdown.

DETECTION
- Built-in BMI286 accelerometer (Apple Silicon Macs)
- Microphone transient detection (all Macs)
- Headphone motion via AirPods Pro / Beats
- 6-gate analysis pipeline: spike threshold, rise rate, crest factor, confirmations
- Multi-sensor consensus with configurable agreement threshold
- Adjustable cooldown between reactions

RESPONSE
- Sound clips selected by impact intensity (audio always-on when enabled)
- Always-on menu bar face icon reaction on every detected impact
- Flash Mode (off / overlay / notification) for the visual response
  - **Overlay**: per-monitor screen flash with animated face
  - **Notification**: posts an impact banner with a tier-appropriate
    flirty playful one-liner; entry is removed from Notification Center
    after the cooldown
- Selectable notification language (independent of system language)
- Reactivity, volume, and flash opacity range controls
- Multi-device audio output selection

CONFIGURATION
- Range sliders for reactivity, volume, and flash windows
- Per-sensor tuning (accelerometer, microphone, headphone motion)
- Per-sensor enable/disable
- Launch at Login

PRIVACY
- Zero network connections
- No data collection, no tracking, no ads
- No account required
- Microphone audio processed in real-time, never recorded
- Logs auto-delete after 24 hours

COMPATIBILITY
- All Macs: microphone + headphone-motion impact detection (default)
- MacBook Air / MacBook Pro (Apple Silicon): an optional one-time external
  helper warms the built-in BMI286 accelerometer at boot via a user-installed
  LaunchDaemon, adding a third detection channel. Setup is documented on
  the support page; the App Store build itself cannot warm the sensor from
  inside the sandbox.
- Requires macOS 14.0+ (Sonoma), arm64 binary

Yamete runs entirely in the menu bar with no Dock icon. Microphone-based
impact detection works on every Mac out of the box; the accelerometer is a
power-user opt-in on Apple Silicon MacBooks that adds a tactile detection
channel complementary to the microphone.

## Keywords (100 chars max)

impact,accelerometer,desk,slap,reaction,menu bar,sound,flash,sensor,tap,vibration

## URLs

- **Privacy Policy**: https://studnicky.github.io/yamete/privacy.html
- **Support URL**: https://studnicky.github.io/yamete/support.html
- **Marketing URL**: https://studnicky.github.io/yamete/

## Screenshots

Required resolutions (at least 1 each):
- 1280x800 (MacBook Air 13")
- 1440x900 (MacBook Air 15")  
- 2560x1600 (Retina MacBook Pro 14")
- 2880x1800 (Retina MacBook Pro 16")

Screenshot ideas:
1. Menu bar dropdown showing main controls (Reactivity, Volume, Flash)
2. Screen flash in action with face overlay
3. Advanced settings panel (Accelerometer Tuning expanded)
4. Device selection panel
5. Multiple monitors with different flash states

## App Review Notes

```
What the app does:
  Yamete detects physical impacts (desk slaps, taps) on Apple Silicon MacBooks
  using the built-in accelerometer, microphone, and headphone motion. It
  responds with audio clips and an optional visual response (full-screen
  overlay or notification banner). It runs as a menu bar (LSUIElement) app
  with no Dock icon and no app windows.

Accelerometer implementation note (please read carefully):
  The App Store build ships with the accelerometer detection path present
  but **runtime-gated**: it only activates when the kernel driver is already
  actively reporting, which inside the App Sandbox we cannot cause ourselves.
  `IORegistryEntrySetCFProperty` writes to the `AppleSPUHIDDriver` service
  are silently dropped by the sandbox before they reach the driver, so the
  App Store build itself never starts the sensor.

  On launch, the adapter reads `DebugState._last_event_timestamp` from the
  driver service (a read-only IORegistry lookup that works from inside
  sandbox) and compares it to `mach_absolute_time()`. If the delta exceeds
  500ms — meaning no reports have been emitted recently, i.e. the sensor
  is cold — the adapter reports `isAvailable = false` and the settings
  reconciler prunes it from the pipeline entirely. The app then runs on
  microphone + headphone-motion only, which is the default experience for
  every App Store user.

  For users who want the tactile detection channel, the support page links
  an open-source GitHub gist containing a minimal Swift helper
  (`yamete-accel-warmup.swift`) plus a LaunchDaemon plist. The helper
  compiles with `swiftc`, installs to `/usr/local/libexec/`, and runs as
  a long-lived LaunchDaemon that warms the sensor once at boot and then
  subscribes to IOKit system power notifications via
  `IORegisterForSystemPower` to re-warm on every wake event. Because
  the LaunchDaemon runs outside the App Sandbox, its writes reach the
  driver successfully. The daemon idles at effectively zero CPU when
  nothing is happening (parked in `CFRunLoopRun` waiting for wake
  notifications), so the Yamete App Store build's subsequent
  `IOHIDManager` subscription receives the live 100Hz stream with no
  further involvement from the app itself.

  IOKit symbols used by the app (all in public SDK headers):
    - IOServiceGetMatchingServices (IOKit/IOKitLib.h)
    - IORegistryEntryCreateCFProperty (IOKit/IOKitLib.h) — availability probe
    - IOHIDManagerCreate (IOKit/hid/IOHIDManager.h)
    - IOHIDDeviceRegisterInputReportCallback (IOKit/hid/IOHIDDevice.h)
  No private API symbols are imported. The `com.apple.security.device.usb`
  entitlement is the documented entitlement for `IOHIDManager` access.

  The service class name (`AppleSPUHIDDriver`) and the property keys read
  by the probe (`DebugState._last_event_timestamp`, `dispatchAccel`) are
  Apple-internal implementation details of the SPU HID driver, not
  documented SDK constants. The app uses public IOKit read functions to
  inspect an undocumented driver surface; this is not a private API import.

  Why any of this matters: there is no public Apple API for macOS
  accelerometer access. `CMMotionManager` is `API_UNAVAILABLE(macos)`, and
  no replacement has been provided. The BMI286 is a real piece of hardware
  on every Apple Silicon MacBook and the `AppleSPUHIDDriver` is its only
  host-accessible surface. If App Review prefers that we remove this code
  path entirely, we are happy to ship App Store with microphone +
  headphone-motion only — the runtime probe already guarantees the
  accelerometer code is dormant unless a user has explicitly opted in via
  the external helper.

  Graceful degradation: if the accelerometer is cold, the adapter is
  pruned before pipeline start and the app runs on the remaining sensors.
  If the sensor goes cold mid-session (e.g., after sleep), the existing
  5-second stream watchdog surfaces the stall and the fusion engine
  continues on the other adapters. There is no user-visible error state.

Why microphone access is needed:
  The microphone detects impact sounds (desk taps, slaps) as a complementary
  sensor to the accelerometer. Audio data is processed in real-time for
  transient detection only (peak extraction per buffer). No audio is recorded,
  stored, or transmitted. Users can deny microphone access and use
  accelerometer-only detection.

How to test:
  1. Launch the app (appears in menu bar as a face icon)
  2. Click the menu bar icon to see the settings dropdown
  3. Grant microphone permission when prompted (optional)
  4. Firmly tap or slap the desk next to the MacBook
  5. The app will play a sound and flash the screen
  6. Adjust Reactivity slider to change sensitivity
  7. Expand "Sensitivity & Sensors" for advanced tuning
  8. Expand "Devices" to select audio outputs and displays

Testing note:
  The accelerometer requires physical impact on or near the MacBook.
  Remote testing via screen sharing will not trigger accelerometer detection.
  Microphone detection can be triggered by any sharp transient sound near
  the Mac's built-in microphone.
```

## Content Rating Questionnaire (App Store build)

| Question | Answer |
|----------|--------|
| Violence | None |
| Sexual Content or Nudity | None |
| Profanity or Crude Humor | None |
| Drugs/Alcohol/Tobacco | None |
| Gambling | None |
| Horror/Fear | None |
| Medical/Treatment | None |
| Mature/Suggestive Themes | Infrequent/Mild |
| Unrestricted Web Access | No |
| Contests | None |

**Result**: 12+ (Ages 12 and Up)

### Rationale for Mature/Suggestive Themes = Infrequent/Mild

The App Store build ships with the tame `Moans.strings` pool only. Notification
copy is flirty/playful but not sexual ("Mm, again?", "Show off~", "Whoa!",
"OUCH"). The app concept (a name derived from the Japanese word for "stop"
and a notification voice that reacts to laptop impacts in a flirty register)
warrants the Infrequent/Mild Mature/Suggestive Themes descriptor and the
12+ rating, even though no explicit content is present.

The Direct build (notarized download, NOT submitted to the App Store) ships
with the spicy `App/Resources-Direct/.../Moans.strings` overlay containing
DDLG-register sub vocabulary. That build is rated separately and is not the
subject of this App Store submission.

### Build content guarantee

The App Store build's bundle MUST NOT contain the spicy moans. Verification
gate: any `Moans.strings` shipped in the App Store build that contains the
substring "daddy" in any locale should fail bundle lint.
