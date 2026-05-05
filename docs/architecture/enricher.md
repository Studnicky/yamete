---
title: Bus enricher
description: One pre-fan-out pass that resolves the audio clip, picks the face, and stamps `publishedAt`. So every output sees the same reaction.
---

# Bus enricher

*`ReactionBus` runs a single enricher before any subscriber receives a `Reaction`. The enricher resolves the audio clip URL + duration, calls `FaceLibrary.selectIndices(count:)` to deduplicate face picks across multiple displays, and stamps `publishedAt`. The output is a `FiredReaction`. Audio, screen flash, LED, and notification all see the same enriched envelope, so a reaction stays in lockstep regardless of how many outputs are firing.*

Before any subscriber receives a reaction, `ReactionBus` runs a registered enricher closure exactly once. The enricher resolves all per-reaction metadata so that every subscriber operates on identical, pre-computed values. The bus stamps `publishedAt` at the moment `publish(_:)` is called. before enrichment begins. so the timestamp is stable regardless of enrichment latency. If enrichment takes longer than 500 ms, the bus publishes a minimal fallback `FiredReaction`.

        
The enricher, registered by `Yamete.startOutputs()`, does three things:

        
- Calls `AudioPlayer.peekSound(intensity:reaction:)` to dedup-filter and intensity-select an audio clip URL and duration. For non-impact reactions, `peekSound` returns nil and the bus falls back to `ReactionsConfig.eventResponseDuration`.

          - Calls `FaceLibrary.shared.selectIndices(count:)` with the current connected screen count to pick one face index per display, scored for recency dedup.

          - Returns a `FiredReaction` carrying the resolved `soundURL`, `clipDuration`, `faceIndices`, and `publishedAt`.
