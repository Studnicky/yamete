---
title: LED flash detail
description: Caps Lock PWM dithering + a damped spring on the keyboard backlight. The crash-recovery sentinel that puts the brightness back if everything explodes mid-pulse.
---

# LED flash detail

*`LEDFlash` runs two independently-toggleable subsystems with separate menu cards and separate per-event matrix columns. The Caps Lock LED is a binary toggle, dithered at 60 Hz against the shared `Envelope` so the user reads it as a brightness ramp. The keyboard backlight is a CoreBrightness spring oscillating around the captured baseline. Each subsystem is gated by its own `LEDOutputConfig` flag (`enabled` for caps lock, `keyboardBrightnessEnabled` for backlight), so a user can enable either output without enabling the other. A `kb_dirty` sentinel file is written before the pulse begins; if Yamete crashes mid-animation, the next launch reads the sentinel, restores the pre-crash brightness, and deletes it. Idempotent crash recovery for a feature that is, on its face, decorative.*

`LEDFlash` drives two separate hardware paths on each reaction. Each is independently gated:

- **Caps Lock LED** (`SettingsStore.ledEnabled`): discovered via
  `IOHIDManagerCopyDevices` filtered for keyboard HID usage page, then
  element usage page LED / usage Caps Lock. On each 60 Hz tick, a duty
  cycle computed from the spring oscillation level controls whether the
  element value is written 0 or 1. This approximates a PWM opacity ramp
  on a binary LED. `driver.capsLockSet(...)` is gated by `c.enabled`
  inside `LEDFlash.action` so the Caps Lock writes are skipped entirely
  when only keyboard brightness is enabled.

- **Keyboard backlight** (`SettingsStore.keyboardBrightnessEnabled`):
  uses the `KeyboardBrightnessClient` class loaded at runtime from
  `CoreBrightness.framework` (private). The level follows the spring
  oscillation envelope:
  `base + amplitude * easeIn * exp(-decay * t) * cos(omega * t)`
  at 60 Hz. Idle dimming is suspended for the pulse duration to
  prevent the system from fighting the writes. A dirty-sentinel file
  at `app support/kb_dirty` captures the pre-pulse level so a crash
  does not permanently alter backlight state. The card hides entirely
  on hosts where `keyboardBacklightAvailable` returns false (Mac mini,
  Mac Pro, etc. — non-laptops have no backlight).

The menu surfaces two cards in the **Reactions** group: "Keyboard
Brightness" (with a brightness range slider) and "Caps Lock LED" (a
flat toggle). The per-event matrix in **Stimuli** carries one column
per output (`KbBright` and `Caps`), so a user can decide that, e.g.,
a USB attach pulses the backlight but only a slam fires the Caps Lock
indicator.

On `Yamete.shutdown()`, `LEDFlash.resetHardware()` restores keyboard
brightness to the snapshot taken before the first pulse and re-enables
idle dimming.
