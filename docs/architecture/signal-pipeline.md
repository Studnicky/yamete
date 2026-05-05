---
title: Signal pipeline
description: Sensor or event to output, end to end. The shape of the bus.
---

# Signal pipeline

*Two emission patterns feed one bus. Continuous-stream sources (accelerometer, microphone, gyroscope, ambient light) run their own detection pipeline over a high-frequency sample stream and emit one `Reaction` when the pipeline crosses threshold. Discrete state-transition sources (USB, power, audio, Bluetooth, Thunderbolt, display, sleep/wake, lid angle, thermal) observe an OS notification or KVO surface and emit one `Reaction` per user-meaningful state change. Same bus, same envelope, same fan-out.*

Two categories of source publish onto the `ReactionBus`. Impact sources run three parallel sensor streams through `ImpactFusion`, which applies consensus and rearm gating before publishing `Reaction.impact`. Infrastructure event sources (USB, power, Bluetooth, etc.) publish discrete `Reaction` cases directly. The bus runs a pre-fan-out enricher that resolves audio clip URL, clip duration, and face indices exactly once per reaction. Four independent outputs each subscribe to the bus via `bus.subscribe()`, receiving an `AsyncStream<FiredReaction>`, and pattern-match the reaction kinds their per-output toggle matrix enables.

        
          End-to-end signal flow
          
```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "primaryColor": "#141414",
    "primaryTextColor": "#e8e8e8",
    "primaryBorderColor": "#ff6b8a",
    "lineColor": "#ff6b8a",
    "secondaryColor": "#141414",
    "tertiaryColor": "#0a0a0a",
    "edgeLabelBackground": "#0a0a0a",
    "clusterBkg": "#1a1a1a",
    "clusterBorder": "#ff6b8a",
    "titleColor": "#ffb3c4",
    "nodeTextColor": "#e8e8e8",
    "fontFamily": "SF Mono, ui-monospace, Menlo, monospace"
  }
}}%%
flowchart LR
  subgraph IMPACT["IMPACT SENSORS  (SensorSource, parallel AsyncThrowingStream)"]
    direction LR
    ACC["AccelerometerSource
BMI286 via IOKit HID
bandpass 20-25 Hz
ImpactDetector (6 gates)"]:::sensor
    MIC["MicrophoneSource
AVAudioEngine tap
DC-block filter
ImpactDetector (6 gates)"]:::sensor
    HP["HeadphoneMotionSource
CMHeadphoneMotionManager
userAcceleration magnitude
ImpactDetector (6 gates)"]:::sensor
  end

  subgraph EVENTS["INFRASTRUCTURE & STATE SOURCES  (EventSource, each publishes directly to bus)"]
    direction LR
    USB["USBSource"]:::evtsrc
    PWR["PowerSource"]:::evtsrc
    AUD["AudioPeripheralSource"]:::evtsrc
    BT["BluetoothSource"]:::evtsrc
    TB["ThunderboltSource"]:::evtsrc
    DSP["DisplayHotplugSource"]:::evtsrc
    SW["SleepWakeSource"]:::evtsrc
    GYR["GyroscopeSource
SPU HID usage 9
GyroDetector (6 gates)"]:::evtsrc
    LID["LidAngleSource
SPU HID usage 8
state machine + slam gate"]:::evtsrc
    ALS["AmbientLightSource
SPU HID usage 7
step detector + cover gate"]:::evtsrc
    THR["ThermalSource
NSProcessInfo state-change KVO
cold-start suppressed"]:::evtsrc
    KBD["KeyboardActivitySource"]:::evtsrc
    MSE["MouseActivitySource"]:::evtsrc
    TPD["TrackpadActivitySource"]:::evtsrc
  end

  FUSION["ImpactFusion
fan-in task group
consensus + rearm gate
sensitivity remapping
→ Reaction.impact"]:::fusion

  BUS["ReactionBus (actor)
pre-fan-out enricher:
resolve audio clip URL + duration
FaceLibrary.selectIndices(count:)
stamp publishedAt
→ FiredReaction"]:::bus

  subgraph OUTPUTS["OUTPUTS  (each independently subscribes, pattern-matches ReactionKind)"]
    direction LR
    AP["AudioPlayer
plays pre-selected clip
on enabled Core Audio devices"]:::resp
    SF["ScreenFlash
borderless NSWindow overlays
per-screen face + radial gradient"]:::resp
    LED["LEDFlash
Caps Lock LED PWM
keyboard brightness spring oscillation"]:::resp
    NR["NotificationResponder
UNUserNotificationCenter
tier-phrase, 40 locales"]:::resp
  end

  MBF["MenuBarFace
subscribes to bus
impact-only face swap
NSStatusItem icon"]:::menubar

  ACC -->|"SensorImpact"| FUSION
  MIC -->|"SensorImpact"| FUSION
  HP  -->|"SensorImpact"| FUSION

  FUSION -->|"Reaction.impact"| BUS
  USB -->|"Reaction.usb*"| BUS
  PWR -->|"Reaction.ac*"| BUS
  AUD -->|"Reaction.audioPeripheral*"| BUS
  BT  -->|"Reaction.bluetooth*"| BUS
  TB  -->|"Reaction.thunderbolt*"| BUS
  DSP -->|"Reaction.displayConfigured"| BUS
  SW  -->|"Reaction.willSleep / .didWake"| BUS

  BUS -->|"AsyncStream<FiredReaction>"| AP
  BUS -->|"AsyncStream<FiredReaction>"| SF
  BUS -->|"AsyncStream<FiredReaction>"| LED
  BUS -->|"AsyncStream<FiredReaction>"| NR
  BUS -->|"AsyncStream<FiredReaction>"| MBF

  classDef sensor fill:#141414,stroke:#ff6b8a,color:#e8e8e8
  classDef evtsrc fill:#141414,stroke:#ff6b8a,color:#e8e8e8
  classDef fusion fill:#1a1a1a,stroke:#ffb3c4,color:#ffb3c4,stroke-width:2px
  classDef bus fill:#1a1a1a,stroke:#ffb3c4,color:#ffb3c4,stroke-width:2px
  classDef resp fill:#141414,stroke:#ff6b8a,color:#e8e8e8
  classDef menubar fill:#141414,stroke:#ff6b8a,color:#e8e8e8
```

        

        
The bus enricher runs once per reaction before fan-out. All subscribers receive a `FiredReaction` with identical, pre-resolved values: the same `soundURL`, the same `clipDuration`, the same `faceIndices` array, and the same `publishedAt` timestamp. No output re-selects a clip or picks a face. they just consume what the enricher resolved.
