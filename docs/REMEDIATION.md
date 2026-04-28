# Yamete — Remediation Plan

Generated from multi-agent audit covering all four SPM modules.  
Execution is wave-ordered: each wave must build clean before the next starts.

---

## Wave 1 — P0 Ship Blockers

Issues that cause immediate user-visible damage, memory corruption, use-after-free, or hardware left in a dirty state.

### T1-A · IOHIDValue CF leak in `writeLED`
**File:** `Sources/ResponseKit/LEDFlash.swift`  
`IOHIDValueCreateWithIntegerValue` returns a `+1`-retained CF object that is never released. At 60 Hz over a 1.5 s pulse that is 90 leaks per reaction.  
**Fix:** `defer { CFRelease(value) }` immediately after creation.

### T1-B · NULL device pointer in `writeLED`
**File:** `Sources/ResponseKit/LEDFlash.swift`  
`IOHIDElementGetDevice` returns nil when the keyboard disconnects mid-animation. The nil pointer is passed unchecked to `IOHIDDeviceSetValue` — undefined behaviour.  
**Fix:** Guard `guard let device = IOHIDElementGetDevice(element) else { return }`.

### T1-C · Use-after-free ordering in `IOHIDDeviceRegisterInputReportCallback` teardown
**File:** `Sources/SensorKit/AccelerometerReader.swift`  
`ctx.invalidate()` must execute after the HID run-loop thread joins, not before. Verify and document the phase ordering with a contract comment.

### T1-D · CFSet / transient probe manager leak
**File:** `Sources/SensorKit/AccelerometerReader.swift`  
`isSPUDevicePresent()` opens a probe `IOHIDManager` and never closes it. Each availability check leaks a kernel manager reference.  
**Fix:** `defer { IOHIDManagerClose(manager, 0) }` in the probe path.

### T1-E · IONotificationPort iterators not released on partial setup
**File:** `Sources/SensorKit/EventSources.swift`  
If the `detachKr` guard fires in USB/Bluetooth/Thunderbolt `start()`, the already-created `attachIterator` leaks.  
**Fix:** `if rawAttachIter != 0 { IOObjectRelease(rawAttachIter) }` before returning on failure.

### T1-F · Unretained IOKit context pointer cleared before callbacks drain
**File:** `Sources/SensorKit/EventSources.swift`  
`passUnretained` context pointers in USB/BT/Thunderbolt sources are cleared in `stop()` while inflight IOKit callbacks may still dereference them.  
**Fix:** Switch to `passRetained` + explicit release after iterator release, matching the accelerometer pattern.

### T1-G · Buffer allocation failure unchecked
**File:** `Sources/SensorKit/AccelerometerReader.swift`  
`UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)` is called without validating `maxSize > 0`. A zero or corrupted property causes a crash in the subsequent `initialize`.  
**Fix:** Guard `maxSize > 0` and add a `precondition` before allocating.

### T2-A · No `applicationWillTerminate` cleanup
**Files:** `Sources/YameteApp/YameteApp.swift`, `Sources/YameteApp/Yamete.swift`  
Output tasks, the sensor pipeline, and the enricher Task are never cancelled on quit. Hardware writes may occur during OS teardown; keyboard brightness is not restored.  
**Fix:** Add `applicationWillTerminate(_:)` calling `yamete.shutdown()`. Implement `public func shutdown()` on `Yamete` that cancels all tasks, stops fusion, and calls `ledFlash.hardResetKB()`.

### T4-A · NSSound deallocated during playback
**File:** `Sources/ResponseKit/AudioPlayer.swift`  
`NSSound` objects go out of scope immediately after `.play()`. Playback is silently truncated.  
**Fix:** Hold sounds in `private var activeSounds: [NSSound]`. Use `NSSound` delegate `sound(_:didFinishPlaying:)` to release them.

### T6-E · IOHIDManager never closed
**File:** `Sources/ResponseKit/LEDFlash.swift`  
The HID manager is opened in `init` but no `deinit` closes it.  
**Fix:** `deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }`.

---

## Wave 2 — P1 Critical Correctness

### T2-B · Keyboard brightness not restored on crash
**File:** `Sources/ResponseKit/LEDFlash.swift`  
On `setKBIdleDimmingSuspended(true)`, write a `kb_dirty` sentinel file containing `kbLaunchLevel`. Delete it in `hardResetKB`. On `LEDFlash.init`, if the sentinel exists, restore brightness before first pulse.

### T3-A · `@unchecked Sendable` masking races on event source fields
**File:** `Sources/SensorKit/EventSources.swift`  
`PowerSource.lastWasOnAC`, `AudioPeripheralSource.knownDevices`, and listener fields are mutated from system callbacks without locks. These classes already operate on the main queue; add `@MainActor` isolation and drop `@unchecked Sendable`.

### T3-B · `Logging.debugEnabled` docstring is wrong
**File:** `Sources/YameteCore/Logging.swift`  
Docstring claims "`@MainActor`-written" but the implementation uses `OSAllocatedUnfairLock` correctly (safe from any actor). Update the docstring only.

### T3-C · `ReactionBus.setEnricher` allows post-bootstrap overwrite
**File:** `Sources/YameteCore/ReactionBus.swift`  
No guard prevents replacing the enricher mid-stream.  
**Fix:** `precondition(self.enricher == nil, "ReactionBus: enricher already set")`.

