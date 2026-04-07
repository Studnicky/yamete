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
- **Age Rating**: 4+
- **Copyright**: 2026 Studnicky

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
- Sound clips selected by impact intensity
- Per-monitor screen flash with animated face overlays
- Reactivity, volume, and flash opacity range controls
- Multi-device audio output selection

CONFIGURATION
- Range sliders for reactivity, volume, and flash windows
- Advanced accelerometer tuning (frequency band, spike threshold, crest factor, rise rate)
- Per-sensor enable/disable
- Launch at Login
- Debug logging for troubleshooting

PRIVACY
- Zero network connections
- No data collection, no tracking, no ads
- No account required
- Microphone audio processed in real-time, never recorded
- Logs auto-delete after 24 hours

Yamete runs entirely in the menu bar with no Dock icon. It is designed for Apple Silicon MacBooks but also supports microphone-only detection on any Mac.

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
  using the built-in accelerometer and microphone. It responds with audio clips
  and animated screen flash overlays. It runs as a menu bar app.

Why USB entitlement is needed:
  The com.apple.security.device.usb entitlement enables IOHIDManager access to
  read the built-in BMI286 accelerometer via public IOKit APIs. The app uses
  IOHIDEventSystemClientCreate and IOHIDServiceClientSetProperty (public SDK
  headers) to activate the sensor, and IOHIDManager with
  IOHIDDeviceRegisterInputReportCallback to read motion data. No private APIs
  are used. The accelerometer detects physical impacts on the device.

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

## Content Rating Questionnaire

| Question | Answer |
|----------|--------|
| Violence | None |
| Sexual Content | None |
| Profanity | None |
| Drugs/Alcohol/Tobacco | None |
| Gambling | None |
| Horror/Fear | None |
| Medical/Treatment | None |
| Mature/Suggestive Themes | None |
| Unrestricted Web Access | No |
| Contests | None |

**Result**: 4+ (Ages 4 and Up)
