---
title: Acknowledgments
description: The reverse-engineering work this project is built on.
---

# Acknowledgments

Stands on people who already did the reverse-engineering Apple wouldn't.

## KBPulse

[github.com/EthanRDoesMC/KBPulse](https://github.com/EthanRDoesMC/KBPulse/)

Keyboard brightness via CoreBrightness on M1+. The reason `LEDFlash` can spring the keyboard backlight at all on Apple Silicon. Without this work the keyboard-flash output would be Caps Lock only.

## spank

[github.com/vlasvlasvlas/spank](https://github.com/vlasvlasvlas/spank)

IOKit patterns and hardware-interaction approaches. The conventions for talking to the SPU HID device safely from userland Swift are downstream of this.

## apple-silicon-accelerometer

[github.com/olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)

Proved the BMI286 was accessible at all. Without this we would not be here.

## mac-hardware-toys

[github.com/pirate/mac-hardware-toys](https://github.com/pirate/mac-hardware-toys)

Keyboard-brightness wrapping and system-level integration patterns. Reference for Real/Mock seam shape on private CoreBrightness.

## macbook-lighter

[github.com/harttle/macbook-lighter](https://github.com/harttle/macbook-lighter)

Brightness-daemon design and light-sensing approaches. The shape of `AmbientLightSource` and the SPU usage-7 subscriber owe its design to this prior work.

---

This app only exists because they did the work first. Pay them attention.
