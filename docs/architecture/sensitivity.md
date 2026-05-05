---
title: Sensitivity gate
description: User-facing sensitivity becomes an inverted threshold band that decides which impacts even reach the bus.
---

# Sensitivity gate

*`FusedImpact.applySensitivity` maps the raw 0-1 intensity through the user's sensitivity range. Sensitivity is *inverted* against threshold: high sensitivity means low threshold, more reactivity. Below the band, the impact is rejected silently. Above it, intensity is remapped onto a clean 0-1 scale that the rest of the system uses as the audio/face/flash intensity.*

After fusion but before publishing to the bus, intensity passes through one more mapping. The user's sensitivity sliders define a window over the [0,1] intensity range. The gate rejects impacts below the lower edge and linearly rescales survivors to fill [0,1]. This is implemented as an `intensityGate` closure on `ImpactFusion`, set by `Yamete` during init. Infrastructure event sources bypass this gate entirely — they carry synthesized intensities from `ReactionsConfig.eventIntensity`.

        
          Sensitivity window mapping (FusedImpact.applySensitivity)
          
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
  FI(["raw intensity [0,1]
(from ImpactFusion)"]):::io

  COMP["thresholdLow  = 1 - sensitivityMax
thresholdHigh = 1 - sensitivityMin
band = thresholdHigh - thresholdLow"]:::proc

  GATE{"intensity >=
thresholdLow?"}:::gate
  GATEF(["nil -- drop impact
below sensitivity floor"]):::drop

  MAP["mappedIntensity =
(intensity - thresholdLow) / band
clamped to [0,1]"]:::proc

  OUT(["bus.publish(Reaction.impact)
intensity: mappedIntensity"]):::io

  FI --> COMP
  COMP --> GATE
  GATE -->|"no"| GATEF
  GATE -->|"yes"| MAP
  MAP --> OUT

  classDef io fill:#141414,stroke:#ffb3c4,color:#ffb3c4,rx:20
  classDef gate fill:#0a0a0a,stroke:#ff385f,color:#e8e8e8
  classDef proc fill:#0a0a0a,stroke:#ff6b8a,color:#e8e8e8
  classDef drop fill:#0a0a0a,stroke:#666,color:#666
```
