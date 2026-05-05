---
title: Source map
description: Every Swift file in the project, one line each. The cheat sheet.
---

# Source map

*Reference. One line per file across the four SPM targets plus the host app. Updated by hand at release time.*

| File | Module | Role |
|---|---|---|
| ReactionBus.swift | YameteCore | Actor: multi-subscriber fan-out, pre-fan-out enricher, 500 ms timeout fallback |
| Reaction.swift | YameteCore | Reaction enum (impact + 31 event cases), ReactionKind, FusedImpact, sensitivity gate math |
| FiredReaction.swift | YameteCore | Enriched reaction: soundURL, clipDuration, faceIndices, publishedAt |
| ReactionsConfig.swift | YameteCore | Per-event synthesized intensities, debounce windows, bus buffer depth, LED PWM constants |
| Constants.swift | YameteCore | Detection parameter ranges, hardware constants |
| Defaults.swift | YameteCore | Factory default values for all thresholds and timing |
| Domain.swift | YameteCore | Vec3, SensorID, ImpactTier enum, OnceCleanup, responder protocols |
| Envelope.swift | YameteCore | Shared LED/flash animation envelope: attack, hold, decay timing from clipDuration + intensity |
| SignalProcessing.swift | YameteCore | HighPassFilter, LowPassFilter (first-order IIR, 3-axis) |
| Logging.swift | YameteCore | AppLog dual-sink (os.Logger + file), 24-hour retention |
| VisualResponseMode.swift | YameteCore | VisualResponseMode enum (off / overlay / notification) for legacy compat |
| SensorAdapter.swift | SensorKit | SensorSource and EventSource protocols, SensorImpact, SensorError |
| ImpactDetection.swift | SensorKit | ImpactFusion: fan-in, consensus gate, rearm, sensitivity gate, publishes Reaction.impact |
| ImpactDetector.swift | SensorKit | Per-sensor 6-gate pipeline: warmup, spike, rise, crest, confirm, intensity |
| AccelerometerReader.swift | SensorKit | BMI286 HID reader, bandpass filters, ImpactDetector, watchdog |
| MicrophoneAdapter.swift | SensorKit | AVAudioEngine tap, DC-block filter, ImpactDetector |
| HeadphoneMotionAdapter.swift | SensorKit | CMHeadphoneMotionManager, connection probe, ImpactDetector |
| EventSources.swift | SensorKit | Original infrastructure EventSource implementations: USBSource, PowerSource, AudioPeripheralSource, BluetoothSource, ThunderboltSource, DisplayHotplugSource, SleepWakeSource |
| AudioPlayer.swift | ResponseKit | Sound pool, intensity-based clip selection (peekSound), NSSound multi-device playback |
| ScreenFlash.swift | ResponseKit | Borderless overlay windows, window pool, per-screen face rendering, animated envelope |
| LEDFlash.swift | ResponseKit | Caps Lock LED PWM (IOKit HID), keyboard brightness spring oscillation (CoreBrightness), crash-recovery sentinel |
| NotificationResponder.swift | ResponseKit | UNUserNotificationCenter, tier phrases, 40-locale resolution |
| FaceLibrary.swift | ResponseKit | Shared singleton face image cache, selectIndices() dedup scoring for enricher |
| FaceRenderer.swift | ResponseKit | SVG template loader, placeholder resolution, light/dark palette |
| AudioDevice.swift | ResponseKit | Core Audio device enumeration, UID resolution, change notifications |
| OutputConfig.swift | ResponseKit | AudioOutputConfig, FlashOutputConfig, LEDOutputConfig, NotificationOutputConfig, OutputConfigProvider protocol |
| Yamete.swift | YameteApp | Orchestrator: owns bus, all sources, all outputs, lifecycle wiring, settings observation |
| SettingsStore.swift | YameteApp | @Observable UserDefaults persistence, all detection/response params, validation, OutputConfigProvider |
| MenuBarFace.swift | YameteApp | Bus subscriber: impact-only face swap in NSStatusItem, daily impact counter |
| StatusBarController.swift | YameteApp | NSStatusItem ownership, menu bar icon and popover management |
| EventSettings.swift | YameteApp | EventSourceDefaults, ReactionToggleMatrix for per-output per-reaction toggle persistence |
| AppleSPUDevice.swift | SensorKit | Ref-counted broker for the Apple Silicon SPU HID handle: accel, gyro, lid, ALS share one open device, decode their own bytes from the same input report, three-phase teardown when the last subscriber releases |
| GyroscopeSource.swift | SensorKit | SPU HID usage 9 subscriber, GyroDetector pipeline, deg/s magnitude |
| GyroDetector.swift | SensorKit | Six-gate consensus pipeline tuned for gyroscope rotational spikes |
| LidAngleSource.swift | SensorKit | SPU HID usage 8 subscriber, hinge angle stream → state machine |
| LidAngleStateMachine.swift | SensorKit | closed/opening/open/closing transitions, slam-rate gate, EMA-smoothed Δangle/Δt |
| AmbientLightSource.swift | SensorKit | SPU HID usage 7 subscriber, two-second ring buffer + step detector |
| AmbientLightDetector.swift | SensorKit | Step gates (lights flipped, sensor covered) with separate percent + floor/ceiling thresholds |
| ThermalSource.swift | SensorKit | NSProcessInfo.thermalStateDidChangeNotification observer, cold-start suppressed, per-state dedup |
| KeyboardActivitySource.swift | SensorKit | CGEvent tap (key-press rate threshold), MockEventMonitor in tests |
| MouseActivitySource.swift | SensorKit | CGEvent tap (mouse-down + scroll-wheel), TCC-aware, RealEventMonitor seam |
| TrackpadActivitySource.swift | SensorKit | NSEvent monitor + IOKit HID multitouch listener for circling/contact/sliding/tapping |
| HIDDeviceMonitor.swift | SensorKit | Real/Mock seam for IOHIDManager device queries — used by KeyboardActivitySource and others |
| EventMonitor.swift | SensorKit | Real/Mock seam for CGEvent tap subscription |
| MicrophoneEngineDriver.swift | SensorKit | Real/Mock seam for AVAudioEngine — keeps MicrophoneAdapter testable without spinning up a real engine |
| HeadphoneMotionDriver.swift | SensorKit | Real/Mock seam for CMHeadphoneMotionManager |
| AudioPlaybackDriver.swift | ResponseKit | Real/Mock seam for NSSound playback |
| SystemVolumeDriver.swift | ResponseKit | Volume read/write via Core Audio |
| VolumeSpikeResponder.swift | ResponseKit | Volume-spike output: bumps system volume on impact via SystemVolumeDriver |
| HapticEngineDriver.swift | ResponseKit | Real/Mock seam for CoreHaptics (CHHapticEngine + transient pattern) |
| HapticResponder.swift | ResponseKit | Trackpad haptic feedback subscriber wired through HapticEngineDriver |
| LEDBrightnessDriver.swift | ResponseKit | Real/Mock seam for IOKit Caps Lock LED |
| DisplayBrightnessDriver.swift | ResponseKit | Real/Mock seam for CoreBrightness keyboard/display brightness |
| DisplayBrightnessFlash.swift | ResponseKit | Display-backlight pulse output (spring envelope) |
| DisplayTintDriver.swift | ResponseKit | Real/Mock seam for display tint via CoreGraphics gamma table |
| DisplayTintFlash.swift | ResponseKit | Display-tint pulse output (gradient overlay via tint table) |
| ReactiveOutput.swift | ResponseKit | Output protocol the bus dispatches against — every responder conforms |
| SystemNotificationDriver.swift | ResponseKit | Real/Mock seam for UNUserNotificationCenter |
| Updater.swift | YameteApp | GitHub releases version check, update prompt (Direct build only) |

*Test surface details have moved to [Testing.](/testing)*
