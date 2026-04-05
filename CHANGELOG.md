# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- ImpactTier enum (Tap/Light/Medium/Firm/Hard) with tier display in menu footer
- DetectionConfig struct for atomic configuration of detection parameters
- AudioResponder and FlashResponder protocols for dependency injection
- SensorID and AudioDeviceUID type-safe identifier newtypes
- NSScreen.displayID extension replacing duplicated NSDeviceDescriptionKey usage
- AccordionCard and SettingHeader reusable UI components
- Per-setting SF Symbol icons with tappable inline help
- Collapsible Device Settings and Sensitivity Settings panels
- Privacy policy (PRIVACY.md)
- All user-facing strings wrapped in NSLocalizedString

### Changed
- Accelerometer API: IOHIDManager → IOHIDEventSystemClient (macOS 15 motion restriction)
- Detection: 4-algorithm voting → 5-gate pipeline (bandpass, spike, rise rate, confirmations, rearm)
- Sensitivity renamed to Reactivity with inverted mapping (higher = more reactive)
- Assets loaded from sounds/ and faces/ folders recursively by extension
- Sound selection: pre-sorted by duration at startup, intensity maps to clip length
- ImpactController split into detect() → respond() with DetectedImpact struct
- Debounce merged with rearm into single Cooldown control
- SensorFusionEngine renamed to ImpactDetectionEngine
- Frequency band: configurable bandpass (HP 20Hz + LP 25Hz default)
- All detection parameters exposed as user-configurable advanced settings
- Entitlements consolidated to single file (Yamete.entitlements)
- Makefile: hardened runtime, proper process kill cycle, release target cleanup
- Default entitlements for development builds (no sandbox)

### Fixed
- @MainActor isolation on ImpactDetectionEngine (was unconfined)
- ScreenFlash hide Task missing @MainActor (AppKit thread safety)
- Updater Tasks missing @MainActor (state mutation isolation)
- EventContext use-after-free on stream termination
- Force unwraps in Logging.swift and Updater.swift URL construction
- Rise rate gate checking instantaneous value instead of window peak
- RMS poisoning after hard impacts (crest factor gate removed — incompatible with IOHIDEventSystem smoothed data)
- Settings schema reset wiping all user preferences on every default change

### Removed
- ImpactDetector, SignalDetectors, DetectorConfig (replaced by ImpactDetectionEngine)
- Crest factor detection gate (IOHIDEventSystem noise floor too close to signal)
- Schema version reset mechanism (UserDefaults.register handles new keys)
- Yamete-hardened.entitlements (consolidated into Yamete.entitlements)
- Prefix-based asset naming requirement (sound_*, face_*)

## [0.0.0] - 2026-04-02

### Added
- Impact detection via BMI286 accelerometer on Apple Silicon Macs
- Menu bar UI with branded pink theme
- Audio and visual response to impacts
- Self-updater via GitHub Releases
- Dual-sink logging with 24-hour retention
- Build via Makefile with swiftc
- MIT license

[Unreleased]: https://github.com/Studnicky/yamete/compare/v0.0.0...HEAD
[0.0.0]: https://github.com/Studnicky/yamete/releases/tag/v0.0.0
