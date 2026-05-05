---
title: What is this?
description: A direct answer to the obvious question, plus the extras you didn't ask but might wonder.
---

# What is this?

## What does Yamete actually do?

Lives in your menu bar. When you smack your Mac, it reacts. A sound clip plays, a face shows, optionally the screen flashes or a notification fires. Gentle pat: a small "mm~". Proper smack: something with more conviction. The face has range.

Under the hood: three parallel detection pipelines (accelerometer, microphone, AirPods IMU), fused via a consensus engine, scaled to impact intensity. More engineered than the concept deserves. I'm at peace with that.

## What does "Yamete" mean?

Japanese for "stop." The playful, flirty register. Not the "I mean it" register. Closer to "stop it~" than "cease immediately." Perfect.

## Is this a joke?

The concept is silly. The implementation is not. Swift 6 with full strict concurrency, multi-sensor signal processing with proper bandpass filters, a real consensus engine, thread-safe HID stream cleanup, a full test pyramid. Treat it as a serious engineering exercise in service of an extremely unserious idea.

## Why does this exist?

Apple Silicon MacBooks ship with a real BMI286 accelerometer. Apple marks every line of `CMMotionManager` as `API_UNAVAILABLE(macos)`. That sounded bratty to me. I touched it anyway.

Also I wanted to. Full stop.

## Do I actually need this?

No. That has never been the pitch.

