---
title: Fusion engine
description: Consensus across three impact sensors plus a rearm gate that keeps a single tap from firing twice.
---

# Fusion engine

*`ImpactFusion` runs a fan-in `TaskGroup` across every active impact sensor, holds a sliding window for consensus, applies sensitivity remapping, and then publishes one `Reaction.impact`. The rearm gate is the difference between an app that yells once when you smack it and an app that yells four times because four sensors agreed.*

Individual sensor impacts feed into `ImpactFusion`, which enforces two additional constraints before publishing a `Reaction.impact` onto the bus: consensus (enough sensors must agree within a time window) and rearm (minimum gap between consecutive responses). Before publishing, the sensitivity gate — an `intensityGate` closure set by the orchestrator — maps raw fused intensity through the user's sensitivity band and drops impacts that fall below the floor.

        
          ImpactFusion.ingest() -- one call per SensorImpact
          
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
  IN(["SensorImpact arrives
source, timestamp, intensity"]):::io

  PRUNE["prune impacts older than
fusionWindow (default 150ms)"]:::proc

  APPEND["append new impact
to time window"]:::proc

  REARM{"now >= lastTriggerAt
+ rearmDuration?"}:::gate
  REARMF(["nil -- too soon
cooldown active"]):::drop

  CONS{"unique sources in window
>= consensusRequired
(clamped to active count)?"}:::gate
  CONSF(["nil -- not enough
sensors agree yet"]):::drop

  FUSE["best impact per source
average intensity across sources
confidence = participants / active"]:::proc

  SENS{"intensityGate(intensity)
returns non-nil?"}:::gate
  SENSF(["nil -- below
sensitivity floor"]):::drop

  MARK["lastTriggerAt = now
clear window"]:::proc

  OUT(["bus.publish(Reaction.impact)
remapped intensity, confidence, sources"]):::io

  IN --> PRUNE
  PRUNE --> APPEND
  APPEND --> REARM
  REARM -->|"no"| REARMF
  REARM -->|"yes"| CONS
  CONS -->|"no"| CONSF
  CONS -->|"yes"| FUSE
  FUSE --> SENS
  SENS -->|"no"| SENSF
  SENS -->|"yes"| MARK
  MARK --> OUT

  classDef io fill:#141414,stroke:#ffb3c4,color:#ffb3c4,rx:20
  classDef gate fill:#0a0a0a,stroke:#ff385f,color:#e8e8e8
  classDef proc fill:#0a0a0a,stroke:#ff6b8a,color:#e8e8e8
  classDef drop fill:#0a0a0a,stroke:#666,color:#666
```

        

        
The default `consensusRequired = 1` means any single sensor can trigger a response. Set it to 2 and both the accelerometer and microphone have to agree within 150 ms before anything fires — eliminates most false positives at the cost of some missed detections on very clean impacts. The engine clamps `consensusRequired` to the active source count at runtime, so "require 2" against a single connected sensor still emits.

        
| Parameter | Default | Effect |
|---|---|---|
| fusionWindow | 150 ms | Time window within which multiple sensors must all fire to count as consensus |
| consensusRequired | 1 | Minimum distinct sensor sources in window before firing (clamped to active count) |
| rearmDuration | user debounce | Minimum gap between consecutive fused impacts; set from SettingsStore.debounce |
