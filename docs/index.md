---
layout: home

hero:
  name: Yamete
  text: Your MacBook reacts when you smack it.
  tagline: Three sensors, eleven event sources, forty languages, zero shame. Runs entirely offline. Stores nothing.
  image:
    src: /icon.png
    alt: Yamete app icon
  actions:
    - theme: brand
      text: Download (Direct)
      link: https://github.com/Studnicky/yamete/releases/latest
    - theme: alt
      text: How it works
      link: /architecture
    - theme: alt
      text: Source
      link: https://github.com/Studnicky/yamete

features:
  - title: Three Sensors, One Opinion
    details: Built-in accelerometer, microphone transient detection, and AirPods IMU. A consensus engine fuses them so a passing truck doesn't make your laptop cry in public.
  - title: Eleven Event Sources
    details: USB, power, audio peripherals, Bluetooth, Thunderbolt, display hotplug, sleep/wake, lid angle, thermal pressure, gyroscope spikes, ambient-light step changes. Each its own per-output toggle.
  - title: SPU Sensor Multiplexer
    details: Apple Silicon's SPU HID exposes accelerometer, gyroscope, lid angle, and ambient light through a single in-kernel handle. AppleSPUDevice ref-counts it so all four sensors share one open device.
  - title: Sound Clips With Taste
    details: Impact intensity picks the clip. A gentle tap gets a small "mm~". A full send gets something considerably more expressive. Volume and clip pool tunable.
  - title: The Face
    details: A live face in the menu bar with eleven expressions, scaled to hit intensity. Reacts whether Flash Mode is on or off. It does not look away.
  - title: Flash Mode
    details: Full-screen overlay with a radial-gradient reaction face. Exactly as dramatic as it sounds. Toggle off if your job depends on it.
  - title: LED Flash
    details: Caps Lock LED flickers and the keyboard backlight springs through a damped animation on every reaction. Independent toggles, configurable brightness.
  - title: Per-Reaction Output Matrix
    details: Every output (sound, screen flash, notification, LED) has independent per-event toggles. Sound on USB attach, LED on AC unplug, fully orthogonal.
  - title: 40 Languages
    details: Notification copy in 40 locales, switchable independently of system language. Nothing says "person of culture" like getting scolded by your MacBook in Portuguese.
  - title: Knobs For Days
    details: Sensitivity, volume, flash opacity, LED brightness, per-sensor gate tuning, cooldown debounce. Dial it in until it knows you better than you know yourself.
---

## Why though?

Apple Silicon MacBooks ship with a real BMI286 accelerometer, the same one that's in phones. Apple exposes zero public API for it on macOS. The entire `CMMotionManager` surface is `API_UNAVAILABLE(macos)`. I read that as an invitation.

The result is a fully functional reason to touch your laptop too enthusiastically. It's the engineering equivalent of building a ship in a bottle: the hard part is invisible, the finished thing is not especially useful, and explaining why you spent so much time on it gets awkward at dinner parties.

> If you use this daily, I genuinely want to know why. If you install it, laugh once, and delete it, that's a completely valid outcome and I'm glad you stopped by.

## How it works

All events — impacts and system notifications alike — flow through a single `ReactionBus`. Two emission patterns feed the bus.

**Continuous-stream sources** (accelerometer, microphone, gyroscope, ambient light) run their own detection pipeline over a high-frequency stream: raw samples pass through bandpass filtering and a six-gate analysis (spike threshold, rise rate, crest factor, confirmation count, warmup, cooldown), and the source emits exactly one Reaction when the pipeline crosses threshold. Raw samples never leave the source. The accelerometer, gyroscope, and ambient-light sensor share a single Apple Silicon SPU HID device through a ref-counted multiplexer.

**Discrete state-transition sources** (USB, power, audio, Bluetooth, Thunderbolt, display, sleep/wake, lid angle, thermal pressure) observe an OS notification, an IOKit callback, or a KVO surface and emit one Reaction per user-meaningful state change — lid opens past 10°, lid slams, lights flip off, thermal pressure crosses to `.serious`, USB attaches. Same bus.

