---
title: Yamete
description: A macOS menu bar app that reacts when you smack your laptop. Three sensors. Eleven event triggers. Forty languages. Zero shame.
layout: doc
---

<div class="yamete-hero">
  <img src="/icon.png" alt="Yamete app icon">
  <div>
    <h1>Yamete</h1>
    <p class="tagline">Lives in your menu bar. Watches the accelerometer, the microphone, your AirPods. Reacts when you touch it. The face has range, the sounds have opinions, and the Direct build has no shame whatsoever.</p>
    <div class="actions">
      <a href="https://github.com/Studnicky/yamete/releases/latest">Download (Direct)</a>
      <a class="alt" href="./architecture">How it works</a>
      <a class="alt" href="https://github.com/Studnicky/yamete">Source</a>
    </div>
  </div>
</div>

It also watches your USB ports, the power adapter, audio peripherals, Bluetooth, Thunderbolt, every display, sleep and wake, the lid hinge, the gyro, the ambient-light sensor, and the thermal pressure level. Why react to one event when you can react to all of them.

Built because I wanted to. Runs entirely offline. Stores nothing. Will not meaningfully improve your life. *That's the whole point.*

## What it does (the menu)

| Section | What lives there |
|---|---|
| Header | The face. Live, eleven expressions, scaled to hit intensity. Reacts whether Flash Mode is on or off. It does not look away. It has seen things. |
| Impact detection | Accelerometer, microphone, AirPods motion. The consensus engine fuses them so a passing truck doesn't make your laptop cry in public. Per-sensor threshold knobs if you want to tune the sensitivity to your own touch. |
| Events | USB attach, AC unplug, audio peripheral, Bluetooth, Thunderbolt, display hotplug, sleep and wake, lid open / closed / slammed, gyroscope spike, ambient light step, thermal pressure transition. Each event has its own toggle row across the four outputs. |
| Outputs | Sound, Screen Flash, LED Flash, Notifications. Every output has a master toggle plus an event-by-event matrix. Sound on USB attach, LED on AC unplug, no flash on Bluetooth (fully orthogonal, fully yours). |
| Devices | Pick which audio output, which display gets the flash overlay, which keyboard the LED talks to. |

## Why it exists

Apple Silicon MacBooks ship with a real BMI286 accelerometer. Same chip class as the one in your phone. Apple exposes zero public macOS API for it. The whole `CMMotionManager` surface is `API_UNAVAILABLE(macos)`.

I read that as an invitation.

The result is a fully functional reason to touch your laptop with intent. The engineering equivalent of a ship in a bottle. The hard part is invisible. The finished thing is not especially useful. Explaining why it exists at dinner parties is awkward, in a way I find personally fulfilling.

> If you use this daily I genuinely want to know why. If you install it, laugh once, and delete it, that's a perfectly valid outcome and I'm glad you stopped by.

## How the bus works

All events flow through a single `ReactionBus`. Two emission patterns feed it.

**Continuous-stream sources** (accelerometer, microphone, gyroscope, ambient light) run a detection pipeline over a high-frequency sample stream. Raw samples pass through bandpass filtering and a six-gate analysis: spike threshold, rise rate, crest factor, confirmation count, warmup, cooldown. The source emits exactly one Reaction when the pipeline crosses threshold. Raw samples never leave the source.

The accelerometer, gyroscope, and ambient-light sensor all live behind a single Apple Silicon SPU HID device. `AppleSPUDevice` ref-counts the open handle so the four sensors share one device, decode their own byte offsets from the same kernel report, and only release the device when nobody is listening.

**Discrete state-transition sources** (USB, power, audio, Bluetooth, Thunderbolt, display, sleep and wake, lid angle, thermal pressure) observe an OS notification, an IOKit callback, or a KVO surface. They emit one Reaction per user-meaningful state change. Lid opens past 10 degrees. Lid slams. Lights flip off. Thermal pressure crosses to `.serious`. USB attaches. Same bus.

When enough impact sensors agree inside a fusion window the fused impact publishes onto the bus. Before any output sees it, the bus stamps it once with a clip duration and face selection so sound, screen flash, LED, and notification all see the same pre-selected face and the same pre-selected clip. Every response stays in sync regardless of how many outputs are firing.