### T3-D · Enricher blocks `publish()` with no timeout
**File:** `Sources/YameteCore/ReactionBus.swift`  
A hanging enricher freezes all subscribers forever.  
**Fix:** Wrap `await enricher(reaction)` with a 0.5 s timeout using `withTaskGroup`. On timeout, fall back to the default `FiredReaction` and log a warning.

### T5-A · `unsafeBitCast` with no method signature validation
**File:** `Sources/ResponseKit/LEDFlash.swift`  
Wrong parameter count in a C ABI cast causes stack corruption.  
**Fix:** Add `validateMethodSignature(_ m: Method, expectedArgCount: UInt32) -> Bool` using `method_getNumberOfArguments`. Guard every `unsafeBitCast` call site.

### T6-A · `LogStore` swallows all file I/O errors silently
**File:** `Sources/YameteCore/Logging.swift`  
`try?` in directory creation, file creation, and `FileHandle` opening silently kills file logging.  
**Fix:** Replace with `do/catch`; log failures to `os.Logger` directly.

### T6-B · `ReactionToggleMatrix` silent encode/decode failures
**File:** `Sources/YameteApp/EventSettings.swift`  
Returns empty `Data()` / empty matrix on failure with no log.  
**Fix:** `do/catch` + `AppLog.error`.

### T6-C · `SensorActivation.deactivate()` swallows IOKit errors
**File:** `Sources/SensorKit/AccelerometerReader.swift`  
`IORegistryEntrySetCFProperty` return values are discarded.  
**Fix:** Log failures at `.warning` in `#if DIRECT_BUILD`.

### T6-D · `HeadphoneMotionAdapter` probe timeout holds strong self
**File:** `Sources/SensorKit/HeadphoneMotionAdapter.swift`  
Strong self in `asyncAfter` keeps the adapter alive past deallocation; `stopDeviceMotionUpdates` is never called if `self` was expected to be gone.  
**Fix:** Change to `[weak self]` with `guard let self else { return }`.

### T7-A · `Reaction.timestamp` returns new `Date()` on every access
**File:** `Sources/YameteCore/Reaction.swift`, `Sources/YameteCore/ReactionBus.swift`  
Non-impact reactions compute `Date()` fresh each call — the same reaction reports different timestamps across accesses.  
**Fix:** Add `publishedAt: Date` to `FiredReaction`. Set it in `ReactionBus.publish()`. Remove the live-`Date()` from the `Reaction.timestamp` fallback for event reactions.

### T7-B · `faceIndices[i]` crashes when display count changes mid-reaction
**File:** `Sources/YameteCore/FiredReaction.swift`  
Screen count can change between enrichment and rendering.  
**Fix:** Add `public func faceIndex(for screenIndex: Int) -> Int` with a bounds-safe fallback to `faceIndices[0]`. Replace all direct index accesses.

### T8-A · `flashEnabled` / `visualResponseMode` init ordering
**File:** `Sources/YameteApp/SettingsStore.swift`  
Reorder init so `flashEnabled` is assigned immediately after `visualResponseMode`. Add an adjacent comment documenting the sync contract.

### T9-A · Zero test coverage for core recently-written code
**Files:** `Tests/` (new files)  
Create: `LEDFlashTests.swift`, `FiredReactionTests.swift`, `BusEnricherTests.swift`, `EventSourceIntegrationTests.swift`, `ReactionsConfigTests.swift`.

---

## Wave 3 — P1 Remainder

### Verify `Updater` under strict concurrency
`make lint` confirms or surfaces violations. Add a comment confirming URLSession resumes on calling actor.

### `ReactionBus` weak-self subscriber cleanup
Confirm `continuation.onTermination` + Task pattern cannot leak subscribers if `self` is deallocated. Document ownership contract.

### `consensusRequired` clamping is silent
Log when consensus is clamped below user setting due to fewer active sensors.

---

## Wave 4 — P2/P3 Housekeeping

| ID | File | Action |
|---|---|---|
| T7-C | `ReactionsConfig.swift` | Unit test: every `ReactionKind` has an `eventIntensity` entry |
| T10-A | `OutputConfig.swift` | `reactionDuration` → `internal` |
| T10-B | `ReactionBus.swift` | Add `public typealias ReactionEnricher` |
| T10-C | `SingleSlider.swift` | Remove dead `@State var doubleValue` |
| T10-D | `ScreenFlash.swift` | Remove unused `dismissAfter` parameter |
| T10-E | `AudioPlayer.swift` | Extract duplicate `recentlyPlayed` update to `private func recordPlayed(_:)` |
| T10-F | `Yamete.swift`, `Reaction.swift`, `FaceLibrary.swift` | Remove stale/past-tense docstrings |
| T10-G | `OutputConfig.swift` | Document `OutputConfigProvider` preconditions |
| T10-H | `SensorAdapter.swift` | Introduce `EventSource` protocol, separate from `SensorSource` |
| T11-A | CI workflow | `lint-frameworks` as standalone CI step |
| T11-B | CI workflow | Upload test artifacts on failure |
| Debounce | `EventSources.swift` | Read debounce windows from `ReactionsConfig`, not hardcoded |
| Naming | `OutputConfig.swift`, `ImpactDetection.swift` | Unify config struct naming convention |
