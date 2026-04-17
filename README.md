# Yamete

*An app that reacts when you smack your MacBook.*

[![CI](https://github.com/Studnicky/yamete/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/Studnicky/yamete/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Studnicky/yamete?display_name=tag&label=release&color=brightgreen)](https://github.com/Studnicky/yamete/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Studnicky/yamete/total?label=DMG%20downloads&color=orange)](https://github.com/Studnicky/yamete/releases)

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-555555?logo=apple&logoColor=white)](https://www.apple.com/mac/)
[![Strict Concurrency](https://img.shields.io/badge/strict%20concurrency-complete-blue)](Sources/)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)

[![40 locales](https://img.shields.io/badge/locales-40-ff69b4)](App/Resources)
[![The face has seen things](https://img.shields.io/badge/the%20face-has%20seen%20things-8a2be2)](https://studnicky.github.io/yamete)
[![Uses public IOKit API to read an accelerometer Apple never shipped a public API for](https://img.shields.io/badge/audacity-high-red)](https://studnicky.github.io/yamete/architecture.html)
[![Warranty](https://img.shields.io/badge/warranty-none%20whatsoever-lightgrey)](#license)

Yamete sits in your menu bar, watches the built-in accelerometer, the microphone, and your AirPods if you're wearing them, and plays a sound + flashes a face when anything feels like a smack. The face has range. The sounds have opinions. The notifications, in the Direct build, have no shame whatsoever.

**Everything lives on the project site** → **[studnicky.github.io/yamete](https://studnicky.github.io/yamete)**

This README is the short version. For the tour:

- **[Features, screenshots, the whole pitch](https://studnicky.github.io/yamete)** — what it does and why you might want that
- **[Architecture](https://studnicky.github.io/yamete/architecture.html)** — module graph, detection gates, concurrency model, the whole signal path from IOKit to speaker
- **[Support & FAQ](https://studnicky.github.io/yamete/support.html)** — "what is this", "how do I tune it", "why won't the accelerometer wake up on App Store"
- **[Privacy](https://studnicky.github.io/yamete/privacy.html)** — nothing leaves your Mac. Nothing. *(elaboration unnecessary but available)*
- **[CHANGELOG](CHANGELOG.md)** — every release, what changed, why

## Install

Download the latest **Yamete Direct.dmg** from **[Releases](https://github.com/Studnicky/yamete/releases/latest)**, mount it, drag *Yamete Direct.app* to Applications. Done.

The Mac App Store build ships separately as **Yamete** and is sandboxed. If you want the accelerometer channel on App Store, [install the sensor-kickstart helper](https://studnicky.github.io/yamete/#accelerometer) once per machine — Apple's sandbox won't let the app wake the sensor itself, but a LaunchDaemon can.

### Build from source

```sh
git clone https://github.com/Studnicky/yamete.git
cd yamete
make install     # Yamete Direct.app → /Applications
```

Other make targets: `make build`, `make appstore`, `make dmg`, `make test`, `make lint`.

## What's under the hood

- **Three sensor adapters** fused by a consensus engine with rearm. [Full pipeline on the architecture page](https://studnicky.github.io/yamete/architecture.html#how-it-works).
- **Swift 6 with complete strict concurrency.** The `@unchecked Sendable` surface is two narrow framework-handle wrappers with inline rationale. Everything else is genuine `Sendable` or actor-isolated.
- **Four SPM modules** with a unidirectional graph: `YameteCore` ← `SensorKit`/`ResponseKit` ← `YameteApp`. [Source map](https://studnicky.github.io/yamete/architecture.html#files).
- **Zero network.** No analytics. No telemetry. Local logs auto-rotate every 24 hours. [Privacy page](https://studnicky.github.io/yamete/privacy.html) has the receipts.

## Why does this exist

Apple Silicon MacBooks ship with a real BMI286 accelerometer — the same class of part that's in phones — and Apple exposes exactly zero public API for it on macOS. The entire `CMMotionManager` surface is `API_UNAVAILABLE(macos)`. I read that as an invitation. [Full context](https://studnicky.github.io/yamete/#why).

> If you use this daily, I genuinely want to know why. If you install it, laugh once, and delete it, that's a completely valid outcome and I'm glad you stopped by.

## Contributing

Issues and PRs welcome at [github.com/Studnicky/yamete](https://github.com/Studnicky/yamete). Support is GitHub Issues only — there's no email.

## License

MIT — see [LICENSE](LICENSE). Bundled sound and face assets have their own provenance; see [LICENSES-CONTENT.md](LICENSES-CONTENT.md).