Outputs subscribe independently and filter through their per-reaction toggle matrix. A reaction with LED and sound enabled and flash off produces a pulse and a clip and nothing on screen. The matrix is a hard gate.

It is a menu bar app (`LSUIElement`). No Dock icon. No app windows. No onboarding wizard asking how you heard about it. All controls live in the menu bar dropdown because some of us have standards.

## How seriously is this tested (way too)

For a joke app whose entire premise is "your laptop yells when you smack it," the test apparatus is genuinely disproportionate.

* ~795 unit and integration cells across two SPM build variants (default and `DIRECT_BUILD`)
* A 130-entry **mutation catalog**. Every entry is a deliberate code change to a production gate that must cause a named test to fail. Every gate caught.
* Property-based fuzz over the bus invariants (1600 random cases per cell). Concurrent-interleaved fuzz that spawns multiple producers on overlapping timelines and asserts no missed drop, no double action, no leaked task. Settings-corruption fuzz against `SettingsStore`. Locale by plural fuzz across 40 locales.
* ~28 SwiftUI snapshot baselines per build variant across 4 variants (`AppStore`, `Direct`, `HostApp`, `CI`). Pixel diffs catch a header layout regression before it ships.
* Performance baselines with a 2x tolerance band. Crash-handling boundary audit. Driver Real-vs-Mock parity. Cross-boundary fault injection at every Source / Bus / Output seam.
* A two-hour `xcodebuild` host-app integration lane that runs the test bundle inside a real `Yamete.app`. Cells gated on Accessibility, the full Haptic engine, and the macOS notification center exercise their real-driver paths instead of skipping. Locally on Apple Silicon: 4 minutes.
* A pre-push hook that refuses to push a release branch unless the host-app run is fresh. Once was enough.

None of this proves the laptop actually flinches when you hit it. That part you have to verify yourself. Sorry.

## Privacy (nothing leaves, nothing)

Zero network connections. All sensor data processed locally, in real time. Microphone audio is analysed for transient peaks and immediately discarded. Nothing recorded. Logs auto-delete after 24 hours. No accounts, no tracking, no ads, no telemetry, no analytics, no "just this once" exceptions to any of the above.

If that sounds suspiciously clean, the source code is public and you are welcome to read every line. [Full Privacy Policy.](/privacy)

## Requirements

* macOS 14.0 or later (Sonoma)
* Apple Silicon MacBook (M1 through M4) for the tactile accelerometer channel
* Any Mac with a microphone for the sound-based path, which works everywhere
* AirPods Pro or Beats for headphone motion (optional, deeply silly, therefore recommended)

On an Intel Mac, an iMac, a Mac Mini, a Mac Studio, or a Mac Pro: microphone detection works fine. Every system event source above works on every Mac. You just cannot physically smack the laptop, on account of not having a laptop. Life finds a way.

## Two builds

* **Yamete.** The Mac App Store build, rated 12+, with tame notification copy ("Mm, again?", "Show off~", "OUCH"). Plausibly deniable in most workplaces.
* **Yamete Direct.** A notarised direct download with considerably less restrained notification copy. Not submitted to the App Store. For consenting adults who specifically wanted that.

Same detection engine. Same event sources. Same sounds. Same face library. Same 40 locales in both. The only difference is what your Mac says about it.

## Accelerometer setup on App Store (optional)

The App Store build runs under App Sandbox. Sandbox silently blocks the IORegistry writes needed to wake the BMI286, so out of the box that build uses microphone and headphone motion only. Honestly fine. The microphone path is good.

If you want the full tactile channel on an Apple Silicon MacBook, there is a small open-source helper at [Sensor Kickstart.](/sensor-kickstart/) Compile one Swift file with `swiftc`, install it as a LaunchDaemon. It kickstarts the sensor at boot and re-warms it on every wake event. Yamete picks up the live stream automatically.

> Tried it? [File an issue](https://github.com/Studnicky/yamete/issues/new) either way. Building a known-working matrix across M1 through M4. Every data point helps.

## Support

The [Support page](/support) covers setup, tuning, false positives, the whole accelerometer situation, and a handful of questions invented because they were funny.

Something broken or weird on your M3 Air: [GitHub Issues.](https://github.com/Studnicky/yamete/issues) Only support channel. Please don't email the author.
