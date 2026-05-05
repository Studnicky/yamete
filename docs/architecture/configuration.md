---
title: Configuration
description: Every tunable knob in Yamete, what it does, what it ranges over, and what the default is. Documentation as inventory.
---

# Configuration

*Every tunable knob in the app, reading directly from `YameteCore/Defaults.swift`, `YameteCore/Constants.swift`, and `YameteCore/ReactionsConfig.swift`. The point of this page is to make the design legible: if a number lives in production code, it lives on this page with a sentence about why.*

## Response controls

User-facing surface in the menu bar dropdown. Clamped on every `SettingsStore` write.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Sensitivity (min / max) | 0.10 / 0.90 | 0.0…1.0 | Inverted threshold band. High sensitivity → low intensity threshold → more reactions fire. Below the band an impact is rejected silently. Above it intensity is remapped onto a clean 0…1 the rest of the system uses. |
| Volume (min / max) | 0.50 / 0.90 | 0.0…1.0 | Range randomly sampled per-clip so the same clip does not play at the same level twice in a row. |
| Flash opacity (min / max) | 0.50 / 0.90 | 0.0…1.0 | Range randomly sampled per overlay so successive flashes vary. |
| Sound enabled | on | bool | Master toggle for `AudioPlayer`. Per-event row in the matrix still applies. |
| Screen flash enabled | on | bool | Master toggle for `ScreenFlash`. Per-event row in the matrix still applies. |
| Visual response mode | overlay | off / overlay / notification | Three-way switch under Flash Mode. |
| Debug logging | off | bool | Direct build only. Adds `[DEBUG]` lines to the file log; verbose. |

## Fusion / timing

Cross-sensor fusion lives in `ImpactFusion`. The values here are the contract between three parallel `ImpactDetector` streams.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Consensus | 1 | 1…10 | How many impact sensors must agree inside the fusion window for the fused impact to publish. 1 means any single sensor wins. 2 forces at least two. |
| Debounce | 0.5 s | 0…2 s | Cooldown after a fused impact publishes. The bus rejects another fused impact in the same window. |
| Fusion window | 0.15 s | constant | Sliding consensus window. A second sensor's spike has to land inside this many seconds of the first to count as agreement. |
| Rearm duration | 0.50 s | constant | After fusion fires, the engine ignores any further sensor agreement until this elapses. Difference between yelling once when you smack it and yelling four times because four sensors agreed within 200 ms. |

## Sensitivity gate math

`FusedImpact.applySensitivity(rawIntensity:sensitivityMin:sensitivityMax:)`:

```
thresholdLow  = 1.0 - sensitivityMax
thresholdHigh = 1.0 - sensitivityMin
if rawIntensity < thresholdLow:
    return nil   // reject — below the user's reactivity floor
remapped = (rawIntensity - thresholdLow) / max(0.001, thresholdHigh - thresholdLow)
return clamp(remapped, 0…1)
```

Result: low sensitivityMin (default 0.10) → high thresholdHigh (0.90) → wide band → most impacts pass. High sensitivityMin → narrow band → only the loudest impacts pass.

## Detection: accelerometer

BMI286 via IOKit HID through the SPU broker. Bandpass-filtered g-force.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Spike threshold | 0.020 g | 0.010…0.040 | Magnitude that has to be exceeded for the spike gate to fire. Lower is more reactive. |
| Crest factor | 1.5 | 1.0…5.0 | Ratio between peak and recent RMS. Filters sustained vibration (truck, fan) from sharp transients (smack). |
| Rise rate | 0.010 g/sample | 0.005…0.020 | Per-sample slope minimum. A slow ramp into threshold is rejected; sharp rises pass. |
| Confirmations | 3 | 1…5 | Number of consecutive samples that must hold above threshold. Cuts isolated noise. |
| Warmup samples | 50 | 10…100 | Filter-settling burn-in period before the detector publishes anything. |
| Report interval | 10 000 µs | 5 000…50 000 | IOKit HID report cadence in microseconds. 10 000 µs = 100 Hz polling. |
| Bandpass low | 20 Hz | 10…25 | High-pass corner; cuts low-frequency drift (gravity, posture). |
| Bandpass high | 25 Hz | 10…25 | Low-pass corner; cuts high-frequency hash. |
| Intensity floor | 0.002 g | const | Below this the published intensity clamps to 0. |
| Intensity ceiling | 0.060 g | const | Above this the published intensity clamps to 1. |

## Detection: gyroscope

BMI286 angular velocity in deg/s. Same SPU broker, different HID usage (9 vs 3).

