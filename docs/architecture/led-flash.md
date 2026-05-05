---
title: LED flash detail
description: Caps Lock PWM dithering + a damped spring on the keyboard backlight. The crash-recovery sentinel that puts the brightness back if everything explodes mid-pulse.
---

# LED flash detail

*`LEDFlash` runs two independently-toggleable subsystems. The Caps Lock LED is a binary toggle, dithered at 60 Hz against the shared `Envelope` so the user reads it as a brightness ramp. The keyboard backlight is a CoreBrightness spring oscillating around the captured baseline. A `kb_dirty` sentinel file is written before the pulse begins; if Yamete crashes mid-animation, the next launch reads the sentinel, restores the pre-crash brightness, and deletes it. Idempotent crash recovery for a feature that is, on its face, decorative.*

`LEDFlash` drives two separate hardware paths simultaneously on each reaction.

        
- Caps Lock LED: discovered via `IOHIDManagerCopyDevices` filtered for keyboard HID usage page, then element usage page LED / usage Caps Lock. On each 60 Hz tick, a duty cycle computed from the spring oscillation level controls whether the element value is written 0 or 1. This approximates a PWM opacity ramp on a binary LED.

          - Keyboard backlight (optional): uses the `KeyboardBrightnessClient` class loaded at runtime from `CoreBrightness.framework` (private). The level follows the same spring oscillation envelope: `base + amplitude * easeIn * exp(-decay * t) * cos(omega * t)` at 60 Hz. Idle dimming is suspended for the pulse duration to prevent the system from fighting the writes. A dirty-sentinel file at app support/`kb_dirty` captures the pre-pulse level so a crash does not permanently alter backlight state.

        
On `Yamete.shutdown()`, `LEDFlash.resetHardware()` restores keyboard brightness to the snapshot taken before the first pulse and re-enables idle dimming.
