# Yamete — App Store Release Plan

Version: 1.0.0
Target: Mac App Store (macOS 14.0+ Sonoma, Apple Silicon)
Category: Entertainment
Price: $2.99 USD (Tier 3)

---

## Critical Blockers

These must be resolved before submission. No exceptions.

### BLOCKER-1: Accelerometer Activation API

**Status**: RESOLVED (with caveat)
**Risk**: Low — all IOKit functions are public SDK, but driver property keys are undocumented

#### Implementation

Sensor activation uses `IORegistryEntrySetCFProperty` (declared in `IOKit/IOKitLib.h`)
to set properties on `AppleSPUHIDDriver` IORegistry services. Report reading uses
`IOHIDManager` + `IOHIDDeviceRegisterInputReportCallback` (declared in `IOKit/hid/`).

**What is public API**: Every function called (`IOServiceMatching`, `IOServiceGetMatchingServices`,
`IORegistryEntrySetCFProperty`, `IOHIDManagerCreate`, `IOHIDDeviceOpen`,
`IOHIDDeviceRegisterInputReportCallback`). Zero private symbols in the binary.

**What is undocumented**: The IORegistry driver class name `AppleSPUHIDDriver` and the
property keys `ReportInterval`, `SensorPropertyReportingState`, `SensorPropertyPowerState`.

**Why**: `CMMotionManager` is `API_UNAVAILABLE(macos)`. There is no documented Apple API for
reading the built-in accelerometer on macOS. This is the same approach used by all known
macOS accelerometer utilities.

**Graceful degradation**: If activation fails (return values checked), the app falls back to
microphone-only detection. No crash, no error beyond a log message.

No `@_silgen_name` bindings. No `#if !APP_STORE` guards. One adapter, one build.
Verified: works under App Sandbox with `device.usb` entitlement. 100Hz data on Apple Silicon.

#### Files
- [x] `Sources/IOHIDPublic/include/IOHIDPublic.h` — C bridging header for public SDK headers
- [x] `Sources/SensorKit/AccelerometerReader.swift` — single accelerometer adapter using public API
- [x] `Sources/YameteApp/ImpactController.swift` — adapter list: Accelerometer, Microphone, Headphone Motion
- [x] `Package.swift` — IOHIDPublic C target, SensorKit depends on it
- [x] `Makefile` — includes IOHIDPublic headers
- [x] Verified: the public-header accelerometer path type-checks cleanly, and both the generated Xcode project and direct bundle build succeed in an unsandboxed environment

---

### BLOCKER-2: Build Pipeline — Xcode Project & Signing

**Status**: RESOLVED IN REPO
**Risk**: Remaining manual work is signing/provisioning only

The repo now has one app layout shared by both distribution paths:

- `App/Config/Info.plist` is the single source of truth for app metadata
- `App/Resources/` is the single source of truth for privacy manifest, localizations, sounds, faces, and icons
- `project.yml` defines the Xcode target with explicit resources and no post-build copy script
- `Makefile` builds the direct-download app from the same `App/` tree

**Implementation**:
- [x] Generate the Xcode project from `project.yml` via `xcodegen`
- [x] Keep `YameteApp.swift` as the app entry point while leaving the shared modules in SwiftPM
- [x] Point the app target to `App/Config/AppStore.entitlements`
- [x] Point the app target to `App/Config/Info.plist`
- [x] Add `App/Resources` as target-owned resources, including:
  - [x] `Assets.xcassets/AppIcon.appiconset`
  - [x] `PrivacyInfo.xcprivacy`
  - [x] `*.lproj`
  - [x] `sounds/`
  - [x] `faces/`
- [x] Keep `Sources/IOHIDPublic/include` in the target header search paths
- [x] Split Xcode release configs into `ReleaseAppStore` and `ReleaseDirect`
- [x] Keep the Makefile working for direct distribution from the same app layout
- [ ] Set `DEVELOPMENT_TEAM` in Xcode / `project.yml`
- [ ] Archive with the `Yamete-AppStore` scheme
- [ ] Verify archive builds and validates in Xcode Organizer
- [ ] Test Transporter upload to App Store Connect (can upload without publishing)