| Setting | Default | Range | What it does |
|---|---|---|---|
| Spike threshold | 200 deg/s | 50…500 | Angular-velocity magnitude required to fire. |
| Crest factor | 2.5 | 1.5…5.0 | Peak-to-recent-RMS ratio. Filters sustained rotation (Mac picked up off a desk and walked) from sharp spikes (lid yank). |
| Rise rate | 50 deg/s/sample | 10…200 | Slope minimum. |
| Confirmations | 3 | 1…10 | Consecutive samples above threshold. |
| Warmup samples | 50 | 0…200 | Burn-in. |
| Intensity floor / ceiling | 50 / 500 | const | Magnitude clamping for the 0…1 published intensity. |

## Detection: lid angle

Hinge angle in degrees via SPU HID usage 8. State-machine driven.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Open threshold | 10° | 5°…30° | Angle above which the lid is considered open. Crossing from below fires `lidOpened`. |
| Closed threshold | 5° | 1°…10° | Angle below which the lid is considered closed. Crossing from above fires `lidClosed`. |
| Slam rate | -180 deg/s | -500…-50 | Closing rate (negative — closing reduces angle). If the lid crosses the closed threshold faster than this the event is `lidSlammed` instead of `lidClosed`. |
| Smoothing window | 100 ms | 50…500 | EMA window over Δangle/Δt to suppress jitter. |

## Detection: ambient light

Lux via SPU HID usage 7. Two-second ring buffer + step detector.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Cover-drop threshold | 0.95 (95 %) | 0.5…0.99 | Fractional lux drop required to fire `alsCovered` (hand over the sensor). |
| Off-drop percent | 0.80 (80 %) | 0.5…0.99 | Fractional drop required to fire `lightsOff` (switch flipped). |
| Off-floor lux | 30 lux | 1…300 | Post-drop ceiling — lux must end below this for `lightsOff` to fire. |
| On-rise percent | 1.50 (150 %) | 0.5…5.0 | Fractional rise required to fire `lightsOn`. |
| On-ceiling lux | 100 lux | 50…1000 | Post-rise floor — lux must end above this for `lightsOn` to fire. |
| Window | 2.0 s | 0.5…10.0 | Ring-buffer duration the step detector compares before-and-after over. |

## Detection: thermal

`ThermalSource` observes `NSProcessInfo.thermalStateDidChangeNotification`. **No tunable knobs.** The state set, the transition gates, and the cadence are all OS-defined. Cold-start suppression: the initial state captured at start does not publish (otherwise launching Yamete on an already-warm Mac would always fire `thermalFair`).

## Detection: microphone

High-pass-filtered PCM amplitude via `AVAudioEngine`.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Spike threshold | 0.020 | 0.005…0.100 | Amplitude required to fire (post HP filter). |
| Crest factor | 1.5 | 1.0…5.0 | Peak-to-recent-RMS ratio. Filters background noise from transient slaps. |
| Rise rate | 0.010 | 0.002…0.050 | Slope minimum. |
| Confirmations | 2 | 1…5 | Consecutive samples above threshold. |
| Warmup samples | 50 | 10…100 | Burn-in. |
| HP alpha | 0.95 | const | First-order IIR DC-block coefficient. |
| Target Hz | 50 | const | Downsample target the adapter aims for. |
| Intensity floor / ceiling | 0.005 / 0.300 | const | Amplitude clamping for the 0…1 published intensity. |

## Detection: headphone motion

`CMHeadphoneMotionManager`. AirPods Pro / Beats only.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Spike threshold | 0.10 g | 0.02…0.50 | userAcceleration magnitude required. |
| Crest factor | 1.5 | 1.0…5.0 | Peak-to-recent-RMS ratio. |
| Rise rate | 0.05 g/sample | 0.010…0.200 | Slope minimum. |
| Confirmations | 2 | 1…5 | Consecutive samples above threshold. |
| Warmup samples | 50 | 10…100 | Burn-in. |
| Intensity floor / ceiling | 0.05 / 2.0 g | const | Magnitude clamping for the 0…1 published intensity. |

## Activity sources (trackpad / mouse / keyboard)

These do not run the six-gate impact pipeline. They watch input device events directly.

| Source | Reactions | What it watches | Notes |
|---|---|---|---|
| `TrackpadActivitySource` | `trackpadTouching` / `trackpadSliding` / `trackpadContact` / `trackpadTapping` / `trackpadCircling` | NSEvent monitor for scroll/touch + IOKit HID multitouch listener | Circling: integrates Δangle from finger position, fires when `abs(circleAngleAccum) > 2π && circleEventCount >= 15`. |
| `MouseActivitySource` | `mouseClicked` / `mouseScrolled` | CGEvent tap on `.leftMouseDown` and `.scrollWheel` | Filters out trackpad-originated events via the device-attribution gate (so an external mouse click is not also credited to the trackpad source). |
| `KeyboardActivitySource` | `keyboardTyped` | CGEvent tap on `.keyDown`, sliding rate window | Crosses the rate threshold once and publishes; debounce-gated against re-publish. |

