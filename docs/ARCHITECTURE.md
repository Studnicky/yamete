# Architecture

Yamete is a macOS menu bar app that detects physical impacts on Apple Silicon MacBooks and responds with audio and visual feedback. Four SPM modules with a unidirectional dependency graph:

```
YameteCore  <──  SensorKit
                     │
YameteCore  <──  ResponseKit
                     │
YameteApp  ──>  SensorKit, ResponseKit, YameteCore
```

## Module responsibilities

| Module | Role | Key types |
|--------|------|-----------|
| **YameteCore** | Shared types, logging, signal processing | `Vec3`, `ImpactTier`, `SensorID`, `HighPassFilter`, `LowPassFilter`, `RingBuffer` |
| **SensorKit** | Sensor adapters, per-adapter detection, multi-sensor fusion | `SensorAdapter`, `SensorManager`, `ImpactDetector`, `ImpactFusionEngine` |
| **ResponseKit** | Audio playback, screen flash, device enumeration | `AudioPlayer`, `ScreenFlash`, `AudioDeviceManager` |
| **YameteApp** | App shell: controller, settings, UI | `ImpactController`, `SettingsStore`, `MenuBarView` |

## End-to-end data flow

The pipeline has three phases: **fan-out** (parallel sensor detection), **fan-in** (consensus fusion), and **fan-out** (parallel hardware response).

```mermaid
graph LR
    subgraph HW_IN["Hardware Input"]
        BMI["BMI286<br/>Accelerometer"]
        MIC["Microphone"]
        IMU["AirPods<br/>IMU"]
    end

    subgraph DETECT["Per-Adapter Detection"]
        A_DET["Accel<br/>ImpactDetector"]
        M_DET["Mic<br/>ImpactDetector"]
        H_DET["Headphone<br/>ImpactDetector"]
    end

    subgraph FUSE["Consensus"]
        FE["ImpactFusionEngine"]
    end

    subgraph CTRL["Controller"]
        IC["ImpactController"]
    end

    subgraph HW_OUT["Hardware Output"]
        SPK["Audio<br/>Devices"]
        DSP["Display<br/>Overlays"]
    end

    BMI --> A_DET
    MIC --> M_DET
    IMU --> H_DET

    A_DET -->|SensorImpact| FE
    M_DET -->|SensorImpact| FE
    H_DET -->|SensorImpact| FE

    FE -->|FusedImpact| IC

    IC -->|AudioPlayer| SPK
    IC -->|ScreenFlash| DSP
```

## Phase 1: Sensor fan-out

Each sensor adapter conforms to the `SensorAdapter` protocol and runs its own independent detection pipeline. Adapters are instantiated by `ImpactController.buildAdapters()` using current settings, then run concurrently inside `SensorManager` via a `TaskGroup`.

```mermaid
graph TD
    subgraph SM["SensorManager (TaskGroup)"]
        direction TB

        subgraph ACCEL["SPUAccelerometerAdapter"]
            direction TB
            IOKit["IOHIDManager<br/>input report callback"]
            RC["ReportContext<br/>parse raw bytes to Vec3"]
            HP["HighPassFilter<br/>20 Hz cutoff"]
            LP["LowPassFilter<br/>25 Hz cutoff"]
            DET_A["ImpactDetector<br/>6-gate pipeline"]

            IOKit --> RC --> HP --> LP --> DET_A
        end

        subgraph MICRO["MicrophoneAdapter"]
            direction TB
            AVE["AVAudioEngine<br/>installTap (48kHz)"]
            DC["DC-blocking<br/>HP filter"]
            PEAK["Per-buffer<br/>peak extraction"]
            DET_M["ImpactDetector<br/>6-gate pipeline"]

            AVE --> DC --> PEAK --> DET_M
        end

        subgraph HEADPHONE["HeadphoneMotionAdapter"]
            direction TB
            CMM["CMHeadphoneMotionManager<br/>userAcceleration"]
            MAG["Magnitude<br/>calculation"]
            DET_H["ImpactDetector<br/>6-gate pipeline"]

            CMM --> MAG --> DET_H
        end
    end

    DET_A -->|"SensorImpact<br/>(intensity 0-1)"| OUT["AsyncStream&lt;SensorEvent&gt;"]
    DET_M -->|"SensorImpact<br/>(intensity 0-1)"| OUT
    DET_H -->|"SensorImpact<br/>(intensity 0-1)"| OUT
```

### ImpactDetector gate pipeline

Every adapter feeds samples through the same `ImpactDetector` instance. All six gates must pass for a sample to produce a `SensorImpact`:

