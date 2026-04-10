# Codex Review — Remediation Plan

Findings from the most recent Codex audit, grouped by severity, with a concrete plan per item.
Every code line reference is pinned to the audit run — verify before editing.

---

## App Store Age Rating (what Apple actually requires)

The user asked what the App Store requires. **There is no 13+ rating on the App Store.**
Apple uses four tiers: **4+, 9+, 12+, 17+**.

Relevant descriptors for this app (kink/DDLG body content, daddy references, moaning audio):

- **Frequent/Intense Mature/Suggestive Themes** → forces **17+**
- **Frequent/Intense Sexual Content or Nudity** → forces **17+**
- **Frequent/Intense Profanity or Crude Humor** → forces **17+**

Yamete's notification copy ("Mmm~ daddy~", "I'LL BE GOOD!!", submissive begging, audio moans)
sits squarely in **Frequent/Intense Mature/Suggestive Themes**. Correct rating is **17+**.

**Stronger caveat**: Apple App Store Review Guideline **1.1.4** prohibits
*"Overtly sexual or pornographic material"* at **any** rating. A kink app whose
core mechanic is producing moans on impact can realistically be rejected outright
regardless of the descriptors selected. Shipping 17+ is necessary but may not be
sufficient.

**Recommended path**:
1. Ship two builds: `Yamete` (tame, App Store) and `Yamete Direct` (spicy, notarized direct-download).
2. The `DIRECT_BUILD` flag already exists in the codebase — extend it to gate the moan/title string pools.
3. App Store build: replace `moan_*`/`title_*` bodies with mild flirty but non-sexual phrases.
4. Direct build: full DDLG register unchanged.
5. Update `docs/APP_STORE_METADATA.md` to reflect 17+ on the App Store variant even with tame copy (daddy-adjacent brand identity alone is suggestive enough to warrant 17+ safely).

---

## Blocker #1 — App Store metadata mismatch (publish blocker)

**Symptoms**
- `App/Resources/en.lproj/Localizable.strings` contains "Mmm~ daddy~", "Please, daddy~", "I'LL BE GOOD!!"
- `docs/APP_STORE_METADATA.md:13` declares Age Rating: 4+
- `docs/APP_STORE_METADATA.md:133` declares Sexual Content: None, Mature/Suggestive Themes: None
- Translator comments in the `.strings` files editorialize about "DDLG kink register"

**Plan**
1. **Fork the strings**: introduce a build-time switch that selects between tame/spicy pools.
   - Option A: Two `Localizable.strings` variants per locale (complex, 40 locales × 2 = 80 files).
   - Option B (preferred): One strings file, but body/title pools use keys `moan_tame_*` / `title_tame_*` alongside the existing DDLG pools. `NotificationPhrase` switches prefix based on `DIRECT_BUILD`.
2. **Strip editorial comments** from every `.strings` file. Replace with factual per-section comments ("Impact notification moans — random per-tier variants"). No "DDLG kink register" commentary in shipped binaries.
3. **Update `docs/APP_STORE_METADATA.md`**:
   - Age Rating: **17+**
   - Mature/Suggestive Themes: **Frequent/Intense** (brand name "Yamete" + concept warrants this even with tame copy)
   - Sexual Content: **None** (after tame copy swap)
   - Update the App Review Notes section with an honest description of the app concept.
4. **Verification gate**: add a lint step to `Makefile` that greps the App Store build bundle for the word "daddy" and fails if found. Direct build exempt.

**Files touched**: `App/Resources/**/Localizable.strings` (40), `docs/APP_STORE_METADATA.md`, `Makefile`, `Sources/ResponseKit/NotificationResponder.swift`

---

## Blocker #2 — Accelerometer unaligned memory access (undefined behavior)

**Symptoms**
`Sources/SensorKit/AccelerometerReader.swift:315-320` reads `Int32` at byte offsets 6, 10, 14 via
`withMemoryRebound`. Those offsets are not 4-byte aligned. `withMemoryRebound` has a documented
contract that the source pointer must be properly aligned for the target type. This is UB regardless
of whether it "works" on Apple Silicon.

**Plan**
Replace each `withMemoryRebound` load with `loadUnaligned(fromByteOffset:as:)`, which is the Swift-sanctioned
API for exactly this case (available since Swift 5.7 / macOS 13):

```swift
let rawBuffer = UnsafeRawPointer(report)
let rawX = rawBuffer.loadUnaligned(fromByteOffset: 6, as: Int32.self)
let rawY = rawBuffer.loadUnaligned(fromByteOffset: 10, as: Int32.self)
let rawZ = rawBuffer.loadUnaligned(fromByteOffset: 14, as: Int32.self)
```

