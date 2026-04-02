# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.0] - 2026-04-02

### Added
- Impact detection via BMI286 accelerometer on Apple Silicon Macs
- Four signal processing algorithms (STA/LTA, CUSUM, Kurtosis, PeakMAD) with 2+ vote consensus
- Sensitivity band (dual slider) with noise gate and limiter
- Intensity-dependent sliding windows for volume, flash opacity, and debounce
- 14 audio reaction clips scaled by impact intensity
- Full-screen radial vignette flash with centered face overlay on all monitors
- Intensity-shaped flash envelope (attack/sustain/decay) gated inside sound duration
- Per-monitor face rotation matrix with cross-event dedup
- 11 normalized face SVGs (potrace bezier, uniform 5-color pink palette)
- Display selection (choose which monitors show the flash)
- Audio output device routing (per-device via NSSound)
- Self-updater via GitHub Releases with SHA256, codesign, and bundle ID verification
- Auto-update with daily check interval and native alert prompts
- Dual-sink logging (os.Logger + file-based with 24-hour retention)
- Menu bar UI with branded pink theme and range sliders
- Launch at Login via SMAppService
- Daily impact counter with midnight auto-reset
- First-launch welcome sound on all audio devices
- Themed DMG installer with drag-to-Applications background
- Build via Makefile with swiftc (no Xcode required)
- GitHub Actions CI (lint, build, test) and release workflow
- 30 tabular tests (unit, integration, E2E) via Swift Package Manager
- Swift 6 strict concurrency compliance (zero warnings)
- MIT license

[Unreleased]: https://github.com/Studnicky/yamete/compare/v0.0.0...HEAD
[0.0.0]: https://github.com/Studnicky/yamete/releases/tag/v0.0.0
