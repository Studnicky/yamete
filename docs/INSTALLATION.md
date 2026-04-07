# Installation & Configuration

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon Mac (M1/M2/M3/M4) for accelerometer detection
- Any Mac for microphone-only detection
- AirPods Pro / Beats Fit Pro for headphone motion detection (optional)

## Install from DMG

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **Yamete.app** to `/Applications`.

On first launch:
1. macOS may prompt "Yamete is from an identified developer" — click **Open**
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
| `make build` | `dist/Yamete.app` | Debug build, ad-hoc signed |
| `make release` | `dist/Yamete.app` | Optimized, Developer ID signed |
| `make dmg` | `dist/Yamete.dmg` | Distributable disk image |
| `make install` | `/Applications/Yamete.app` | Build and install |
| `make test` | — | Run test suite (37 tests) |
| `make clean` | — | Remove build artifacts |

### SPM (for development)

```sh
swift build         # build all modules
swift test          # run tests
```

The `Package.swift` defines four modules: `YameteCore`, `SensorKit`, `ResponseKit`, `YameteApp`, plus the `IOHIDPublic` C bridging target.

## Entitlements

The app runs under App Sandbox with these entitlements:

| Entitlement | Purpose |
|-------------|---------|
| `com.apple.security.app-sandbox` | App Sandbox (required for distribution) |
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
- **Debug Logging** — Write verbose sensor data to `~/Library/Application Support/Yamete/logs/`
- **Impact counter** — Daily count and last impact tier + magnitude

## Troubleshooting

**No impacts detected (accelerometer)**
- Verify Apple Silicon Mac (Intel Macs lack the BMI286 sensor)
- Check that `com.apple.security.device.usb` entitlement is present
- Try lowering Spike Threshold and increasing Reactivity range
- Enable Debug Logging, reproduce the issue, check logs

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
- `~/Library/Application Support/Yamete/logs/` — auto-pruned after 24 hours
