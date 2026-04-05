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
BMI286 Accelerometer (100Hz via IOHIDEventSystemClient)
    Decimation (2:1 to 50Hz)
    Bandpass filter (HP 20Hz + LP 25Hz: rejects floor vibrations + electronic noise)
    5-gate detection pipeline:
      1. Spike threshold (0.020g minimum filtered magnitude)
      2. Rise rate (peak onset speed within window rejects transmitted vibrations)
      3. Confirmation count (3+ above-threshold samples in 120ms window)
      4. Time-based rearm (0.5s cooldown prevents filter ringing retrigger)
      5. Warmup gate (50 samples for filter settling after start)
    Impact tier classification (Tap / Light / Medium / Firm / Hard)
    Reactivity band maps magnitude to 0-1 intensity
    Intensity drives audio clip selection, volume, flash opacity, and envelope
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
- **Auto-Update**: Daily check for new releases on GitHub.
- **Impact counter**: Shows daily count and last impact tier + magnitude.

## Distribution

Yamete is distributed as a **notarized DMG** (direct distribution). The app uses private IOHIDEventSystemClient APIs for accelerometer access, which are not available under App Sandbox. App Store distribution is not possible.

Self-updates are verified with SHA256 checksum + codesign + bundle ID + team ID before installation.

## Project structure

```
Sources/
  YameteApp.swift             App entry point, menu bar setup
  Domain.swift                Vec3, ImpactTier, SensorID, AudioDeviceUID, protocols
  Logging.swift               Dual-sink logger (os.Logger + file, 24h retention)
  SignalProcessing.swift      RingBuffer, HighPassFilter, LowPassFilter
  SensorAdapter.swift         SensorAdapter protocol, SensorManager, SensorEvent
  ImpactDetection.swift       DetectionConfig, ImpactDetectionEngine (5-gate pipeline)
  AccelerometerReader.swift   BMI286 via IOHIDEventSystemClient (SPU transport)
  AudioDevice.swift           CoreAudio output device enumeration
  AudioPlayer.swift           Sound playback, duration-sorted clip selection
  ScreenFlash.swift           Per-monitor radial vignette overlay
  SettingsStore.swift         UserDefaults persistence, range validation
  ImpactController.swift      Coordinator: detect() -> respond() pipeline
  Updater.swift               GitHub release checker, DMG installer, relaunch
  Views/
    MenuBarView.swift         Settings dropdown with accordion panels
    MenuBarIcon.swift         Menu bar icon
    SliderRow.swift           Single-value slider component
    Theme.swift               Color palette, AccordionCard, SettingHeader
    RangeSlider.swift         Dual-thumb range slider component

Bundle/Contents/Resources/
  faces/                      Face images (any SVG/PNG/JPG, loaded recursively)
  sounds/                     Sound clips (any MP3/WAV/M4A, sorted by duration at startup)

Tests/                        38 tests (unit, integration, E2E)
```

## Privacy

See [PRIVACY.md](PRIVACY.md). No data leaves your Mac. Logs auto-delete after 24 hours.

## License

MIT License — see [LICENSE](LICENSE) for details.
