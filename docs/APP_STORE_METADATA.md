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
- MacBook Air / MacBook Pro (Apple Silicon): all three sensors — accelerometer, microphone, headphone motion
- Other Apple Silicon Macs (iMac, Mac Mini, Mac Studio, Mac Pro): microphone and headphone motion only
- Intel Macs: runs via Rosetta 2 with microphone and headphone motion only
- Requires macOS 14.0+ (Sonoma), arm64 binary

Yamete runs entirely in the menu bar with no Dock icon. Best experienced on Apple Silicon MacBooks with the built-in accelerometer. All Macs can use microphone-based impact detection.

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
  This app reads the built-in BMI286 accelerometer using the public IOKit
  framework. The imported symbols are all publicly declared in the SDK
  headers shipped with Xcode:
    - IOServiceGetMatchingServices (IOKit/IOKitLib.h)
    - IORegistryEntrySetCFProperty (IOKit/IOKitLib.h)
    - IOHIDManagerCreate (IOKit/hid/IOHIDManager.h)
    - IOHIDDeviceRegisterInputReportCallback (IOKit/hid/IOHIDDevice.h)
  No private API symbols are imported. The com.apple.security.device.usb
  entitlement is the documented entitlement for IOHIDManager access.

  The activation step uses these public IOKit functions to set driver
  properties on `AppleSPUHIDDriver` services. The driver class name and
  the property keys (`ReportInterval`, `SensorPropertyReportingState`,
  `SensorPropertyPowerState`) are not surfaced in the public SDK headers
  as documented constants — they are Apple-internal implementation details
  of the SPU HID driver. We are using public IOKit APIs to talk to an
  undocumented driver surface; we are not using private APIs.

  Why this matters: there is no public Apple API for macOS accelerometer
  access. `CMMotionManager` is `API_UNAVAILABLE(macos)`, and no replacement
  has been provided. The IOKit + AppleSPUHIDDriver path is the only way
  to read the built-in accelerometer from a third-party macOS app. If you
  prefer that we remove this code path entirely from the App Store build,
  we are happy to do so — accelerometer detection is one of three sensor
  inputs and the app continues to function with microphone and headphone
  motion only.

  Graceful degradation: if accelerometer activation fails for any reason
  (sandbox restriction, driver unavailable, OS version mismatch), the app
  continues to detect impacts via the microphone and headphone motion
  sensors. There is no error state and no degraded user experience.

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