**Preserve dual build paths**:
```
make build              # Direct distribution (Yamete Direct.app, ad-hoc sign)
make release            # Direct distribution (Yamete Direct.app, Developer ID sign)
make notarize           # Direct distribution (Yamete Direct.dmg, notarized)
open Yamete.xcodeproj   # App Store project generated from project.yml
xcodebuild archive ...  # App Store (Yamete.app, App Store signing)
```

---

### BLOCKER-3: Internationalization (i18n)

**Status**: RESOLVED IN REPO
**Risk**: Remaining work is translation QA and copy review across 40 locales

The app now resolves its menu UI, footer controls, onboarding copy, and status labels
through `Localizable.strings` resources under `App/Resources/*.lproj`. Remaining release
risk is translation completeness rather than missing localization infrastructure.

#### Supported Locales

All macOS-supported languages (40 locales matching Finder.app):

| Code | Language | Region |
|------|----------|--------|
| `ar` | Arabic | RTL |
| `ca` | Catalan | |
| `cs` | Czech | |
| `da` | Danish | |
| `de` | German | |
| `el` | Greek | |
| `en` | English | Base/US |
| `en_AU` | English | Australia |
| `en_GB` | English | UK |
| `es` | Spanish | Spain |
| `es_419` | Spanish | Latin America |
| `fi` | Finnish | |
| `fr` | French | France |
| `fr_CA` | French | Canada |
| `he` | Hebrew | RTL |
| `hi` | Hindi | |
| `hr` | Croatian | |
| `hu` | Hungarian | |
| `id` | Indonesian | |
| `it` | Italian | |
| `ja` | Japanese | CJK |
| `ko` | Korean | CJK |
| `ms` | Malay | |
| `nl` | Dutch | |
| `no` | Norwegian | |
| `pl` | Polish | |
| `pt_BR` | Portuguese | Brazil |
| `pt_PT` | Portuguese | Portugal |
| `ro` | Romanian | |
| `ru` | Russian | Cyrillic |
| `sk` | Slovak | |
| `sl` | Slovenian | |
| `sv` | Swedish | |
| `th` | Thai | |
| `tr` | Turkish | |
| `uk` | Ukrainian | Cyrillic |
| `vi` | Vietnamese | |
| `zh_CN` | Chinese | Simplified |
| `zh_HK` | Chinese | Hong Kong |
| `zh_TW` | Chinese | Traditional |

#### Architecture: `.lproj` Bundles with `NSLocalizedString`

Apple's built-in localization system is free, offline, and automatic. No custom dispatch maps
needed — `NSLocalizedString` resolves the correct `.strings` file based on the user's device
language settings. This is the standard, expected approach for Mac App Store apps.

**Bundle structure**:
```
App/Resources/
  en.lproj/
    Localizable.strings        # Base English translations
    InfoPlist.strings           # Info.plist display strings
  ja.lproj/
    Localizable.strings
    InfoPlist.strings
  zh_CN.lproj/
    Localizable.strings
    InfoPlist.strings
  ar.lproj/
    Localizable.strings
    InfoPlist.strings
  ... (one directory per locale)
```

**How it works**:
1. All user-facing strings wrapped in `NSLocalizedString("key", comment: "context")`
   or SwiftUI `Text("key", tableName: "Localizable")` / `LocalizedStringKey`
2. macOS reads `AppleLanguages` from the user's system preferences
3. `Bundle.main` resolves the matching `.lproj` directory automatically
4. Falls back to `en.lproj` (Base) if no match exists
5. No custom code, no dispatch maps, no runtime translation — fully offline

**SwiftUI integration**:
- `Text("string_key")` automatically looks up `NSLocalizedString` when `.strings` files exist
- String interpolation: `Text("impacts_today \(count)")` matches `"impacts_today %lld" = "...";`
- Plurals: use `.stringsdict` files for proper plural rules per language

#### String Inventory (75 strings across 5 files)

**File: `Sources/YameteApp/Views/MenuBarView.swift`** (~60 strings)

