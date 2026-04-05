# Yamete

A macOS menu bar app that detects physical impacts on Apple Silicon MacBooks and responds with audio and visual feedback.

Uses the built-in BMI286 accelerometer to detect impacts via high-pass filtered spike detection with multi-sensor consensus fusion.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon Mac (M1/M2/M3/M4) with built-in accelerometer
- Input Monitoring permission (prompted on first launch)

## Install

### From DMG

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **Yamete.app** to Applications.

### From source

```sh
git clone https://github.com/Studnicky/yamete.git
cd yamete
make install
```

### Build only

```sh
make build        # → dist/Yamete.app
make dmg          # → dist/Yamete.dmg
make test         # run test suite
```

### Uninstall

```sh
make uninstall
```

## Configuration

All settings are accessible from the menu bar dropdown. Every output parameter is a range slider driven by the normalized impact intensity — a single impact flows through all four windows simultaneously.

```
raw force → [sensitivity] → intensity 0–1 → [volume]   → audio level
                                           → [opacity]  → flash brightness
                                           → [debounce] → cooldown time
```

### Sensitivity (range: 0–100%)

Higher = more reactive. The sensitivity values are inverted to force thresholds internally, so dragging the sliders right makes the app respond to lighter impacts.

- **Low thumb**: minimum sensitivity. Default 10% (inverts to 90% force threshold — only the strongest impacts produce any response at this level).
- **High thumb**: maximum sensitivity. Default 90% (inverts to 10% force threshold — very light taps produce full-intensity response at this level).
- **Band width effect**: a narrow band (e.g., 80–90%) creates steep, dramatic response within a small sensitivity range. A wide band (e.g., 10–90%) creates gradual, proportional response.

### Volume (range: 0–100%)

Audio playback level window. The normalized intensity maps linearly between the two thumbs.

- **Low thumb**: volume for the lightest detectable impact. Default 20%.
- **High thumb**: volume for the hardest impact. Default 100%.
- Clip selection also scales with intensity — lighter impacts play shorter clips, harder impacts play longer ones.

### Flash Opacity (range: 0–100%)

Screen flash brightness window. Each impact triggers a full-screen radial vignette (bright center, deep pink corners) with a random face overlay centered on each connected monitor.

- **Low thumb**: opacity for the lightest impact. Default 10%.
- **High thumb**: opacity for the hardest impact. Default 65%.
- The flash envelope (attack/sustain/decay) is gated inside the sound clip duration and shaped by intensity: hard impacts have fast attack and long sustain; light impacts have gentle attack and quick decay.

### Debounce (range: 0.0–3.0s)

Minimum seconds between reactions. The actual cooldown is the greater of the debounce value and the playing clip's duration.

### Other controls

- **Enable/Disable toggle**: starts or stops the accelerometer and detection pipeline.
- **Launch at Login**: register with macOS to start automatically on login.
- **Impact counter**: daily count, resets at midnight (matches 24-hour log retention).

## How it works

```
Accelerometer (100Hz BMI286 via IOKit HID)
    → Decimation (÷2 → 50Hz)
    → Sensor fusion (per-source high-pass filter + rolling-window consensus)
    → Sensitivity band gates and normalizes intensity
    → Intensity flows through volume, opacity, debounce windows
    → Audio clip selected by duration (shortest → lightest, longest → hardest)
    → Screen flash envelope computed to fit inside clip duration
    → Radial vignette + face overlay shown on selected monitors
```

## Project structure

```
Sources/
├── YameteApp.swift           App entry point, menu bar setup
├── Domain.swift              Vec3, clamping, bundle resource discovery
├── Logging.swift             Dual-sink logger (os.Logger + file, 24h retention)
├── SignalProcessing.swift    RingBuffer, HighPassFilter
├── SensorAdapter.swift       Sensor protocol, SensorManager, fan-in stream
├── SensorFusion.swift        Rolling-window multi-source spike consensus
├── AccelerometerReader.swift BMI286 via IOHIDManager (SPU transport)
├── AudioDevice.swift         CoreAudio output device enumeration
├── AudioPlayer.swift         Sound playback, duration-sorted clip selection
├── ScreenFlash.swift         Per-monitor radial vignette overlay
├── SettingsStore.swift       UserDefaults persistence, range validation
├── ImpactController.swift    Main coordinator, fusion → response pipeline
└── Views/
    ├── MenuBarView.swift     Settings dropdown panel
    ├── MenuBarIcon.swift     Menu bar icon
    ├── SliderRow.swift       Single-value slider component
    ├── Theme.swift           Shared color palette
    └── RangeSlider.swift     Dual-thumb range slider component

Bundle/Contents/Resources/
├── faces/                    Face images (any SVG/PNG/JPG)
└── sounds/                   Sound clips (any MP3/WAV/M4A)

Tests/                        Tabular tests (unit, integration, E2E)
```

## License

MIT License — see [LICENSE](LICENSE) for details.
