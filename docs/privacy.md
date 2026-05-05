---
title: Privacy Policy
description: Privacy policy for Yamete. Nothing leaves your Mac.
---

# Privacy Policy

*Effective: April 10, 2026. App: Yamete for macOS.*

**Yamete** is a macOS menu bar app that reacts when you smack your laptop. This is the formal document about what it does and does not do with your data. Short answer: **nothing leaves your Mac**. Your smacking habits are your business.

## Data collection

Yamete collects and stores the following data **locally on your Mac only**.

## Activity logs

* Timestamped sensor and detection events written to the app's log directory
  (`~/Library/Application Support/Yamete Direct/logs/` for direct downloads,
  `~/Library/Containers/com.studnicky.yamete/Data/Library/Application Support/Yamete/logs/` for the Mac App Store build).
* Logs may include your Mac's accelerometer serial number (a hardware identifier, used only for debugging).
* **Retention: 24 hours.** Log files older than 24 hours are automatically deleted.
* Logs are never transmitted over the network.

## User preferences

* Detection sensitivity, volume, opacity, frequency band, per-sensor tuning, and device settings.
* Stored in macOS UserDefaults (standard app preferences).
* No personally identifiable information.

## Device identifiers

* Core Audio device UIDs (for audio output routing).
* Display IDs (for flash overlay targeting).
* These are hardware identifiers used only for local device selection. They do not leave the Mac.

## Network access

Yamete does not make any network connections. None. Not even for software updates (the Direct build checks GitHub via the standard Sparkle updater if you opt in, but the core app does nothing network-ish).

## No data sharing

Yamete does not:

* Collect personal information
* Track usage patterns
* Send data to third parties
* Use advertising identifiers
* Require an account or login
* Include analytics, telemetry, or crash reporting services

## Sensor data

Accelerometer, microphone, and headphone motion data is processed in real time for impact detection only. No sensor data is recorded, stored beyond the detection moment, or transmitted anywhere.

Microphone audio buffers are analysed for transient peaks (short, sharp energy spikes) and immediately discarded. No audio recording occurs at any point. The analysis path does not retain input buffers. The app is structurally incapable of recording you.

## Children's privacy

Yamete does not collect any personal information from any user, including children under 13.

## Changes to this policy

If this policy changes, the updated version will be posted at this URL. The effective date at the top of the page will be updated.

## Contact

For privacy questions or corrections to this policy: [file an issue on GitHub.](https://github.com/Studnicky/yamete/issues/new) Yamete collects nothing and sends nothing so there is nothing to ask about privately. Open issues are a better venue anyway. The answers become documentation for everyone with the same question.

Source code is public at [github.com/Studnicky/yamete.](https://github.com/Studnicky/yamete) If you don't trust the policy, read the code. Every word of this is verifiable.
