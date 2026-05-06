---
title: Display / audio pairing
description: How Yamete tries to figure out which audio output belongs to which monitor, and the cases where it can't.
---

# Display / audio pairing

*Many monitors carry their own audio over the video cable — DisplayPort, HDMI, and the built-in MacBook display all do this. The Devices section of the Yamete menu tries to tell you, for each audio output, **which monitor it belongs to**, so a flash on a particular display and the impact sound on its built-in speakers can be reasoned about as one thing. This page explains how it works, when it works, and when it falls back to "we don't know."*

## What you see

In the menu's `Devices › Audio output` list, an audio device that Yamete has been able to associate with a connected display renders a small footnote under its name:

```
🖥  LG Ultra HD                     [ ✓ ]
    attached to LG Ultra HD 4K (Display 2)
```

If no association is found, the footnote is omitted and the row renders single-line. That includes every USB / Bluetooth / Thunderbolt / wired-headphone output, since none of those have a meaningful "owning" display.

## How it works

There are two pairing strategies, applied in order:

### 1. EDID match (DisplayPort / HDMI)

When a monitor's audio is exposed to macOS through the video cable, the kernel registers the audio device as a child of the same IORegistry node that backs the display. That node carries the monitor's raw 128-byte EDID block in a property called `EDID` (or `IODisplayEDID` on some macOS versions).

Yamete extracts three identifiers from the EDID:

| Bytes | Field           | Source                                       |
|-------|-----------------|----------------------------------------------|
| 8–9   | Vendor ID       | Big-endian, 5-bit letter codes packed into 15 bits |
| 10–11 | Product ID      | Little-endian 16-bit                          |
| 12–15 | Serial number   | Little-endian 32-bit (often 0 on cheap monitors) |

The same three identifiers are exposed by Core Graphics on the display side via `CGDisplayVendorNumber()`, `CGDisplayModelNumber()`, and `CGDisplaySerialNumber()`. When the audio device's triple matches a display's triple exactly, that's the pairing.

### 2. Built-in special case

The MacBook's built-in speakers register with transport type `kAudioDeviceTransportTypeBuiltIn`. Apple Silicon and Intel MacBook chassis are guaranteed to have exactly one display where `CGDisplayIsBuiltin == 1`. The pairing is therefore unambiguous and is asserted structurally — no EDID involved.

### What we deliberately don't do

We do **not** match by name string equality (e.g., `audio.name == display.localizedName`). Names are locale-dependent, change across reconnects, and produce false positives when two identical monitors of the same model are connected. The cost of skipping name matching is that some setups behind adapters / docks fall through to "no pairing detected" — that's an honest "we don't know" rather than a possibly-wrong guess.

## When pairing fails

The EDID approach is only as reliable as the path the EDID takes from the monitor to CoreAudio. Several common topologies break that path:

- **USB-C docks.** Many docks present a single composite USB device that exposes audio under transport type `usb` rather than `displayPort` / `hdmi`. The EDID never reaches CoreAudio in that case and Yamete cannot pair the audio to the display. The audio row will show the USB icon and no footnote.
- **KVM switches.** A KVM may rewrite the EDID to a generic placeholder, or attach audio to a different display on different sources. A pairing made under one source can become stale when the user switches.
- **Adapter chains.** HDMI→DP, DP→HDMI, mDP→HDMI, and other adapter combinations sometimes strip or rewrite EDID bytes. Pairing fails silently in that case.
- **Cheap monitors.** Many monitors leave the EDID serial as `0`, which limits the pairing to vendor + product. If two identical monitors of the same model are connected, both may match the same audio device and we fall back to "no pairing" rather than display an ambiguous result.
- **macOS internals shifting.** The IORegistry property names (`EDID` vs `IODisplayEDID`) and the audio device class (`IOAudioEngine` vs `AppleHDAEngineOutput`) have varied across macOS releases. Yamete walks both sets to maximise coverage but may need a new key path on a future release.

When pairing fails, no harm is done — the audio still works, the user just doesn't see the "attached to" footnote on that row. The flash and audio can still target the same monitor; the user just has to map them by hand.

## File pointers

- `Sources/ResponseKit/EDIDExtractor.swift` — IORegistry walk + EDID byte parser.
- `Sources/ResponseKit/DisplayAudioPairing.swift` — pure function that takes the audio-device list and the display list and returns the `(audioUID → CGDirectDisplayID)` map. Re-called on every menu render — cheap (≤10 audio devices, ≤5 displays in any realistic setup).
- `Sources/ResponseKit/AudioDevice.swift` — `AudioOutputDevice.transport` and `.edid` populated by `AudioDeviceManager.outputDevices()`.
- `Sources/YameteApp/Views/MenuBar/DeviceSection.swift` — renders the row icon and "attached to" footnote.