Per-event debounce gates live inside each source rather than in `ReactionsConfig` because the conflation patterns differ per source.

## Per-source bus debounce

Pinned in `ReactionsConfig`. These are not user-tunable.

| Source | Debounce | Why |
|---|---|---|
| `USBSource` | 0.05 s | macOS often emits 2-3 callbacks during device spin-up. |
| `DisplayHotplugSource` | 0.20 s | macOS emits 3-4 callbacks per real reconfiguration. |
| `GyroscopeSource` | 0.5 s | BMI286 reports at 100 Hz; cap publish so sustained-rotation does not flood the bus. |
| `AmbientLightDetector` | 1.0 s | Caps a flickering lamp / hand-pass-through from flooding the bus. |
| Audio peripheral, power, BT, Thunderbolt | (none) | Set-diff dedup or edge-state gating handles it. |

## Per-event synthesised intensity

`ReactionsConfig.eventIntensity` — every non-impact reaction publishes with a fixed intensity since there is no measured magnitude. Used for face selection, audio clip pick, flash opacity, LED brightness.

| Reaction | Intensity | Reaction | Intensity |
|---|---|---|---|
| `usbAttached` | 0.5 | `trackpadCircling` | 1.0 |
| `usbDetached` | 0.3 | `mouseClicked` | 0.50 |
| `acConnected` | 0.4 | `mouseScrolled` | 0.40 |
| `acDisconnected` | 0.7 | `keyboardTyped` | 0.35 |
| `audioPeripheralAttached` | 0.4 | `gyroSpike` | 0.7 |
| `audioPeripheralDetached` | 0.3 | `lidOpened` | 0.4 |
| `bluetoothConnected` | 0.4 | `lidClosed` | 0.3 |
| `bluetoothDisconnected` | 0.3 | `lidSlammed` | 0.95 |
| `thunderboltAttached` | 0.5 | `alsCovered` | 0.7 |
| `thunderboltDetached` | 0.3 | `lightsOff` | 0.5 |
| `displayConfigured` | 0.3 | `lightsOn` | 0.4 |
| `willSleep` | 0.2 | `thermalNominal` | 0.2 |
| `didWake` | 0.5 | `thermalFair` | 0.5 |
| `trackpadTouching` | 0.45 | `thermalSerious` | 0.8 |
| `trackpadSliding` | 0.65 | `thermalCritical` | 1.0 |
| `trackpadContact` | 0.40 | | |
| `trackpadTapping` | 0.55 | | |

## Reaction bus

| Setting | Value | What it does |
|---|---|---|
| Per-subscriber buffer depth | 8 | `bufferingNewest(8)`. Slow consumers drop oldest reactions rather than blocking publishers. |
| Enricher timeout | 500 ms | If the enricher (audio resolve + face select) takes longer than this the bus falls back to a default envelope and publishes anyway. |

## LED pulse

Used by `LEDFlash` (Caps Lock + keyboard backlight).

| Setting | Value | What it does |
|---|---|---|
| LED PWM frequency | 60 Hz | Caps Lock is binary; PWM-dither at 60 Hz against the shared `Envelope` so the user reads it as a brightness ramp. |
| Min pulse duration | 0.10 s | Floor on the audio-clip-derived envelope length. |
| Max pulse duration | 1.50 s | Ceiling on the envelope length. |
| Event response duration | 0.6 s | Default envelope length for non-impact reactions (which carry no clip duration). |

## Hardware constants (BMI286)

`AccelHardwareConstants` — read from the IOKit HID device descriptor. Not tunable.

| Field | Value | Why |
|---|---|---|
| HID usage page | `0xFF00` | Apple-vendor HID page. |
| HID usage | `3` | Accelerometer device. (Gyro = 9, lid = 8, ALS = 7.) |
| Required transport | `"SPU"` | Safety check — only the on-package Sensor Processing Unit qualifies. |
| Decimation factor | 2 | Hardware reports at 100 Hz; decimate to 50 Hz. |
| Magnitude min | 0.3 g | Sane lower bound for valid reads. |
| Magnitude max | 4.0 g | Sane upper bound. |
| Min report length | 18 bytes | Reject malformed HID reports. |
| Raw scale | 65 536 | Q15 fixed-point scaling factor in the report. |
| Default sample rate | 50 Hz | Post-decimation. |
| Sensor activity staleness | 500 ms | If `_last_event_timestamp` is older than this, the runtime probe declares the sensor cold. |

---

If you scrolled this far the joke is on both of us.