```mermaid
graph LR
    RAW["Filtered<br/>sample"] --> G1

    G1["1. Warmup<br/>skip first N samples"]
    G1 -->|pass| G2["2. Spike<br/>magnitude >= threshold"]
    G2 -->|pass| G3["3. Rise Rate<br/>consecutive increase >= min"]
    G3 -->|pass| G4["4. Crest Factor<br/>peak / RMS >= min"]
    G4 -->|pass| G5["5. Confirmations<br/>N hits in 120ms window"]
    G5 -->|pass| G6["6. Intensity Map<br/>clamp to floor..ceiling"]
    G6 --> SI["SensorImpact<br/>intensity 0-1"]

    G1 -->|fail| DROP["Discard"]
    G2 -->|fail| DROP
    G3 -->|fail| DROP
    G4 -->|fail| DROP
    G5 -->|fail| DROP
```

Background RMS is tracked with a slow exponential moving average (alpha = 0.02) so the crest factor gate adapts to ambient noise floor changes.

## Phase 2: Consensus fan-in

`ImpactFusionEngine` collects `SensorImpact` events from all active adapters and applies consensus + rearm gating before producing a `FusedImpact`.

```mermaid
sequenceDiagram
    participant A as Accelerometer
    participant M as Microphone
    participant FE as ImpactFusionEngine
    participant IC as ImpactController

    Note over FE: fusionWindow = 150ms<br/>consensusRequired = 2

    A->>FE: SensorImpact (0.72)
    Note over FE: Buffer: [accel:0.72]<br/>1 source, need 2

    M->>FE: SensorImpact (0.65)
    Note over FE: Buffer: [accel:0.72, mic:0.65]<br/>2 sources, consensus met

    FE->>FE: Prune impacts older than 150ms
    FE->>FE: Check rearm gate (time since last trigger)
    FE->>FE: Take strongest per source, average
    FE->>IC: FusedImpact (avg: 0.685, confidence: 66%)

    Note over FE: Set lastTriggerAt = now<br/>Rearm blocks next 500ms

    A->>FE: SensorImpact (0.40)
    Note over FE: Blocked by rearm cooldown
```

### FusedImpact fields

| Field | Description |
|-------|-------------|
| `timestamp` | Time of fusion decision |
| `avgIntensity` | Average of strongest impact per participating source |
| `confidence` | Fraction of active sources that participated |
| `sources` | Set of SensorIDs that contributed |

## Phase 3: Configuration

`SettingsStore` persists all user preferences to `UserDefaults` with clamped ranges. `ImpactController` uses `withObservationTracking` to react to any setting change and rebuild the pipeline.

```mermaid
graph TD
    subgraph UI["MenuBarView"]
        RS["Range Sliders<br/>Reactivity, Volume, Flash"]
        ADV["Advanced Panels<br/>Spike, Rise, Crest, etc."]
        DEV["Device Selectors<br/>Displays, Audio"]
    end

    subgraph SS["SettingsStore (@Observable)"]
        direction TB
        DET_S["Detection params<br/>spikeThreshold, riseRate<br/>crestFactor, confirmations<br/>bandpass, reportInterval"]
        FUSE_S["Fusion params<br/>consensusRequired<br/>debounce"]
        RESP_S["Response params<br/>sensitivityMin/Max<br/>volumeMin/Max<br/>flashOpacityMin/Max"]
        DEV_S["Device selection<br/>enabledSensorIDs<br/>enabledDisplays<br/>enabledAudioDevices"]
    end

    subgraph IC["ImpactController"]
        BUILD["buildAdapters()"]
        PUSH["pushFusionConfig()"]
        RESPOND["respond()"]
    end

    RS --> RESP_S
    ADV --> DET_S
    ADV --> FUSE_S
    DEV --> DEV_S

    DET_S -->|"withObservationTracking<br/>rebuild pipeline"| BUILD
    FUSE_S -->|"push on change"| PUSH
    DEV_S -->|"rebuild pipeline"| BUILD

    BUILD --> ADAPTERS["New SensorAdapter<br/>instances with<br/>baked-in config"]
    PUSH --> FUSION["FusionEngine<br/>.configure()"]
    RESP_S -->|"read at response time"| RESPOND
```

Settings that require a pipeline rebuild (bandpass frequencies, report interval, enabled sensors) trigger `stopPipeline()` + `startPipeline()`. Response parameters (volume, opacity, reactivity) are read at response time and take effect immediately.

## Phase 4: Response fan-out

When `ImpactController` receives a `FusedImpact`, it maps intensity through the user's reactivity window, then dispatches to audio and screen flash in parallel.

