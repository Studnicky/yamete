---
title: Per-sensor detection gates
description: Six gates between a raw sample and a published reaction. Why each one exists.
---

# Per-sensor detection gates

*Every continuous sensor runs the same six-gate pipeline (`ImpactDetector`): warmup, spike threshold, rise rate, crest factor, confirmation count, intensity remap. Each gate kills a specific class of false positive that the gate before it cannot. Walking the gates in order is walking the design conversation about what counts as an impact.*

Every impact sensor runs an `ImpactDetector` independently. Each sample passes through six gates in order. All six must pass to produce an intensity value. Any gate failure returns nil for that sample. no event emitted, no noise downstream.

        
          ImpactDetector.process() -- per-sample gate chain
          
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
  IN(["new sample
magnitude: Float"]):::io

  WRMP{"warmupSamples
elapsed?"}:::gate
  WRMF(["nil -- skip
filter settling"]):::drop

  EMA["update background RMS
EMA alpha = 0.02"]:::proc
  WIN["append to sliding window
prune entries older than 120ms"]:::proc

  SPK{"magnitude >=
spikeThreshold?"}:::gate
  SPKF(["nil -- too quiet"]):::drop

  RISE{"max consecutive rise
in window >= minRiseRate?"}:::gate
  RISEF(["nil -- not a
sharp transient"]):::drop

  CREST{"peak / backgroundRMS
>= minCrestFactor?"}:::gate
  CRESTF(["nil -- ambient noise
matches peak"]):::drop

  CONF{"above-threshold count
in window >= minConfirmations?"}:::gate
  CONFF(["nil -- not sustained
enough to confirm"]):::drop

  INTENS["compute intensity
clamp (mag - floor) / ceiling to [0,1]"]:::proc

  OUT(["SensorImpact
source, timestamp, intensity"]):::io

  IN --> WRMP
  WRMP -->|"no"| WRMF
  WRMP -->|"yes"| EMA
  EMA --> WIN
  WIN --> SPK
  SPK -->|"no"| SPKF
  SPK -->|"yes"| RISE
  RISE -->|"no"| RISEF
  RISE -->|"yes"| CREST
  CREST -->|"no"| CRESTF
  CREST -->|"yes"| CONF
  CONF -->|"no"| CONFF
  CONF -->|"yes"| INTENS
  INTENS --> OUT

  classDef io fill:#141414,stroke:#ffb3c4,color:#ffb3c4,rx:20
  classDef gate fill:#0a0a0a,stroke:#ff385f,color:#e8e8e8
  classDef proc fill:#0a0a0a,stroke:#ff6b8a,color:#e8e8e8
  classDef drop fill:#0a0a0a,stroke:#666,color:#666
```

        

        
The combination of these gates is what makes Yamete usable at a desk. Typing produces magnitude but no sharp rise. Footsteps produce a rise but the crest factor is too low (ambient RMS is already elevated). A real smack produces all six: a clean spike, a fast transient, a high crest, and multiple samples above threshold in the window.

        
| Gate | What it rejects | Accel default | Mic default | Headphone default |
|---|---|---|---|---|
| warmupSamples | Filter transients on startup (IIR settling) | 50 samples | 50 samples | 50 samples |
| spikeThreshold | Ambient vibration, background noise | 0.020 g | 0.020 PCM | 0.10 g |
| minRiseRate | Slow drifts, HVAC, sustained rumble | 0.010 | 0.010 | 0.05 |
| minCrestFactor | Noisy rooms, street noise (peak/RMS too low) | 1.5 | 1.5 | 1.5 |
| minConfirmations | One-sample spikes, electrical interference | 3 samples | 2 samples | 2 samples |
| intensity mapping | (output stage) maps passing magnitude to 0-1 | 0.002-0.060 g | 0.005-0.300 | 0.05-2.0 g |
