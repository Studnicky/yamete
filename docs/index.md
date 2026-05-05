---
title: Yamete
description: A macOS menu bar app that reacts when you smack your laptop. Three sensors. Eleven event triggers. Forty languages. Zero shame.
layout: doc
---

<div class="yamete-hero">
 <h1>Yamete</h1>
 <p class="tagline">Lives in your menu bar. Watches the accelerometer, the microphone, your AirPods. Reacts when you touch it. The face has range. The sounds have opinions. The Direct build has no shame at all.</p>
 <div class="actions">
 <a href="https://github.com/Studnicky/yamete/releases/latest">Download (Direct)</a>
 <a class="alt" href="./architecture">How it works</a>
 <a class="alt" href="https://github.com/Studnicky/yamete">Source</a>
 </div>
</div>

It also watches your USB ports, power adapter, audio peripherals, Bluetooth, Thunderbolt, every display, sleep and wake, the lid hinge, the gyro, the ambient-light sensor, the thermal pressure level. Picking one would be rude.

Built because I felt like it. Runs offline. Stores nothing. Will not improve your life in any way I'd describe with a straight face. *That's the whole point.*

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

That sounded bratty to me. I touched it anyway.

The result is a fully functional excuse to touch your laptop too hard. Engineering equivalent of a ship in a bottle. Hard part invisible, finished thing useless, dinner-party explanation awkward in a way I personally enjoy.

> If you use this daily I want to know what's wrong with you. If you install it, laugh once, and delete it, that's the right outcome and I'm glad you stopped by.

## How the bus works

All events flow through a single `ReactionBus`. Two emission patterns feed it.

**Continuous-stream sources** (accelerometer, microphone, gyroscope, ambient light) run a detection pipeline over a high-frequency sample stream. Raw samples pass through bandpass filtering and a six-gate analysis: spike threshold, rise rate, crest factor, confirmation count, warmup, cooldown. The source emits exactly one Reaction when the pipeline crosses threshold. Raw samples never leave the source.

The accelerometer, gyroscope, and ambient-light sensor all live behind a single Apple Silicon SPU HID device. `AppleSPUDevice` ref-counts the open handle so the four sensors share one device, decode their own byte offsets from the same kernel report, and only release the device when nobody is listening.

**Discrete state-transition sources** (USB, power, audio, Bluetooth, Thunderbolt, display, sleep and wake, lid angle, thermal pressure) observe an OS notification, an IOKit callback, or a KVO surface. They emit one Reaction per user-meaningful state change. Lid opens past 10 degrees. Lid slams. Lights flip off. Thermal pressure crosses to `.serious`. USB attaches. Same bus.

When enough impact sensors agree inside a fusion window the fused impact publishes onto the bus. Before any output sees it, the bus stamps it once with a clip duration and face selection so sound, screen flash, LED, and notification all see the same pre-selected face and the same pre-selected clip. Every response stays in sync regardless of how many outputs are firing.

Outputs subscribe independently and filter through their per-reaction toggle matrix. A reaction with LED and sound enabled and flash off produces a pulse and a clip and nothing on screen. The matrix is a hard gate.

It is a menu bar app (`LSUIElement`). No Dock icon. No app windows. No onboarding wizard asking how you heard about it. All controls live in the menu bar dropdown because some of us have standards.

## How seriously is this tested (way too)

For a joke app whose pitch is "your laptop yells when you smack it," the test apparatus is oversexed.

* ~795 unit and integration cells across two SPM build variants (default and `DIRECT_BUILD`)
* A 130-entry **mutation catalog**. Every entry is a deliberate code change to a production gate that must cause a named test to fail. Every gate caught.
* Property-based fuzz over the bus invariants (1600 random cases per cell). Concurrent-interleaved fuzz that spawns multiple producers on overlapping timelines and asserts no missed drop, no double action, no leaked task. Settings-corruption fuzz against `SettingsStore`. Locale by plural fuzz across 40 locales.
* ~28 SwiftUI snapshot baselines per build variant across 4 variants (`AppStore`, `Direct`, `HostApp`, `CI`). Pixel diffs catch a header layout regression before it ships.
* Performance baselines with a 2x tolerance band. Crash-handling boundary audit. Driver Real-vs-Mock parity. Cross-boundary fault injection at every Source / Bus / Output seam.
* A two-hour `xcodebuild` host-app integration lane that runs the test bundle inside a real `Yamete.app`. Cells gated on Accessibility, the full Haptic engine, and the macOS notification center exercise their real-driver paths instead of skipping. Locally on Apple Silicon: 4 minutes.
* A pre-push hook that refuses to push a release branch unless the host-app run is fresh. Once was enough.

None of this proves the laptop actually flinches when you hit it. That part you have to verify yourself. Sorry.

## Privacy (nothing leaves, nothing)

Zero network connections. Everything happens locally. Microphone audio gets scanned for transient peaks and thrown away the same frame. Nothing recorded. Logs auto-delete after 24 hours. No accounts. No tracking. No ads. No telemetry. No analytics. No "just this once."

If that sounds suspiciously clean, the source is public. Read every line. [Full Privacy Policy.](/privacy)

## Requirements

* macOS 14.0 or later (Sonoma)
* Apple Silicon MacBook (M1 through M4) so it can feel you smacking it
* Any Mac with a microphone so it can hear you smacking it
* AirPods Pro or Beats for headphone motion (optional, very silly, recommended)

On an Intel Mac, iMac, Mac Mini, Mac Studio, or Mac Pro: microphone detection works fine. Every system event source above works on every Mac. You just cannot physically smack the laptop, on account of not having a laptop. Life finds a way.

## Two builds

* **Yamete.** The Mac App Store build, rated 12+, with tame notification copy ("Mm, again?", "Show off~", "OUCH"). Plausibly deniable in most workplaces.
* **Yamete Direct.** A notarised direct download with notification copy that has fewer brakes on. Not submitted to the App Store. For consenting adults who knew what they were clicking.

Same detection engine. Same event sources. Same sounds. Same face library. Same 40 locales. Only difference: what your Mac says about it.

## Accelerometer setup on App Store (optional)

The App Store build runs under App Sandbox. Sandbox quietly drops the IORegistry writes that would wake the BMI286, so out of the box that build runs on microphone and headphone motion only. Fine. The microphone path is good.

Want the full tactile channel? Use the open-source [Sensor Kickstart](/sensor-kickstart/) helper. Compile one Swift file. Install it as a LaunchDaemon. It wakes the sensor at boot and re-warms it on every wake. Yamete picks up the live stream automatically.

> Tried it? [File an issue](https://github.com/Studnicky/yamete/issues/new) either way. Putting together a known-working matrix across M1 through M4. Every data point counts.

## Support

The [Support page](/support) covers setup, tuning, false positives, the whole accelerometer situation, and a handful of questions invented because they were funny.

Something broken or weird on your M3 Air: [GitHub Issues.](https://github.com/Studnicky/yamete/issues) Only support channel. Don't email the author.