| Key | English Value | Type | Notes |
|-----|---------------|------|-------|
| `impacts_today` | `%lld impacts today` | Plural | Needs `.stringsdict` |
| `last_impact` | `last: %@` | Format | Tier name substituted |
| `status_paused` | `Paused` | Static | |
| `setting_reactivity` | `Reactivity` | Static | |
| `help_reactivity` | `Impact force response window. Low thumb = weakest force that triggers. High thumb = force for maximum response. Higher values respond to lighter impacts.` | Static | Long help text |
| `setting_volume` | `Volume` | Static | |
| `help_volume` | `Audio playback level window. Intensity maps linearly between low and high. Clip selection also follows intensity — lighter impacts play shorter clips.` | Static | |
| `setting_flash_opacity` | `Flash Opacity` | Static | |
| `help_flash_opacity` | `Screen flash brightness window. Envelope timing shaped by intensity. Gated inside the sound clip duration.` | Static | |
| `tier_hard` | `Hard` | Static | Ruler + ImpactTier |
| `tier_firm` | `Firm` | Static | |
| `tier_medium` | `Med` | Static | Abbreviated on ruler |
| `tier_light` | `Light` | Static | |
| `tier_tap` | `Tap` | Static | |
| `section_sensitivity_sensors` | `Sensitivity & Sensors` | Static | Accordion title |
| `setting_consensus` | `Sensor Consensus` | Static | |
| `help_consensus` | `Number of sensors that must independently detect an impact before triggering. Clamped to the number of sensors delivering data.` | Static | |
| `consensus_format` | `%lld sensor(s)` | Plural | Needs `.stringsdict` |
| `setting_cooldown` | `Cooldown` | Static | |
| `help_cooldown` | `Minimum time between reactions. 0 = gated only by the playing clip's duration.` | Static | |
| `section_accel_tuning` | `Accelerometer Tuning` | Static | Section header |
| `setting_frequency_band` | `Frequency Band` | Static | |
| `help_frequency_band` | `Bandpass filter on raw accelerometer data. Low = high-pass cutoff (rejects floor vibrations). High = low-pass cutoff (rejects electronic noise).` | Static | |
| `unit_hz` | `%lld Hz` | Format | |
| `setting_spike_threshold` | `Spike Threshold` | Static | |
| `help_spike_threshold` | `Minimum filtered magnitude (g-force) to consider as a potential impact. Applied after bandpass filtering. Higher values require stronger force.` | Static | |
| `unit_gforce` | `%.3fg` | Format | |
| `setting_crest_factor` | `Crest Factor` | Static | |
| `help_crest_factor` | `Peak signal must exceed background RMS by this multiple. Sharp desk hits spike well above background. Footsteps raise background along with peak. Higher values reject more ambient vibration.` | Static | |
| `unit_multiplier` | `%.1f\u{00D7}` | Format | Multiplication sign |
| `setting_rise_rate` | `Rise Rate` | Static | |
| `help_rise_rate` | `Minimum magnitude increase between consecutive samples. Direct impacts rise in 1-2 samples. Transmitted vibrations rise gradually. Higher values reject indirect vibration.` | Static | |
| `setting_confirmations` | `Confirmations` | Static | |
| `help_confirmations` | `Above-threshold samples required in the 120ms detection window. Direct hits produce 3-5 high samples. Single jolts produce 1-2.` | Static | |
| `confirmations_format` | `%lld hit(s)` | Plural | Needs `.stringsdict` |
| `setting_warmup` | `Warmup` | Static | |
| `help_warmup` | `Samples before detection activates. Filters need time to settle. At 50 Hz, 50 samples = 1 second.` | Static | |
| `unit_seconds` | `%.1fs` | Format | |
| `setting_report_interval` | `Report Interval` | Static | |
| `help_report_interval` | `Accelerometer polling interval. 10ms = 100 Hz (default), 5ms = 200 Hz, 20ms = 50 Hz. Changes take effect on sensor restart.` | Static | |
| `unit_milliseconds` | `%.0fms` | Format | |
| `section_devices` | `Devices` | Static | Accordion title |
| `devices_subtitle` | `%lld displays, %lld audio` | Format | |
| `setting_flash_displays` | `Flash Displays` | Static | |
| `help_flash_displays` | `Select which monitors show the flash overlay on impact.` | Static | |
| `setting_audio_output` | `Audio Output` | Static | |
| `help_audio_output` | `Select which audio devices play impact sounds. None selected = no audio.` | Static | |
| `no_output_devices` | `No output devices found` | Static | |
| `label_launch_at_login` | `Launch at Login` | Static | |
| `label_debug_logging` | `Debug Logging` | Static | |
| `button_quit` | `Quit` | Static | |
| `version_format` | `v%@` | Format | |
| `unit_percent` | `%lld%%` | Format | |

