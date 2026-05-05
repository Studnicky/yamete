---
title: Module graph
description: Four SPM targets. One direction. Why each layer exists and what it refuses to know.
---

# Module graph

*The dependency graph is a contract about what each layer is allowed to know. `IOHIDPublic` is a header-only bridging shim and knows nothing about Yamete. `YameteCore` knows nothing about sensors or outputs; it only knows what a `Reaction` is. `SensorKit` and `ResponseKit` both depend on `YameteCore` but never on each other; sources publish `Reaction`s, outputs subscribe to `Reaction`s, and the bus is the only handshake between them. `YameteApp` wires everyone together.*

The codebase is split into four Swift Package Manager targets with a strictly unidirectional dependency graph. `YameteApp` sees everything. `IOHIDPublic` sees nothing.

        
          SPM dependency graph
          
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
graph LR
  A["IOHIDPublic
IOKit HID headers
C interop layer"]:::iokit
  B["SensorKit
SensorSource, EventSource,
ImpactFusion, AccelerometerSource,
MicrophoneSource, HeadphoneMotionSource,
USBSource, PowerSource, etc."]:::sensor
  C["YameteCore
ReactionBus, Reaction, FiredReaction,
FusedImpact, ReactionsConfig,
types, signal processing, logging"]:::core
  D["ResponseKit
AudioPlayer, ScreenFlash,
LEDFlash, NotificationResponder,
FaceLibrary, OutputConfig"]:::response
  E["YameteApp
Yamete (orchestrator),
SettingsStore, MenuBarFace,
SwiftUI shell"]:::app

  A --> B
  A --> D
  C --> B
  C --> D
  B --> E
  D --> E
  C --> E

  classDef iokit fill:#141414,stroke:#ff6b8a,color:#e8e8e8
  classDef sensor fill:#141414,stroke:#ff6b8a,color:#e8e8e8
  classDef core fill:#1a1a1a,stroke:#ffb3c4,color:#ffb3c4,stroke-width:2px
  classDef response fill:#141414,stroke:#ff6b8a,color:#e8e8e8
  classDef app fill:#1a1a1a,stroke:#ffb3c4,color:#ffb3c4,stroke-width:2px
```

        

        
- `IOHIDPublic` -- C header shim exposing private IOKit HID types Apple does not publish. Read-only; never changes.

          - `YameteCore` -- shared types, the reaction bus, signal processing, and logging. No sensor knowledge, no UI. Imported by everything.

          - `SensorKit` -- the entire sensor abstraction: impact sensors (accelerometer, microphone, AirPods motion), infrastructure event sources (USB, power, Bluetooth, audio peripherals, Thunderbolt, display hotplug, sleep/wake), ImpactFusion engine, and ImpactDetector per-sensor gate chain.

          - `ResponseKit` -- audio playback, screen overlay, LED flash, notification dispatch, face image cache. Knows about reactions and intensity; knows nothing about where they came from.

          - `YameteApp` -- the orchestrator. Owns the bus, wires sources and outputs, manages lifecycle. Also the SwiftUI menu bar shell.