No functional change on Apple Silicon (where unaligned loads are free), but removes the UB and
satisfies the Swift memory model. Endianness matches current implementation.

**Files touched**: `Sources/SensorKit/AccelerometerReader.swift`
**Tests**: existing accelerometer decode tests cover this path.

---

## Major #3 — Visual Response = Off still animates menu bar and dock

**Symptoms**
`ImpactController.respond()` at `Sources/YameteApp/ImpactController.swift:196` unconditionally calls
`showReactionFace()`, then gates overlay/notification dispatch afterward at line 199. So with Visual
Response = Off but sound enabled, the dock icon and menu bar still swap faces.

**Conflict with prior user instruction**
Earlier in this session the user stated *"The dock should always react, the mode selection is accurate.
When overlay and notification are off, the dock still responds."* Codex is flagging this as a bug.

**Plan — requires user decision**. Three options:

- **A. Honor the UI**: Visual Response = Off disables ALL visual feedback (dock, menu bar, overlay, notification). Pipeline still runs for audio only. Fix: wrap `showReactionFace()` call in `guard settings.visualResponseMode != .off`.
- **B. Keep prior instruction**: Dock reaction is part of "any feedback is enabled" and cannot be turned off. Rename the UI setting from "Visual Response" to **"Flash Mode"** (off / overlay / notification) so the user understands dock is separate. Add a brief caption.
- **C. Split it out**: Add a separate "Dock Reaction" toggle (on/off), independent of visual mode. More controls, most flexibility.

**Recommendation**: **B** (rename, clarify scope) because the user was explicit that the dock must always react.

**Files touched** (option B): `Sources/YameteApp/Views/MenuBarView.swift`, `App/Resources/en.lproj/Localizable.strings` (rename `setting_visual_response` label), 40 locale files for label rename.

---

## Major #4 — `screenFlash` and `visualResponseMode` are dual sources of truth

**Symptoms**
- `SettingsStore` persists both `screenFlash` (Bool) and `visualResponseMode` (enum off/overlay/notification)
- Only `MenuBarView` syncs them on mode change (`onChange` sets `screenFlash = (mode != .off)`)
- `ImpactController.shouldBeEnabled` at `Sources/YameteApp/ImpactController.swift:65` keys off `screenFlash`
- `ImpactResponse.triggerFlash` at `Sources/YameteApp/ImpactController.swift:314` gates on both `screenFlash` AND `visualResponseMode != .off`
- **Migration hazard**: existing users with persisted `screenFlash = false` + picked `.overlay` → pipeline never runs

**Plan**
1. **Make `visualResponseMode` the single source of truth** for visual feedback state.
2. **Delete** the persisted `screenFlash` key entirely. Replace with a computed property:
   ```swift
   var screenFlashEnabled: Bool { visualResponseMode != .off }
   ```
3. **Migration**: on first launch after upgrade, if the legacy `screenFlash` key exists in UserDefaults:
   - If `screenFlash == false` and `visualResponseMode != .off`, set `visualResponseMode = .off`
   - Delete the legacy key
4. **Update `ImpactController.shouldBeEnabled`** to read `settings.visualResponseMode != .off` directly instead of `settings.screenFlash`.
5. **Remove the `onChange` sync** from `MenuBarView` since there's now nothing to sync.
6. **Remove `Key.screenFlash`** from `SettingsStore.Key` enum.

**Files touched**: `Sources/YameteApp/SettingsStore.swift`, `Sources/YameteApp/ImpactController.swift`, `Sources/YameteApp/Views/MenuBarView.swift`

---

## Medium #5 — Notification cleanup timing overstatement

**Symptoms**
- User-facing help strings claim the notification "clears when the cooldown ends"
- `NotificationResponder.cleanupTask` at `Sources/ResponseKit/NotificationResponder.swift:83-90` only calls `removeDeliveredNotifications` / `removePendingNotificationRequests`
- macOS Notification Center controls when a displayed banner actually disappears; our cleanup removes from the NC list but cannot force-hide a currently-visible banner
- No tests for `NotificationResponder` exist under `Tests/`

**Plan**
1. **Soften the copy** in `App/Resources/en.lproj/Localizable.strings:47` and `:184`. New copy:
   > "Posts a notification when an impact is detected. The notification is removed from Notification Center after the cooldown."
   (propagate to all 40 locales, or keep en.lproj only and rely on dev-region fallback)
2. **Add tests** under `Tests/NotificationResponderTests.swift`:
   - Locale fallback: unknown localeID falls back to `en`
   - Locale fallback: locale with moan but no title falls back to `en` for the whole notification (the resolveLocale unified path)
   - `NotificationPhrase` pool loading: en has 20 keys per pool, count matches file contents
   - `NotificationPhrase.resolveLocale` unit tests
