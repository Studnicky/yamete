# Yamete

A macOS menu bar app that detects physical impacts on Apple Silicon MacBooks and responds with audio and visual feedback.

Uses the built-in BMI286 accelerometer to detect impacts using four independent signal processing algorithms (STA/LTA, CUSUM, Kurtosis, PeakMAD) that vote on whether an impact occurred.

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

Defines which impact forces register and maps them to a normalized 0–1 intensity.

- **Low thumb (noise floor)**: impacts below this are ignored. Default 10%. Typing registers at ~3–5%, so 10% filters it out while catching light taps at ~15%+.
- **High thumb (saturation ceiling)**: impacts at or above this produce full-intensity response. Default 70%.
- **Band width effect**: a narrow band (e.g., 40–50%) creates steep, dramatic response to small force differences. A wide band (e.g., 5–90%) creates gradual, proportional response.

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

### Debounce (range: 0.0–1.5s)

Cooldown window — how long to wait before responding to the next impact. Scales with intensity so light taps recover quickly and hard impacts have longer cooldown.

- **Low thumb**: cooldown after the lightest impact. Default 0.1s.
- **High thumb**: cooldown after the hardest impact. Default 0.5s.
- The actual cooldown is the greater of the debounce value and the playing clip's duration.

### Other controls

- **Enable/Disable toggle**: starts or stops the accelerometer and detection pipeline.
- **Launch at Login**: register with macOS to start automatically on login.
- **Impact counter**: daily count, resets at midnight (matches 24-hour log retention).

## How it works

```
Accelerometer (100Hz BMI286 via IOKit HID)
    → Decimation (÷2 → 50Hz)
    → High-pass filter (5Hz cutoff, removes gravity)
    → 4 signal detectors vote (need 2+ to trigger)
    → Sensitivity band gates and normalizes intensity
    → Intensity flows through volume, opacity, debounce windows
    → Audio clip selected and played (14 clips, scaled by intensity)
    → Screen flash envelope computed to fit inside clip duration
    → Radial vignette + face overlay shown on all monitors
```

## Project structure

```
Sources/
├── YameteApp.swift           App entry point, menu bar setup
├── Domain.swift              Vec3, ImpactEvent, Transferred, clamping
├── Logging.swift             Dual-sink logger (os.Logger + file, 24h retention)
├── SignalProcessing.swift    RingBuffer, HighPassFilter
├── SignalDetectors.swift     STA/LTA, CUSUM, Kurtosis, PeakMAD detectors
├── ImpactDetector.swift      Detector orchestrator, threshold tuning
├── AccelerometerReader.swift BMI286 via IOHIDManager (SPU transport)
├── AudioPlayer.swift         Sound playback, intensity-based clip selection
├── ScreenFlash.swift         Per-monitor radial vignette overlay
├── SettingsStore.swift       UserDefaults persistence, range validation
├── ImpactController.swift    Main coordinator, sliding window pipeline
└── Views/
    ├── MenuBarView.swift     Settings dropdown panel
    ├── MenuBarIcon.swift     Menu bar icon
    ├── SliderRow.swift       Single-value slider component
    └── RangeSlider.swift     Dual-thumb range slider component

Tests/                        30 tabular tests (unit, integration, E2E)
Resources/                    13 face SVGs (uniform 5-color palette) + 14 sound clips
```

## License

MIT License — see [LICENSE](LICENSE) for details.