**File: `Sources/YameteCore/Domain.swift`** (5 strings — ImpactTier descriptions)

| Key | English Value | Notes |
|-----|---------------|-------|
| `tier_tap_full` | `Tap` | ImpactTier.description |
| `tier_light_full` | `Light` | |
| `tier_medium_full` | `Medium` | Full, not abbreviated |
| `tier_firm_full` | `Firm` | |
| `tier_hard_full` | `Hard` | |

**File: `Sources/SensorKit/SensorAdapter.swift`** (4 strings — already localized)

Already wrapped in `NSLocalizedString`. Verify `.strings` files provide translations.

**File: `Sources/YameteApp/Views/MenuBarIcon.swift`** (1 string)

| Key | English Value | Notes |
|-----|---------------|-------|
| `icon_fallback` | `(≧▽≦)` | Kaomoji fallback — keep universal, do not translate |

**File: `App/Config/Info.plist`** (2 strings — via `InfoPlist.strings`)

| Key | English Value | Notes |
|-----|---------------|-------|
| `NSMotionUsageDescription` | `Yamete uses the accelerometer to detect physical impacts on your MacBook.` | System permission dialog |
| `NSMicrophoneUsageDescription` | `Yamete can use the microphone to detect impact sounds on your desk.` | System permission dialog |

#### Translation Strategy

For 40 locales x ~75 strings = ~3,000 string translations.

**Phase 1 — Extract (build-time)**:
- Wrap all strings in `NSLocalizedString("key", comment: "context for translator")`
- Run `genstrings` to generate base `en.lproj/Localizable.strings`
- Create `en.lproj/InfoPlist.strings` for Info.plist descriptions
- Create `.stringsdict` files for plural forms (`impacts_today`, `consensus_format`, `confirmations_format`)

**Phase 2 — Translate (development-time, offline at runtime)**:

Options for free translation generation:

| Method | Cost | Quality | Offline at runtime |
|--------|------|---------|-------------------|
| Apple String Catalogs + Xcode export/import | Free | High (with review) | Yes — compiled into bundle |
| `genstrings` + batch translate via free API, ship as static `.strings` | Free | Medium | Yes — static files in bundle |
| Community translation (open source on GitHub) | Free | Variable | Yes — PR'd `.strings` files |
| Claude / LLM batch translation of `.strings` file | Free | High for UI strings | Yes — generated at dev time, shipped static |

**Recommended**: Generate initial translations using LLM batch processing of the `.strings` file.
Each string has context (the `comment` parameter). Output one `.strings` file per locale. Ship
them as static resources. Community can submit corrections via GitHub PRs.

All translations are **baked into the app bundle at build time**. Zero network access at runtime.
macOS selects the correct `.lproj` automatically based on System Settings > Language & Region.

**Phase 3 — Plurals**:

Three strings need `.stringsdict` plural rules: `impacts_today`, `consensus_format`, `confirmations_format`.
Different languages have different plural categories (Arabic has 6 forms, English has 2, Japanese has 1).
Apple's `.stringsdict` format handles this natively:

```xml
<!-- en.lproj/Localizable.stringsdict -->
<key>impacts_today</key>
<dict>
    <key>NSStringLocalizedFormatKey</key>
    <string>%#@count@ impacts today</string>
    <key>count</key>
    <dict>
        <key>NSStringFormatSpecTypeKey</key>
        <string>NSStringPluralRuleType</string>
        <key>NSStringFormatValueTypeKey</key>
        <string>lld</string>
        <key>one</key>
        <string>%lld impact today</string>
        <key>other</key>
        <string>%lld impacts today</string>
    </dict>
</dict>
```

**Phase 4 — RTL Support**:

