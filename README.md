<p align="center">
  <a href="https://studnicky.github.io/yamete">
    <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256%401x.png" alt="Yamete" width="160" height="160">
  </a>
</p>

<h1 align="center">Yamete</h1>

<p align="center"><em>An app that reacts when you smack your MacBook.</em></p>

<!-- ----- ship status ----- -->

[![CI](https://github.com/Studnicky/yamete/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/Studnicky/yamete/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Studnicky/yamete?display_name=tag&label=release&color=brightgreen)](https://github.com/Studnicky/yamete/releases/latest)
[![Release date](https://img.shields.io/github/release-date/Studnicky/yamete?color=blue&label=last%20release)](https://github.com/Studnicky/yamete/releases)
[![Downloads](https://img.shields.io/github/downloads/Studnicky/yamete/total?label=DMG%20downloads&color=orange)](https://github.com/Studnicky/yamete/releases)
[![Latest commit](https://img.shields.io/github/last-commit/Studnicky/yamete/develop?label=last%20commit&color=success)](https://github.com/Studnicky/yamete/commits/develop)
[![Open PRs](https://img.shields.io/github/issues-pr/Studnicky/yamete?color=orchid)](https://github.com/Studnicky/yamete/pulls)

<!-- ----- platform + stack ----- -->

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-555555?logo=apple&logoColor=white)](https://www.apple.com/mac/)
[![Xcode 16](https://img.shields.io/badge/Xcode-16-1575F9?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen?logo=swift&logoColor=white)](Package.swift)
[![Strict Concurrency](https://img.shields.io/badge/strict%20concurrency-complete-blue)](Sources/)
[![No 3rd-party deps](https://img.shields.io/badge/3rd--party%20deps-zero-success)](Package.swift)
[![Menu bar only](https://img.shields.io/badge/LSUIElement-true-lightgrey)](App/Config/Info.plist)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)

<!-- ----- what's inside ----- -->

[![Sensors](https://img.shields.io/badge/sensors-3-blueviolet)](https://studnicky.github.io/yamete/architecture.html#modules)
[![Detection gates](https://img.shields.io/badge/detection%20gates-6-teal)](https://studnicky.github.io/yamete/architecture.html#detection-gates)
[![SPM modules](https://img.shields.io/badge/SPM%20modules-4-steelblue)](https://studnicky.github.io/yamete/architecture.html#modules)
[![Face expressions](https://img.shields.io/badge/face%20expressions-11-9cf)](https://studnicky.github.io/yamete)
[![Sound clips](https://img.shields.io/badge/sound%20clips-9-ff8c00)](App/Resources/sounds)
[![Locales](https://img.shields.io/badge/locales-40-ff69b4)](App/Resources)
[![Build variants](https://img.shields.io/badge/build%20variants-2-yellowgreen)](https://studnicky.github.io/yamete/#two-builds)

<!-- ----- promises ----- -->

[![Zero network](https://img.shields.io/badge/network-zero-black)](https://studnicky.github.io/yamete/privacy.html)
[![Zero analytics](https://img.shields.io/badge/analytics-none)](https://studnicky.github.io/yamete/privacy.html)
[![Zero telemetry](https://img.shields.io/badge/telemetry-none)](https://studnicky.github.io/yamete/privacy.html)
[![Zero tracking](https://img.shields.io/badge/tracking-nope)](https://studnicky.github.io/yamete/privacy.html)
[![Zero Electron](https://img.shields.io/badge/Electron-heavens%20no-darkgreen)](Package.swift)
[![Zero onboarding](https://img.shields.io/badge/onboarding-skipped-lightgrey)](App/Config/Info.plist)
[![Zero cloud](https://img.shields.io/badge/cloud-absent-skyblue)]()
[![Log retention](https://img.shields.io/badge/log%20retention-24h-slategray)](Sources/YameteCore/Logging.swift)

<!-- ----- flex ----- -->

[![Reads an accelerometer Apple never shipped a public API for](https://img.shields.io/badge/audacity-high-red)](https://studnicky.github.io/yamete/architecture.html)
[![BMI286 whisperer](https://img.shields.io/badge/BMI286-whisperer-crimson)](https://studnicky.github.io/yamete/architecture.html#modules)
[![IOKit respecter](https://img.shields.io/badge/IOKit-respecter-indigo)](Sources/SensorKit/AccelerometerReader.swift)
[![MainActor discipline](https://img.shields.io/badge/MainActor-disciplined-purple)](Sources/YameteApp/ImpactController.swift)
[![CFRunLoopRun parked](https://img.shields.io/badge/CFRunLoopRun-parked%20gracefully-darkorchid)](Sources/SensorKit/AccelerometerReader.swift)
[![@unchecked Sendable: 2](https://img.shields.io/badge/unchecked%20Sendable-2%20narrow%20wrappers-lightblue)](Sources/SensorKit/AccelerometerReader.swift)

<!-- ----- flavor ----- -->

[![The face has seen things](https://img.shields.io/badge/the%20face-has%20seen%20things-8a2be2)](https://studnicky.github.io/yamete)
[![Does it spark joy](https://img.shields.io/badge/does%20it%20spark%20joy-occasionally-ffb6c1)](https://studnicky.github.io/yamete/#features)
[![Will improve your life](https://img.shields.io/badge/will%20improve%20your%20life-no-lightcoral)](https://studnicky.github.io/yamete/#why)
[![Engineering effort](https://img.shields.io/badge/engineering%20effort-wildly%20disproportionate-orange)](https://studnicky.github.io/yamete/#why)
[![Dinner party defensibility](https://img.shields.io/badge/dinner%20party%20defensibility-tenuous-gold)](https://studnicky.github.io/yamete/#why)
[![Screaming face](https://img.shields.io/badge/screaming%20face-on%20demand-hotpink)](App/Resources/faces)
[![Warranty](https://img.shields.io/badge/warranty-none%20whatsoever-lightgrey)](#license)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com/Studnicky/yamete/pulls)
[![Built on a Friday](https://img.shields.io/badge/built-on%20a%20Friday-cyan)]()
[![Made with ](https://img.shields.io/badge/made%20with-%E2%9D%A4-red)]()

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
