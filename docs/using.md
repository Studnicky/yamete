---
title: Using Yamete
description: Plain-English guide to every slider, every toggle, every icon in the menu bar dropdown. The user manual.
---

# Using Yamete

*The menu bar dropdown has more knobs than the joke deserves. This page walks each one in plain English. If you want the numerical ranges and the sensor-gate math, that lives in [Architecture > Configuration.](/architecture/configuration)*

Open the menu bar by clicking the face icon. The panel is grouped into three columns of accordions. Each accordion expands to show its sliders + toggles.

## Header

The strip at the top of the panel. A 2x2 grid: title + impacts counter on the first row, rotating subtext + last-impact tier on the second.

* **The face.** Reacts on every detected impact. Eleven expressions, scaled to hit intensity. Reacts whether Flash Mode is on or off. It does not look away.
* **Yamete (title) + tagline strip.** A slow-rotating one-liner that pulls from the spicy moan pool (Direct build) or the tame copy (App Store).
* **Impacts today counter.** Counts fused impacts since local midnight.
* **Last impact tier.** The tier name (`tap` / `light` / `medium` / `firm` / `hard`) of the most recent impact.

## Diagnostics row

Sits directly below the header. Hidden when there are no active diagnostics. When something needs your attention, this is where it shows up — so you don't have to scroll an accordion to find it.

| Diagnostic | When it shows | Action |
|---|---|---|
| **Paused** | Impact pipeline is stopped (master toggle off, or sensor pruning emptied the active set). | Informational. Re-enable a sensor or flip the Impact Detection master back on. |
| **Input Monitoring required** | The macOS TCC privilege class for keyboard, mouse clicks, and Caps Lock LED is missing. Most common after `make install` rebuilds the bundle (cdhash changes, macOS revokes the prior grant). | Click **Open System Settings…** to deep-link to Privacy & Security → Input Monitoring. Toggle Yamete Direct on. |
| **Sensor error** | The fusion engine raised a hard error from one of the impact sensors (most often: accelerometer report stream stalled past the 5-second watchdog). | Surfaces the underlying error message verbatim. The fix usually lives in [Architecture > Detection gates](/architecture/detection-gates). |

## Impact Detection

Impact reactions are the original Yamete event. The accelerometer, the microphone, and your AirPods all run their own pipeline; a consensus engine fuses them.

| Slider / toggle | What it controls |
|---|---|
| **Reactivity** (range slider, two thumbs) | The sensitivity band. Higher = more reactive. Below the lower thumb, an impact is rejected silently. Above the upper thumb, intensity caps at 1.0. |
| **Impact Consensus** (1-10) | How many impact sensors must agree inside a 0.15s window for the fused impact to fire. 1 means any single sensor wins. 2 forces at least two; cuts most false positives. |
| **Cooldown** (0-2s) | After a fused impact fires, ignore further impacts for this many seconds. Stops a single smack from triggering a string of reactions. |
| **Per-sensor toggles** (Accelerometer / Microphone / AirPods) | Master enable per sensor. A disabled sensor does not contribute to consensus. |
| **Per-sensor tuning accordions** | Each impact sensor has its own collapsible tuning section: Spike Threshold, Crest Factor, Rise Rate, Confirmations, Warmup, etc. Default values work for most users. The full list is in [Configuration.](/architecture/configuration) |

## Events

System-level events. Each fires its own reaction.

| Toggle | What it watches |
|---|---|
| **USB** | Device attach / detach. |
| **Power** | AC adapter plug / unplug. |
| **Audio peripheral** | USB DAC / headset / external speaker connect / disconnect. |
| **Bluetooth** | Bluetooth device connect / disconnect. |
| **Thunderbolt** | Thunderbolt port attach / detach. |
| **Display** | Monitor hotplug / display reconfiguration. |
| **Sleep / Wake** | System will-sleep + has-powered-on. |
| **Lid angle** | Open / closed / slammed. The slam threshold is its own slider. |
| **Gyroscope** | Lid yank, laptop spin (rotational spike). |
| **Ambient light** | Lights off, lights on, sensor covered (hand over the sensor). |
| **Thermal pressure** | macOS thermal state transition. The slider next to this row is the **ratchet**: see below. |

### Thermal sensitivity ratchet

