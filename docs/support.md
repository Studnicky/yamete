---
title: Support
description: Setup, tuning, troubleshooting, and a handful of questions invented because they were funny.
---

# Support

Everything you need to know about Yamete. Plus a few things you didn't ask for.

::: tip Something broken? Something weird? Something that made you laugh?

[Open an issue on GitHub.](https://github.com/Studnicky/yamete/issues) GitHub Issues is the only support channel for this project. Bugs, feature ideas, and "I don't know if this is a bug but it made a noise I didn't expect" all welcome. Please don't email the author.

:::

## Wait, what is this app?

### What does Yamete actually do?

Lives in your menu bar. When you smack your Mac, it reacts. A sound clip plays, a face shows, optionally the screen flashes or a notification banner fires. Gentle pat gets a small "mm~". Proper smack gets something more committed. The face has range.

Under the hood: three parallel detection pipelines (accelerometer, microphone, AirPods IMU), fused via a consensus engine, scaled to impact intensity. Significantly more engineered than the concept deserves. I'm at peace with that.

### What does "Yamete" mean?

Japanese for "stop." The playful, flirty register, not the "I mean it" register. Closer to "stop it~" than "cease immediately." Perfect.

### Is this a joke?

The concept is completely silly. The implementation is not. Swift 6 with full strict concurrency, multi-sensor signal processing with proper bandpass filters, a real consensus engine, thread-safe HID stream cleanup, a full test pyramid. Treat it as a serious engineering exercise in service of an extremely unserious idea.

### Why does this exist?

Apple Silicon MacBooks ship with a real BMI286 accelerometer, and Apple marks all of `CMMotionManager` as `API_UNAVAILABLE(macos)`. That isn't a warning. That's a dare.

Also I wanted to. Full stop.

### Do I actually need this?

No. That has never been the pitch.

## Event triggers

Beyond physical impacts, Yamete reacts to a range of system events. Each toggles independently from the Events section in the menu bar dropdown.

* **USB.** Device attach and detach
* **Power.** AC adapter plug and unplug
* **Audio.** Audio peripheral attach and detach (USB DACs, headsets, that kind)
* **Bluetooth.** Device connect and disconnect
* **Thunderbolt.** Port attach and detach
* **Display.** Monitor hotplug / reconfiguration
* **Sleep / Wake.** System will-sleep and system has-powered-on
* **Lid angle.** Open / closed / slammed (hinge angle from the SPU)
* **Thermal.** Pressure transitions (nominal / fair / serious / critical)
* **Gyroscope.** Lid yank, laptop spin
* **Ambient light.** Lights flipped, sensor covered

All event sources ship enabled by default. Toggling one off stops Yamete from reacting to it. The impact detection pipeline is unaffected.

### How do I control which events fire which outputs?

Each event type has its own row of per-output toggles in the Events section. The four outputs (Sound, Flash, LED, Notification) toggle independently for every event type. USB attach plays a sound and flashes the screen but stays silent on power events. Bluetooth connect notifications stay enabled while sound is muted for that event. Up to you.

Impact detections from the accelerometer, microphone, and headphone motion channels have the same per-output toggles, controlled from the Outputs section. The matrix applies on top of each output's master toggle. An output must be enabled globally **and** enabled for the specific reaction kind before it fires.

## Setup and usage

### How do I get it running?

Download the DMG from the [latest release.](https://github.com/Studnicky/yamete/releases/latest) Drag `Yamete Direct.app` into Applications. Open it. A face appears in your menu bar. Click the face to open the dropdown. Tune whatever you like. On first launch it asks for microphone permission. Say yes unless you specifically don't want the microphone path.

The App Store build installs normally once App Review finishes being coy about it.

### What's the difference between Yamete and Yamete Direct?

* **Yamete** is the Mac App Store build, rated 12+, with tame notification copy: "Mm, again?", "Show off~", "OUCH". Broadly safe for office use, probably.
* **Yamete Direct** is a notarised direct download with considerably less restrained notification copy. Same everything else: engine, sounds, face, settings, 40 locales. Just has more to say about what you did.

### Does it work on Intel Macs, iMacs, Mac Mini, Mac Studio, Mac Pro?

Partially. None of those have the built-in BMI286 accelerometer, so the tactile channel is unavailable. Microphone-based detection works on any Mac with a mic. AirPods headphone motion works whenever AirPods Pro or Beats are connected. So yes, it runs. It is just a different kind of sensitive.

On Intel Macs the binary runs via Rosetta 2 (arm64 only).

### My MacBook's accelerometer isn't working in the App Store build

Short version. App Sandbox silently blocks the IORegistry writes that would wake the accelerometer. The App Store build cannot do it on its own. Not a bug. That's sandboxing.

Long version. Apple provides no public macOS API for accelerometer access, so the app talks to the SPU HID driver directly via public IOKit functions. Those functions are callable from inside sandbox, but the kernel silently drops the property writes before they reach the driver. The sensor stays cold, the availability probe catches it at launch, and the accelerometer adapter is dropped from the pipeline. The app continues on microphone and headphone motion. Honestly fine.

If you specifically want the tactile channel, there is a small open-source helper at [Sensor Kickstart.](/sensor-kickstart/) One Swift file, compiled with `swiftc`, installed as a LaunchDaemon. It wakes the sensor at boot and re-warms it on every wake event. Idle CPU cost is effectively zero.

> Tried it? [File an issue](https://github.com/Studnicky/yamete/issues/new) either way.

## Tuning

### Nothing is being detected at all

Walk through these in order.

1. Open the menu bar dropdown, expand Sensors, confirm at least one is enabled. If Accelerometer is the only one enabled and the sensor wasn't found at launch (common on App Store builds), it may have been auto-pruned. Enable Microphone too.
2. Check Reactivity. Both thumbs above zero. Very low settings miss real impacts.
3. If you granted microphone permission, make sure it is still active. System Settings → Privacy & Security → Microphone → Yamete.
4. Expand Accelerometer Tuning or Microphone Tuning and lower the Spike Threshold a notch. Then smack the desk firmly and with intent.

### Way too many false positives (footsteps, typing, the neighbours, a truck)

The consensus engine exists for this. Try:

* Raise Spike Threshold, Crest Factor, and Rise Rate.
* Set Confirmations to 3 or higher. The signal has to stay above threshold across multiple samples before anything fires.
* Raise Impact Consensus. Requiring two sensors to agree filters a lot. Typing won't register on the microphone, so that combination alone cuts most false hits.
* Add a Cooldown (0.5 to 1.0 seconds is a good start) to space out repeated reactions.

### No sound plays on impact

Check Volume range (both thumbs above zero), confirm a device is selected in Devices, make sure nothing is muted at the system level. Face reacting but no audio means one of those three.

### Screen flash isn't appearing

Flash Mode has three states: Off, Overlay, Notification. Confirm Overlay. Check Flash Opacity (both thumbs above zero), and make sure at least one display is selected in Devices. The overlay is gated to the sound clip duration, so audio needs to be working too.

### The keyboard LED / backlight isn't responding

1. Open the menu bar dropdown and expand Outputs. The Keyboard section has a master toggle at the top. Make sure it is on.
2. Inside the Keyboard section there are two separate sub-controls: the Caps Lock LED toggle, and the keyboard backlight brightness slider. Both independent. Check whichever one you want is enabled.
3. Keyboard backlight control requires macOS 14+ and uses the CoreBrightness private framework. Some externally attached keyboards and some older Mac models are not supported.
4. The brightness animation is a spring that oscillates around your current brightness level, not a fixed target. If the backlight is at zero when the reaction fires, the app falls back to the brightness level it read at launch. The net motion may be subtle at very low baseline brightness.

### The keyboard brightness is stuck off after a crash

If Yamete crashes mid-animation, the keyboard brightness can be left at the animated (near-zero) level. On the next launch the app reads a `kb_dirty` sentinel file written before the pulse began, recovers the pre-crash brightness level, restores the backlight, and deletes the sentinel. Automatic.

If the brightness does not restore on relaunch (sentinel lost, or the recovery path didn't reach your hardware), use the F5 / F6 brightness keys to set the level manually, or toggle keyboard backlight in System Settings → Keyboard.

### Notifications aren't appearing

Flash Mode needs to be set to Notification. macOS prompts for notification permission the first time. If you denied it: System Settings → Notifications → Yamete → enable banners. Notification language is switchable independently (40 locales, under Flash Mode).

### The menu bar icon keeps showing a face instead of the normal icon

That is the normal icon. The face reacts on every detected impact for the duration of the response. Eleven expressions, scaled to hit intensity. It has been watching. If you would rather it didn't, turn off Sound and set Flash Mode to Off. The face is tied to detection, not to Flash Mode specifically.

### CPU usage seems high

Idle should be under 2 percent. If higher: raise the Report Interval (20ms instead of 10ms halves the polling rate), disable sensors you don't use. Still high: [file an issue](https://github.com/Studnicky/yamete/issues/new) with your Mac model, macOS version, and Activity Monitor numbers.

### How do I uninstall?

**Yamete Direct:**

1. Drag `Yamete Direct.app` from Applications to the Trash.
2. Delete `~/Library/Preferences/com.studnicky.yamete.direct.plist`.
3. Delete `~/Library/Application Support/Yamete Direct/` if you want the logs gone too.

**Yamete (App Store):**

1. Delete `Yamete` from Applications.
2. Delete `~/Library/Containers/com.studnicky.yamete/` for the sandboxed data.

**Sensor kickstart helper** (only if you installed it): run `uninstall.sh`. It unloads the LaunchDaemon and removes the binary, the plist, and the log file.

## Questions I hoped you'd ask

### Will you add more sound effects?

Open an [issue](https://github.com/Studnicky/yamete/issues) with a royalty-free clip link and I will consider it. Custom sound pools are on the roadmap.

### Can I use this as a drum machine?

You could map per-intensity tiers to drum hits and tap rhythms out on your laptop lid. I do not recommend it. I also find the idea delightful. If you actually do this, please tell me.

### Will typing trigger it?

Normal typing doesn't produce a spike sharp enough to pass the detection gates at default settings. Very heavy typists on very light laptops might get the occasional false positive. Raise Spike Threshold a notch.

### Can I choose which face appears on each screen?

Not manually, but Yamete handles multiple displays automatically. When a reaction fires across more than one screen, each display gets a different face. The selection runs a deduplication pass so the same expression doesn't repeat across screens within a single reaction. The menu bar icon always shows the face assigned to the primary display.

### Is hitting my Mac bad for my Mac?

The app isn't bad for your Mac. Hitting your Mac hard enough to trigger it repeatedly might be bad for your Mac. Please be gentle. It has feelings now.

## System requirements

macOS 14.0+ (Sonoma), arm64 binary. BMI286 accelerometer channel requires an Apple Silicon MacBook. Everything else uses microphone and headphone motion. Microphone access is optional and requested at first launch. No Dock icon. No app windows. No noise you didn't ask for.
