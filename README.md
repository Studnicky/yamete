# Yamete

A macOS menu bar app that detects physical impacts on Apple Silicon MacBooks and responds with audio and visual feedback.

Uses the built-in BMI286 accelerometer via the IOHIDEventSystemClient API (macOS 15+) with a multi-gate impact detection pipeline calibrated to reject ambient vibrations while responding to direct desk impacts.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon Mac (M1/M2/M3/M4) with built-in accelerometer

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
make build        # dist/Yamete.app
make dmg          # dist/Yamete.dmg
make test         # run test suite
```

## How it works

```
Sensor Adapters (each runs its own detection pipeline):
    SPU Accelerometer (private API activation + public IOHIDManager reading)
        100Hz raw → 2:1 decimation → bandpass (HP 20Hz + LP 25Hz)
        → spike/rise/crest/confirmations gates → SensorImpact (0-1 intensity)
    HID Accelerometer (public API only, requires external activation)
        Same pipeline, IOHIDDeviceSetProperty activation attempt
    Microphone (AVAudioEngine, public API, works on all Macs)
        48kHz audio → per-buffer peak → DC-blocking HP filter
        → spike/rise/crest/confirmations gates → SensorImpact (0-1 intensity)
    Headphone Motion (CoreMotion, AirPods/Beats IMU)
        userAcceleration magnitude → gates → SensorImpact (0-1 intensity)

Impact Fusion Engine:
    Collects SensorImpact events within a time window
    Consensus: N sensors must independently detect (user-configurable, 1-5)
    Rearm: cooldown between responses (user-configurable)
    Fused intensity: average across participating sensors

Response:
    Reactivity band maps fused intensity to 0-1 response intensity
    Intensity drives audio clip selection, volume, flash opacity, and envelope
    Impact tier classification (Tap / Light / Medium / Firm / Hard)
```

## Configuration

All settings are in the menu bar dropdown. Main controls use range sliders where the two thumbs define a response window. Each setting has an icon with tappable inline help.

### Main Controls

- **Reactivity** (0-100%): Impact force response window. Higher = responds to lighter impacts. The five tiers (Hard/Firm/Med/Light/Tap) are marked on the ruler.
- **Volume** (0-100%): Audio playback level window. Intensity maps linearly between low and high thumbs.
- **Flash Opacity** (0-100%): Screen flash brightness window. Envelope (attack/hold/decay) shaped by intensity.

### Collapsible Panels

- **Device Settings**: Select which displays show the flash overlay and which audio devices play sounds.
- **Sensitivity Settings**: Advanced detection tuning — frequency band, cooldown, spike threshold, rise rate, confirmations, warmup. Each has a tappable help icon.

### Footer

- **Pause / Resume**: Stop/start the detection pipeline.
- **Launch at Login**: Register with macOS for auto-start.
- **Impact counter**: Shows daily count and last impact tier + magnitude.

## Distribution

Yamete runs under App Sandbox with the `device.usb` entitlement for accelerometer access via the public IOHIDManager API. Sensor activation uses IOHIDServiceClient property bindings (`@_silgen_name`) to set the SPU report interval — report reading is fully public API.

## Project structure

Four SPM modules with a clean dependency graph: `YameteCore <- SensorKit, ResponseKit <- YameteApp`.

```
Sources/
  YameteCore/                 Shared types, logging, signal processing
    Domain.swift              Vec3, ImpactTier, SensorID, protocols
    Logging.swift             Dual-sink logger (os.Logger + file, 24h retention)
    SignalProcessing.swift    RingBuffer, HighPassFilter, LowPassFilter

  SensorKit/                  Sensor adapters, per-adapter detection, fusion
    SensorAdapter.swift       SensorAdapter protocol, SensorImpact, SensorManager
    ImpactDetector.swift      Per-adapter gate pipeline (spike, rise, crest, confirmations)
    ImpactDetection.swift     ImpactFusionEngine (consensus, rearm, response dispatch)
    AccelerometerReader.swift HID + SPU accelerometer adapters (BMI286 via IOHIDManager)
    MicrophoneAdapter.swift   Audio transient detection (AVAudioEngine)
    HeadphoneMotionAdapter.swift AirPods/Beats IMU (CoreMotion)

  ResponseKit/                Audio playback, device enumeration, screen flash
    AudioDevice.swift         CoreAudio output device enumeration
    AudioPlayer.swift         Sound playback, duration-sorted clip selection
    ScreenFlash.swift         Per-monitor radial vignette overlay

  YameteApp/                  App layer: controller, settings, views
    YameteApp.swift           App entry point, menu bar setup
    ImpactController.swift    Coordinator: detect() -> respond() pipeline
    SettingsStore.swift       UserDefaults persistence, range validation
    Updater.swift             App version display
    Views/
      MenuBarView.swift       Settings dropdown with accordion panels
      MenuBarIcon.swift       Menu bar icon
      Theme.swift             Color palette, AccordionCard, SettingHeader
      RangeSlider.swift       Dual-thumb range slider component

Bundle/Contents/Resources/
  faces/                      Face images (any SVG/PNG/JPG, loaded recursively)
  sounds/                     Sound clips (any MP3/WAV/M4A, sorted by duration at startup)

Tests/                        41 tests (unit, integration, E2E)
```

## Privacy

See [PRIVACY.md](PRIVACY.md). No data leaves your Mac. Logs auto-delete after 24 hours.

## License

MIT License — see [LICENSE](LICENSE) for details.