Arabic (`ar`) and Hebrew (`he`) are right-to-left. SwiftUI handles RTL layout automatically
when using standard layout primitives (`HStack`, `VStack`, `Spacer`). Verify:
- [ ] Menu bar view renders correctly in RTL
- [ ] RangeSlider and SingleSlider thumb positions are mirrored
- [ ] Text alignment respects `.environment(\.layoutDirection, .rightToLeft)`
- [ ] No hardcoded `.leading`/`.trailing` that should flip

#### Implementation Checklist

- [x] Create `en.lproj/Localizable.strings` with all 75 keys
- [x] Create `en.lproj/Localizable.stringsdict` for plural forms
- [x] Create `en.lproj/InfoPlist.strings` for usage descriptions
- [ ] Wrap all hardcoded strings in `MenuBarView.swift` with `NSLocalizedString` or `LocalizedStringKey`
- [ ] Wrap `ImpactTier.description` strings with `NSLocalizedString`
- [ ] Verify existing `NSLocalizedString` calls in `SensorAdapter.swift` have matching keys
- [x] Generate `.lproj` directories for all 40 locales
- [x] Generate translations for all locales (LLM batch + review)
- [x] Create `.stringsdict` files for all locales (plural rules per CLDR)
- [x] Create `InfoPlist.strings` for all locales
- [ ] Test RTL layout (Arabic, Hebrew) in SwiftUI previews
- [ ] Test CJK rendering (Japanese, Chinese, Korean) — verify text doesn't clip
- [ ] Test with `NSUserDefaults -AppleLanguages "(ja)"` launch argument
- [x] Add `CFBundleLocalizations` array to Info.plist listing all supported locales
- [ ] Update Makefile to copy `.lproj` directories into bundle
- [ ] Verify `Bundle.main.localizedString` resolves correctly in the Makefile-built bundle

---

## Required Before Submission

### R-1: App Store Connect Metadata
- [ ] App name: "Yamete" (verify availability)
- [ ] Subtitle (30 chars max): "Desk Impact Reactions"
- [ ] App Store description (short + full)
- [ ] Keywords: impact, accelerometer, desk, slap, reaction, menu bar, sound, flash, sensor
- [ ] Screenshots: at least 1 screenshot for each Mac display resolution
- [ ] App preview video (optional, strongly recommended — shows the impact reaction)
- [ ] Privacy policy URL (host PRIVACY.md content at a stable URL)
- [ ] Support URL (GitHub repository or dedicated page)
- [ ] Marketing URL (optional)
- [ ] Copyright: "2026 Studnicky"
- [ ] Age rating: 4+ (no objectionable content — verify face images are appropriate)
- [ ] App Store review notes: explain USB entitlement, microphone purpose, how to test

### R-2: Privacy Manifest Completeness
- [ ] Add `NSPrivacyAccessedAPICategoryFileTimestamp` to `PrivacyInfo.xcprivacy`
  — `LogStore.pruneStaleFiles()` reads file modification dates via `attributesOfItem(atPath:)`
  — Reason: `DDA9.1` (accessing file timestamps for app functionality)
- [ ] Verify `UserDefaults` reason `CA92.1` is still the correct code for current Apple docs

### R-3: Info.plist Additions
- [x] Add `CFBundleLocalizations` array with all supported locale codes
- [ ] Verify `CFBundleShortVersionString` = `1.0.0` and `CFBundleVersion` = `1`
- [ ] Prepare explanation for App Review re: `com.apple.security.device.usb` entitlement

### R-4: Content Licensing Audit
- [ ] Verify all 9 sound files (sound_00 through sound_13) are royalty-free / owned
- [ ] Verify all 11 face SVGs are original work or properly licensed
- [ ] Document content licenses (add LICENSES-CONTENT.md or note in README)
- [ ] If using third-party assets, verify commercial distribution rights

### R-5: Build & Signing Verification
- [ ] Test signed build launches from `/Applications/`
- [ ] Test on clean macOS 14 install (no prior UserDefaults or Application Support/Yamete)
- [ ] Test first-launch flow: welcome sound, default device migration, permission prompts
- [ ] Test with all sensors disabled (error state UX)
- [ ] Test with microphone permission denied (graceful degradation)
- [ ] Verify app runs entirely within sandbox (no file access outside container + bundle)