```mermaid
sequenceDiagram
    participant FE as FusionEngine
    participant IC as ImpactController
    participant AP as AudioPlayer
    participant SF as ScreenFlash

    FE->>IC: FusedImpact (intensity: 0.7)

    IC->>IC: Sensitivity mapping<br/>map 0.7 through reactivity window

    IC->>IC: Check rearm gate<br/>(time since last response)

    par Audio response
        IC->>AP: play(intensity, volumeMin, volumeMax, deviceUIDs)
        AP->>AP: Select clip by intensity<br/>(longer clips for harder hits)
        AP->>AP: Map volume: min + intensity * (max - min)
        loop Each enabled audio device
            AP->>AP: NSSound with playbackDeviceIdentifier
        end
        AP-->>IC: clipDuration
    and Visual response
        IC->>SF: flash(intensity, opacityMin, opacityMax, clipDuration, displayIDs)
        SF->>SF: Compute peak opacity<br/>min + intensity * (max - min)
        SF->>SF: Compute envelope<br/>(attack/hold/decay from intensity)
        SF->>SF: Pick face images<br/>(recency-weighted selection)
        loop Each enabled display
            SF->>SF: Create/reuse overlay NSWindow
            SF->>SF: Render FlashOverlayView<br/>(radial gradient + face)
        end
    end

    IC->>IC: Set rearmUntil = now + max(clipDuration, cooldown)
```

### Audio clip selection

`AudioPlayer` preloads all audio files from the bundle `sounds/` directory, sorted by duration (shortest first). Impact intensity selects a clip from the sorted list — lighter impacts play shorter clips, harder impacts play longer clips. A history of size 2 prevents immediate repeats.

### Screen flash rendering

`ScreenFlash` creates a borderless, transparent `NSWindow` overlay per monitor. The overlay renders a SwiftUI `FlashOverlayView` with:
- Radial gradient background (warm tones fading to transparent)
- Centered face image selected with recency-weighted scoring to avoid repetition
- Animated envelope: ease-in fade up, hold, ease-out fade down
- Duration gated to the audio clip length

## Bootstrap sequence

```mermaid
sequenceDiagram
    participant App as YameteApp
    participant AD as AppDelegate
    participant IC as ImpactController
    participant SM as SensorManager

    App->>AD: applicationDidFinishLaunching

    AD->>AD: Set activation policy .accessory<br/>(menu bar only, no Dock icon)

    AD->>AD: Migrate device defaults<br/>(first-launch setup)

    AD->>IC: bootstrap()

    IC->>IC: Set debugLogging from settings

    IC->>IC: syncPipelineState()<br/>(start if sound or flash enabled)

    IC->>IC: startSettingsObservation()<br/>(withObservationTracking loop)

    alt Pipeline should be active
        IC->>IC: buildAdapters(settings)
        IC->>SM: SensorManager(adapters)
        IC->>IC: Task: for await event in SM.events()
    end

    opt First launch
        AD->>AD: Play welcome sound
    end
```

## Module dependency graph

```mermaid
graph BT
    IOHIDPublic["IOHIDPublic<br/>(C bridging)"]
    Core["YameteCore<br/>Domain, Logging,<br/>SignalProcessing"]
    Sensor["SensorKit<br/>Adapters, Detector,<br/>FusionEngine"]
    Response["ResponseKit<br/>AudioPlayer,<br/>ScreenFlash"]
    App["YameteApp<br/>Controller, Settings,<br/>Views"]

    Sensor --> Core
    Sensor --> IOHIDPublic
    Response --> Core
    App --> Sensor
    App --> Response
    App --> Core
```

## Concurrency model

All stateful components are `@MainActor`-confined: `ImpactController`, `SensorManager`, `AudioPlayer`, `ScreenFlash`, `SettingsStore`. Sensor adapters run their I/O on background threads/queues but deliver `SensorImpact` events through `AsyncThrowingStream` continuations that are consumed on the main actor via `SensorManager.events()`.

| Pattern | Where | Purpose |
|---------|-------|---------|
| `AsyncThrowingStream` | Each `SensorAdapter.impacts()` | Stream per-adapter impact events |
| `AsyncStream` | `SensorManager.events()` | Unified event stream from all adapters |
| `TaskGroup` | Inside `SensorManager.events()` | Run adapters concurrently |
| `withObservationTracking` | `ImpactController` | React to settings changes |
| `@MainActor` | Controller, Manager, Responders | Thread confinement for shared state |
| `HIDRunLoopThread` | `AccelerometerReader` | Dedicated thread for IOKit callbacks |
| `OperationQueue` | `HeadphoneMotionAdapter` | CoreMotion delivery queue |