When enough impact sensors agree within a fusion window, the fused impact publishes onto the bus. Before any output sees a reaction, the bus stamps it once with a clip duration and face selection — so sound, screen flash, LED, and notification all see the same pre-selected face and audio clip, keeping every response in sync regardless of how many outputs are active.

Outputs subscribe independently and filter by their per-reaction toggle matrix. A reaction with LED and sound enabled but flash disabled produces a pulse and a clip, and nothing on screen.

It's a menu bar app (`LSUIElement`). No Dock icon, no app windows, no onboarding wizard asking how you heard about it. All controls live in the menu bar dropdown, because some of us have standards.

## How seriously is this tested

For a joke app whose entire value proposition is "your laptop yells when you smack it," the test apparatus is genuinely disproportionate.

- ~795 unit and integration cells across two SPM build variants (default and `DIRECT_BUILD`).
- A 130-entry **mutation catalog** — every entry is a deliberate code change to a production gate that must cause a named test to fail. Every gate is caught.
- Property-based fuzz over the bus invariants (1600 random cases per cell). Concurrent-interleaved fuzz that spawns multiple producers on overlapping timelines and asserts no missed drop, no double-action, no leaked task. Settings-corruption fuzz against the `SettingsStore`. Locale × plural fuzz across 40 locales.
- ~28 SwiftUI snapshot baselines per build variant across 4 variants (`AppStore`, `Direct`, `HostApp`, `CI`).
- Performance baselines with a 2× tolerance band. Crash-handling boundary audit. Driver Real-vs-Mock parity. Cross-boundary fault injection at every Source / Bus / Output seam.
- A two-hour `xcodebuild` host-app integration lane that runs the test bundle inside a real `Yamete.app` so cells gated on Accessibility, the full Haptic engine, and the macOS notification center exercise their real-driver paths instead of skipping. (Locally on Apple Silicon: 4 minutes.)
- A pre-push hook that refuses to push a release branch unless the host-app run is fresh, because once was enough.

None of this proves the laptop actually flinches when you hit it. That part you have to verify yourself. Sorry.

## Privacy

Zero network connections. All sensor data processed locally, in real time. Microphone audio is analyzed for transient peaks and immediately discarded. Nothing recorded. Logs auto-delete after 24 hours. No accounts, no tracking, no ads, no telemetry, no analytics.

If that sounds suspiciously clean, the source code is public. [Full Privacy Policy](/privacy).

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon MacBook (M1 through M4) for the tactile accelerometer channel
- Any Mac with a microphone for the sound-based path, which works everywhere
- AirPods Pro or Beats for headphone motion (optional, but it's deeply silly and therefore recommended)

On an Intel Mac, iMac, Mac Mini, Mac Studio, or Mac Pro: microphone detection works fine. USB, power, audio, Bluetooth, Thunderbolt, display, and sleep/wake events work on every Mac. You just can't physically smack the laptop.

## Two builds

- **Yamete** — the Mac App Store build, rated 12+, with tame notification copy ("Mm, again?", "Show off~", "OUCH"). Plausibly deniable in most workplaces.
- **Yamete Direct** — a notarized direct download with considerably spicier notifications. Not submitted to the App Store. For consenting adults who specifically wanted that.

Same detection engine, same event sources, same sounds, same face library, same 40 locales. The only difference is what your Mac says about it.

## Accelerometer setup on App Store

The App Store build runs under App Sandbox. Sandbox silently blocks the IORegistry writes needed to wake the accelerometer, so out of the box that build uses microphone and headphone motion only. Honestly that's fine. The microphone path is good.

If you want the full tactile channel on an Apple Silicon MacBook, there's a small open-source helper: see [Sensor Kickstart](/sensor-kickstart/). You compile one Swift file with `swiftc` and install it as a LaunchDaemon. It kickstarts the sensor at boot and re-warms it on every wake event. Yamete picks up the live stream automatically.

> Tried it? [File an issue](https://github.com/Studnicky/yamete/issues/new) either way. Building a known-working matrix across M1 through M4, and every data point helps.

## Support

The [Support page](/support) covers setup, tuning, false positives, the whole accelerometer situation, and a handful of questions invented because they were funny.

Something broken or weird on your M3 Air: [GitHub Issues](https://github.com/Studnicky/yamete/issues). That's the only support channel. Please don't email the author.