Thermal pressure has four states (`nominal`, `fair`, `serious`, `critical`). The ratchet slider gates which transitions actually fire a reaction:

| Position | What fires |
|---|---|
| 0 | Off. No thermal reactions. |
| 1 | `critical` only. The "your fan is screaming" tier. |
| 2 (default) | `serious` + `critical`. The "this is starting to matter" tier and above. |
| 3 | `fair` + `serious` + `critical`. Everything except idle nominal recovery. |
| 4 | All four states, including `nominal` (every recovery to idle). |

Cold-start suppression always applies: launching Yamete on an already-warm Mac does NOT fire whatever state the system happens to be in. Only transitions count.

## Activity

Three sources that watch your input devices and react to specific patterns.

| Toggle | What it watches | Reactions |
|---|---|---|
| **Trackpad** | Multitouch + scroll | Touching, sliding, contact (fingers resting), tapping, circling (full revolution). |
| **Mouse** | External mouse only (filters trackpad-originated events) | Click, sustained scroll. |
| **Keyboard** | Sliding rate window over key-presses | Typing rate threshold crossed. |

## Outputs

Per-output master toggles plus the per-event matrix.

| Output | What it does | Master controls |
|---|---|---|
| **Sound** | Plays an intensity-picked clip from the audio pool on every reaction. | Volume range slider (two thumbs); each clip plays at a random volume sampled from inside the band. |
| **Screen flash** | Borderless overlay window with a radial-gradient face. | Flash Opacity range slider; Flash Mode three-way (Off / Overlay / Notification). |
| **Keyboard LED** | Caps Lock LED + keyboard backlight pulse. | Master toggle, brightness range. Caps Lock and backlight are independent sub-toggles. |
| **Notifications** | Banner via NSUserNotification. | Master toggle. Locale dropdown (40 languages, switchable independently of system language). |

### The per-event toggle matrix

Below each output's master controls is a matrix of toggles, one row per reaction kind. An output fires for a given reaction only when **both** the master toggle is on and the matrix cell for that reaction is on. This is how you get "sound on USB attach but flash off" or "LED only for impacts, nothing else."

The matrix has one column per output (Sound, Flash, LED, Notification) and one row per reaction kind (`impact`, `usbAttached`, `acDisconnected`, ..., `thermalCritical`). Click a cell to toggle.

## Devices

Pick which physical devices the outputs talk to.

| Picker | What it controls |
|---|---|
| **Audio output** | Which Core Audio device(s) the sound clips play on. Multi-select. Each row carries an icon derived from its CoreAudio transport class (laptop = built-in, TV = DisplayPort/HDMI, cable = USB, headphones = wireless or analog). When the audio device is paired to a connected display via EDID match (DisplayPort/HDMI) or built-in association (MacBook speakers + built-in display), an "attached to *<display>*" footnote appears under the device name. See [Architecture > Display / audio pairing](/architecture/display-audio-pairing) for the matching algorithm and the topologies it can't resolve. |
| **Display** | Which monitor(s) get the screen-flash overlay. Multi-select. |
| **Keyboard** | Which physical keyboard the LED + backlight pulse drives. Useful when an external keyboard is attached. |

### Active-only toggles

Both display and audio device lists offer an "active *X* only" toggle that **only renders when ≥2 devices are selected** — with 0 or 1 selected the toggle adds no signal and is hidden.

| Toggle | Effect when ON |
|---|---|
| **Active display only** (above the display list) | The screen flash routes to `NSScreen.main` (the display with key focus at impact time) regardless of which displays are selected below. The list is dimmed and not interactive while the toggle is on. |
| **Active output only** (above the audio list) | Impact sounds route to the system default audio output (whatever you're currently listening through), ignoring the per-device selection below. The list is dimmed and not interactive while the toggle is on. |

Both toggles are disabled-by-default. They survive across launches.

## Footer

* **Reset to defaults** restores every slider, toggle, and matrix cell to its factory value (`Defaults.swift`).
* **Quit Yamete** exits cleanly. The orchestrator drains the bus, releases the SPU HID handle, and writes the LED brightness sentinel before exit.

---

If a setting on this page maps to a code-level constant you want to inspect, the [Configuration](/architecture/configuration) reference table has every default + range.
