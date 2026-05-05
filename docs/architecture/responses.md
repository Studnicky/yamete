---
title: Response dispatch
description: Independent subscribers on the bus, each gated by the per-output per-reaction toggle matrix.
---

# Response dispatch

*Outputs subscribe to the bus independently. Each output is a `ReactiveOutput` that pattern-matches `ReactionKind` and consults its row of the per-output toggle matrix before firing. A reaction with LED + sound enabled and flash off produces a pulse and a clip and nothing on screen. The matrix is a hard gate, not a hint.*

Each output independently subscribes to the bus via `bus.subscribe()`, which returns a fresh `AsyncStream<FiredReaction>`. The consumer loop reads a live config snapshot on every reaction and gates by: the output's master enable, the per-output per-reaction toggle matrix, and an internal playback-ends-at guard that prevents overlapping responses.

        
          Output consumer loop (same structure for all four outputs)
          
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
  BUS(["bus.subscribe()
AsyncStream<FiredReaction>"]):::io

  CFG["configProvider.xyzConfig()
read live settings snapshot"]:::proc

  EN{"config.enabled?"}:::gate
  ENF(["skip"]):::drop

  MATRIX{"perReaction[fired.kind]
!= false?"}:::gate
  MATRIXF(["skip"]):::drop

  GUARD{"now >= outputEndsAt?"}:::gate
  GUARDF(["skip -- still playing"]):::drop

  ACT["perform output action
(play / flash / pulse / notify)"]:::proc

  REARM["outputEndsAt = now + fired.clipDuration"]:::proc

  BUS --> CFG --> EN
  EN -->|"no"| ENF
  EN -->|"yes"| MATRIX
  MATRIX -->|"no"| MATRIXF
  MATRIX -->|"yes"| GUARD
  GUARD -->|"no"| GUARDF
  GUARD -->|"yes"| ACT
  ACT --> REARM

  classDef io fill:#141414,stroke:#ffb3c4,color:#ffb3c4,rx:20
  classDef gate fill:#0a0a0a,stroke:#ff385f,color:#e8e8e8
  classDef proc fill:#0a0a0a,stroke:#ff6b8a,color:#e8e8e8
  classDef drop fill:#0a0a0a,stroke:#666,color:#666
```

        

        
| Output | Config type | Action | Notes |
|---|---|---|---|
| AudioPlayer | AudioOutputConfig | Plays the pre-selected fired.soundURL on each enabled Core Audio device. Volume = volumeMin + intensity * range. | For non-impact reactions, soundURL is nil. audio skips. |
| ScreenFlash | FlashOutputConfig | Renders a borderless NSWindow overlay per enabled screen: radial gradient + face image. Fade-in / hold / fade-out envelope, timing scaled to intensity. | Window pool reused across reactions. Face pulled from fired.faceIndices. |
| LEDFlash | LEDOutputConfig | PWM-dithers the Caps Lock LED via IOKit HID at 60 Hz. Optionally animates keyboard backlight via KeyboardBrightnessClient (CoreBrightness private framework) with a spring oscillation envelope. Restores both to pre-pulse state on completion. | Crash-recovery sentinel file written before first pulse; deleted on clean restore. |
| NotificationResponder | NotificationOutputConfig | Posts a UNMutableNotificationContent with a tier-matched phrase from a 40-locale string table. Auto-dismisses after dismissAfter. | Locale: user override or system fallback. |

        
`MenuBarFace` also subscribes to the bus independently. It only reacts to `.impact` reactions, swaps the `NSStatusItem` icon to the face at `fired.faceIndices[0]` for `max(0.5, debounce)` seconds, then restores the template icon. It is not an output in the sense of the four above. it has no config provider and no toggle matrix.