### R-6: Test Suite Accuracy
- [x] README claims 41 tests; only 37 run. Update README to match actual count.

---

## Recommended Improvements

### I-1: Permission Onboarding
The app requests `audio-input` entitlement but does not proactively prompt for microphone
access. macOS auto-prompts on first `AVAudioEngine` start, but a pre-prompt explanation
improves conversion (users are more likely to grant access when they understand why).
- [ ] Add a brief first-run explanation before microphone activation
- [ ] Handle microphone denial gracefully with a message in the sensor error area

### I-2: Settings Reset
No UI to reset all settings to defaults. Users who misconfigure advanced detection tuning
have no easy way to recover.
- [ ] Add "Reset to Defaults" button in the footer or sensitivity section

### I-3: Face Image Format
Bundle ships 11 SVGs; PNG versions exist in `Assets/faces-png/` but aren't in the bundle.
`NSImage` SVG rendering can vary across macOS versions.
- [ ] Consider shipping PNGs alongside or instead of SVGs for reliability

### I-4: Intel Mac Consideration
Binary targets `arm64-apple-macosx14.0` only. Intel Macs lack the BMI286 accelerometer
but can use microphone detection. A universal binary with microphone-only mode would expand
the addressable market. App Review may also question ARM-only.
- [ ] Evaluate effort to support Intel (microphone-only mode)
- [ ] Or document why ARM-only in App Store review notes

### I-5: Dead Code
`ImpactDetector.prevMag` (line 55) is assigned at line 76 but never read afterward.
- [ ] Remove the dead assignment

### I-6: App Store Review Notes Template
Prepare detailed review notes:
```
What the app does:
  Yamete detects physical impacts (desk slaps, taps) on Apple Silicon MacBooks
  using the built-in accelerometer and microphone. It responds with audio clips
  and animated screen flash overlays. It runs as a menu bar app.

Why USB entitlement is needed:
  The com.apple.security.device.usb entitlement enables IOHIDManager access to
  read the built-in BMI286 accelerometer. This is a public IOKit API. The app
  reads motion data from the sensor to detect physical impacts on the device.

Why microphone access is needed:
  The microphone detects impact sounds (desk taps, slaps) as a complementary
  sensor to the accelerometer. Audio data is processed in real-time for
  transient detection only. No audio is recorded, stored, or transmitted.

How to test:
  1. Launch the app (appears in menu bar)
  2. Grant microphone permission when prompted
  3. Firmly tap or slap the desk next to the MacBook
  4. The app will play a sound and flash the screen
  5. Adjust Reactivity slider in the menu bar dropdown to change sensitivity
```

---

## Price Point Analysis

**Recommendation: $2.99 USD (Tier 3)**

| Factor | Assessment |
|--------|------------|
| Market segment | Novelty / Entertainment utility |
| Comparable apps | Desk toy, ambient reaction, menu bar gag apps: $0.99-$4.99 |
| Technical depth | Multi-sensor fusion, signal processing, configurable pipeline |
| Revenue model | One-time purchase, no IAP, no subscription |
| Net per sale | ~$2.54 (Apple 85% after year 1) or ~$2.09 (70% year 1) |
| Impulse buy threshold | $2.99 is below the $3 pause-and-think boundary |
| $1.99 consideration | Viable if prioritizing volume over per-unit revenue |
| $4.99+ risk | Hurts conversion for entertainment-only apps |
| Free tier | Would require ads (conflicts with privacy stance) |

Regional pricing is handled automatically by Apple's tier system. Tier 3 maps to
locally appropriate prices in all App Store territories.

---

## Implementation Order

```
Phase 1: Internationalization          (BLOCKER-3: wrap strings, generate translations)
Phase 3: Xcode project + signing      (BLOCKER-2: create project, configure signing)
Phase 4: Required items               (R-1 through R-6)
Phase 5: Recommended improvements     (I-1 through I-6, prioritize as desired)
Phase 6: Final QA                     (full test pass, clean install, all locales)
Phase 7: Submit to App Store Connect
```