3. **Optional**: add an integration test that mocks `UNUserNotificationCenter` and verifies `removeDeliveredNotifications` is called after `dismissAfter`.

**Files touched**: `App/Resources/**/Localizable.strings`, `Tests/NotificationResponderTests.swift` (new)

---

## Medium #6 — `FaceRenderer.loadFaces()` on every impact (hot path)

**Symptoms**
- `ImpactController.respond()` at line 196 calls `FaceRenderer.loadFaces().randomElement()` per event
- `loadFaces()` re-enumerates bundle resources, re-reads 11 SVG files, re-resolves templates with the current palette on every call
- Main-actor hitching possible on rapid impact sequences

**Plan**
1. **Cache in `ImpactController`**: add a `reactionFaceCache: [NSImage]` property, populated on init and whenever appearance changes.
2. **Appearance change detection**: subscribe to `NSApplication.didChangeScreenParametersNotification` OR observe `NSApp.effectiveAppearance` via KVO, OR rebuild cache whenever `showReactionFace` detects a palette change.
3. Simpler alternative: cache once at init, rebuild in `syncPipelineState()` when the pipeline starts. Face cache is per-pipeline-start; if the user switches dark/light mode mid-pipeline, the faces stay in the old palette until the pipeline restarts. Acceptable trade-off.

**Files touched**: `Sources/YameteApp/ImpactController.swift`, potentially `Sources/ResponseKit/FaceRenderer.swift`

---

## Notes (lower-priority clarity drift)

- `Sources/YameteCore/Domain.swift:65` — `FlashResponder` doc says "screen overlay" protocol; notifications also implement it. **Fix**: rename doc comment to "visual impact response (overlay OR notification)".
- `Sources/YameteApp/ImpactController.swift:16` — pipeline comment says "audio + flash"; should say "audio + visual response (overlay / notification / dock)".
- `docs/APP_STORE_RELEASE.md:16` — more certain than warranted about accelerometer review risk. Soften to "IORegistry driver properties are undocumented; activation may be rejected on review. App degrades gracefully to microphone + headphone motion if accelerometer activation fails."

---

## Execution order

1. **Blocker #2** (unaligned accel): safest, smallest, pure correctness fix.
2. **Major #4** (dual source of truth): clears the architectural debt so other fixes are cleaner.
3. **Major #3** (visual off): user decision required first, then implement.
4. **Medium #6** (face cache): perf improvement, independent.
5. **Medium #5** (notification copy + tests): doc + tests.
6. **Blocker #1** (App Store metadata + tame copy): requires decision on whether to ship to App Store at all, given guideline 1.1.4 risk.
7. **Notes**: clean up in a final pass.

## User decisions (locked in)

- [x] **Major #3**: Rename the setting to "Flash Mode" (off/overlay/notification). **The menu bar face icon always reacts** (not the dock). The dock icon IS gated by the flash mode and does NOT swap when mode = off. This reverses my earlier incorrect assumption that the dock was the always-on indicator.
- [x] **Blocker #1**: Dual-build. App Store build = tame flirty/playful copy, target rating **12+** (there is no 13+ on the App Store; 12+ is the closest tier that allows "infrequent/mild suggestive themes"). Direct build = full DDLG register unchanged. App Store bundle must have ZERO trace of the kink copy.
- [x] **App Store target**: 12+, flirty & playful. Direct build ships separately (notarized direct download only, not submitted to App Store).

## Dual-build architecture (decision)

**Approach**: separate string files, merged at bundle time based on build flag.

- `App/Resources/{locale}.lproj/Localizable.strings` — shared UI strings + **tame** moan/title pools. Always bundled.
- `App/Resources-Direct/{locale}.lproj/LocalizableDirect.strings` — **spicy** moan/title pools ONLY. Overrides the tame keys when bundled.
- `NotificationPhrase` loads pools from `LocalizableDirect` first (if present), falling back to `Localizable`. In App Store builds, `LocalizableDirect` is never copied into the bundle, so the tame pools in `Localizable` are used.
- `Makefile` target for App Store build: copy only `App/Resources/*.lproj/` into the bundle. Strip the `App/Resources-Direct` tree entirely.
- `Makefile` target for Direct build: copy both trees.

Why not a `#if DIRECT_BUILD` prefix trick? Because the spicy strings would still be present in the App Store binary's `.strings` file, reviewable by Apple. Physical file separation + Makefile filtering is the only way to guarantee the App Store bundle is clean.

**Bundle-level verification gate** (Makefile lint):
```
plutil -p dist/Yamete.app/Contents/Resources/en.lproj/Localizable.strings | grep -qi 'daddy' && exit 1 || true
```
Fail the App Store build if "daddy" appears anywhere in the bundle's strings files.
