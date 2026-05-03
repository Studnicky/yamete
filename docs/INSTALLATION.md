# Installation & Configuration

## Requirements

- macOS 14.0+ (Sonoma)
- Built with Swift 6 (complete strict concurrency)
- Latest release: 2.0.0

### Sensor compatibility by Mac model

| Sensor | MacBook Air/Pro (Apple Silicon) | iMac, Mac Mini, Studio, Pro | Intel Macs |
|--------|------|------|------|
| Accelerometer (BMI286) | Yes | No | No |
| Microphone | Yes | Yes | Yes |
| Headphone Motion | Yes (with compatible headphones) | Yes (with compatible headphones) | Yes (with compatible headphones) |

Compatible headphones for motion detection: AirPods Pro, AirPods Max, AirPods (3rd gen+), Beats Fit Pro.

## Install from DMG

Download the latest direct-distribution `.dmg` from [Releases](../../releases), open it, and drag **Yamete Direct.app** to `/Applications`.

On first launch:
1. macOS may prompt "Yamete Direct is from an identified developer" — click **Open**
2. The app appears in the menu bar (no Dock icon)
3. Grant microphone permission when prompted (optional — accelerometer works without it)

## Build from source

```sh
git clone https://github.com/Studnicky/yamete.git
cd yamete
make install        # builds and copies to /Applications
```

### Build targets

| Command | Output | Purpose |
|---------|--------|---------|
| `make build` | `dist/Yamete Direct.app` | Debug direct build, ad-hoc signed |
| `make release` | `dist/Yamete Direct.app` | Optimized direct build, Developer ID signed |
| `make dmg` | `dist/Yamete Direct.dmg` | Direct-download disk image |
| `make install` | `/Applications/Yamete Direct.app` | Build and install the direct product |
| `make test` | — | Run the full test suite (unit, integration, E2E) |
| `make clean` | — | Remove build artifacts |

### App Store archive

Use the generated Xcode project for the Mac App Store build:

```sh
xcodegen generate
xcodebuild -project Yamete.xcodeproj -scheme Yamete-AppStore -configuration ReleaseAppStore archive
```

### SPM (for development)

```sh
swift build         # build all modules
swift test          # run tests
```

The `Package.swift` defines four modules: `YameteCore`, `SensorKit`, `ResponseKit`, `YameteApp`, plus the `IOHIDPublic` C bridging target.

## Entitlements

The repo ships two products with different runtime models:

| Product | Bundle ID | Runtime model |
|---------|-----------|---------------|
| `Yamete` | `com.studnicky.yamete` | Mac App Store build, App Sandbox enabled |
| `Yamete Direct` | `com.studnicky.yamete.direct` | Direct-download build, unsandboxed |

App Store entitlements:

| Entitlement | Purpose |
|-------------|---------|
| `com.apple.security.app-sandbox` | App Sandbox for Mac App Store distribution |
| `com.apple.security.device.usb` | IOHIDManager access to built-in accelerometer |
| `com.apple.security.device.audio-input` | Microphone access for audio transient detection |

## Configuration

All settings live in the menu bar dropdown. No config files. Settings persist in UserDefaults.

### Main controls

Each main control is a **range slider** with two thumbs defining a response window. Impact intensity maps linearly between the low and high thumbs.

**Reactivity** — Impact force response window. The low thumb sets the weakest force that triggers a response. The high thumb sets the force for maximum response. Higher values respond to lighter impacts. Five tiers (Tap / Light / Med / Firm / Hard) are marked on the ruler.

**Volume** — Audio playback level window. Impact intensity maps linearly between the low and high thumb values. Clip selection also follows intensity — lighter impacts play shorter clips.

**Flash Opacity** — Screen flash brightness window. The flash envelope (attack/hold/decay timing) is shaped by impact intensity and gated inside the sound clip duration.

### Sensitivity & Sensors panel

Expand the **Sensitivity & Sensors** accordion for advanced tuning:

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| Sensor Consensus | 1–5 | 1 | Sensors that must independently detect before triggering. Clamped to active sensor count. |
| Cooldown | 0–2s | 0s | Minimum time between reactions. 0 = gated only by playing clip duration. |

### Accelerometer Tuning panel

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| Frequency Band | 10–25 Hz | 20–25 Hz | Bandpass filter. Low = high-pass (rejects floor vibrations). High = low-pass (rejects electronic noise). |
| Spike Threshold | 0.01–0.04g | 0.02g | Minimum filtered magnitude to consider as impact. |
| Crest Factor | 1.0–10.0x | 3.0x | Peak must exceed background RMS by this multiple. Rejects ambient vibration. |
| Rise Rate | 0.0–0.05g | 0.005g | Minimum magnitude increase between consecutive samples. Rejects gradual vibrations. |
| Confirmations | 1–5 | 3 | Above-threshold samples required in 120ms window. |
| Warmup | 10–100 | 50 | Samples before detection activates (filter settling time). |
| Report Interval | 5–50ms | 10ms | Accelerometer polling interval. 10ms = 100 Hz. |

### Devices panel

- **Flash Displays** — Select which monitors show the flash overlay. None selected = all monitors.
- **Audio Output** — Select which audio devices play impact sounds. None selected = no audio.

### Footer controls

- **Pause / Resume** — Stop/start the detection pipeline
- **Launch at Login** — Register with macOS for auto-start via ServiceManagement
- **Debug Logging** — Direct builds only. Writes verbose sensor data to the direct app's log directory
- **Impact counter** — Daily count and last impact tier + magnitude

## Troubleshooting

**No impacts detected (accelerometer)**
- Verify Apple Silicon Mac (Intel Macs lack the BMI286 sensor)
- Check that `com.apple.security.device.usb` entitlement is present
- Try lowering Spike Threshold and increasing Reactivity range
- In `Yamete Direct`, enable Debug Logging, reproduce the issue, then check the direct-build logs

**No impacts detected (microphone)**
- Grant microphone permission in System Settings > Privacy & Security > Microphone
- Verify an audio input device is connected
- Microphone detection requires audible desk impact sounds

**Sensor consensus blocks detection**
- If consensus is set to 2+ but only one sensor is active, detection never triggers
- Lower consensus to 1, or ensure multiple sensors are delivering data

**Settings seem to have no effect**
- Changes to Report Interval, Frequency Band, and Warmup require a pipeline restart (toggle Pause/Resume)
- Other settings apply immediately via observation tracking

**Logs location**
- Direct download builds: `~/Library/Application Support/Yamete Direct/logs/`
- Mac App Store builds: `~/Library/Containers/com.studnicky.yamete/Data/Library/Application Support/Yamete/logs/`
