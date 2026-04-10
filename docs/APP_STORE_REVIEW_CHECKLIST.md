# App Store Review Checklist and Decision Record

Last updated: 2026-04-09
Scope: publish-readiness planning only, no code changes

## How to use this document

This is a working release record, not just a TODO list.

- Use the checkboxes to track completion.
- Use the "Decision" lines where a product or engineering choice is required.
- Use the "Notes" blocks to capture rationale, review feedback, or unresolved concerns.
- Keep this document aligned with the actual App Store metadata, review notes, and shipped feature set.

## Current evidence snapshot

Confirmed locally:

- `swift test` passes.
- `swift test --sanitize=thread` passes.
- `xcodebuild -project Yamete.xcodeproj -scheme Yamete-AppStore -configuration ReleaseAppStore CODE_SIGNING_ALLOWED=NO build` passes.
- The public site, privacy page, and support page return HTTP `200`.

Confirmed issues:

- The notification copy and string comments are sexually suggestive, while the App Store metadata currently declares `4+`, `Sexual Content: None`, and `Mature/Suggestive Themes: None`.
  Current Apple age-rating guidance indicates:
  - `13+` covers infrequent sexual content or nudity.
  - `16+` covers frequent mature or suggestive themes.
  - `18+` covers frequent sexual content or nudity.
  Working assessment:
  The current notification content most likely fits `16+`, not `4+`, and probably not `13+`, because the suggestive material is central and repeatable rather than incidental.
- The accelerometer implementation uses public IOKit functions but still depends on undocumented driver names and registry keys.
  Confirmed undocumented pieces in the current code:
  - Driver class name: `AppleSPUHIDDriver`
  - Property keys: `ReportInterval`, `SensorPropertyReportingState`, `SensorPropertyPowerState`
  These appear in `Sources/SensorKit/AccelerometerReader.swift` and are not surfaced as documented public APIs in the SDK headers.
- The visual-response state model currently has two sources of truth: `screenFlash` and `visualResponseMode`.
- ~~The responder abstraction is now semantically inaccurate: `FlashResponder` is no longer only for screen flashes.~~ ✓ Resolved: renamed to `VisualResponder` in `Sources/YameteCore/Domain.swift`.
- The codebase is not strict-concurrency clean under `-strict-concurrency=complete`.
- The HID teardown path is plausible but not yet proven safe at callback shutdown boundaries.

Working decisions from notes:

- Keep accelerometer support as a flagship feature target for the App Store path if a defensible public/documented story can be established, or if the remaining risk is clearly documented and consciously accepted.
- Tone down notification strings for App Store compatibility and re-review all locales.
- Move to one source of truth for visual-response state.
- Rename the responder abstraction to match current behavior.
- Treat strict-concurrency cleanliness as required, not optional.
- Treat HID teardown hardening as required, not optional.

## Decision 1: Accelerometer App Store strategy

### Option A: Ship the current accelerometer path to the App Store

Description:
Keep the current App Store build behavior. Continue using the undocumented `AppleSPUHIDDriver` + property-key activation path, while documenting it honestly in review notes.

Pros:

- One runtime behavior across direct and App Store builds.
- Preserves the headline feature on Apple silicon MacBooks.
- No capability split or App Store-specific fallback logic.

Cons:

- Review outcome is uncertain under App Review 2.5.1 because the implementation depends on undocumented driver details even though the imported symbols are public.
  What that means:
  Apple’s current published rules require documented/public APIs for App Store software. The code imports public IOKit functions, but the specific driver class and property keys used to activate the sensor are not documented SDK surface. So the implementation is not using private symbols, but it is still relying on undocumented behavior.
- This likely increases scrutiny on entitlements, review notes, and testing instructions.
- Any rejection will land late in the release path.

Use this option if:

- Shipping full accelerometer support in the App Store is more important than review predictability.
- You are willing to accept rejection risk and iterate with App Review.

Apple-documented submission consequence:

- Rejected items can be edited and resubmitted, or removed from the submission.
- I found no official Apple documentation describing a strike system or formal penalty for a rejected submission.
- The practical cost is delay, review churn, and potentially more scrutiny on subsequent submissions.

Required if chosen:

- [ ] Rewrite release docs and review notes to describe the risk honestly.
- [ ] Keep microphone-only graceful degradation explicit and testable.
- [ ] Remove any claim that the review risk is "resolved" or "low."
- [ ] Exhaustively research whether a fully documented/public macOS accelerometer path exists before accepting the undocumented-driver dependency.
- [ ] Build a reviewer-ready test plan and evidence package for accelerometer behavior, entitlement usage, and fallback paths.

Assessment:
Viable, but not the safest publishing strategy.

Decision:

- [ ] Choose Option A
- [ ] Reject Option A
- [x] Current working direction: investigate and pursue Option A, but only with a stronger public-API analysis and materially better review preparation.

Notes:

-
-

### Option B: Disable accelerometer in the Mac App Store build, keep it in direct builds

Description:
Treat the accelerometer as a direct-distribution capability and ship the App Store build with microphone and headphone-motion only.

Pros:

- Best path for App Store predictability.
- Removes the undocumented-driver story from the review-critical binary.
- Makes the App Store review notes much simpler.

Cons:

- Product split between direct and App Store builds.
- Marketing copy, screenshots, onboarding, and support docs must clearly differentiate capabilities.
- Requires build-time or runtime capability gating.

Use this option if:

- The primary goal is successful App Store distribution with reduced review friction.
- You are willing to maintain a real capability split between distribution lanes.

Required if chosen:

- [ ] Define App Store capability surface explicitly.
- [ ] Remove accelerometer claims from App Store metadata and screenshots.
- [ ] Add tests to ensure the App Store target cannot accidentally re-enable accelerometer behavior.

Assessment:
Best option if App Store approval probability is the main goal.

Decision:

- [ ] Choose Option B
- [x] Reject Option B for now

Notes:

-
-

### Option C: Delay App Store submission until the accelerometer path is replaced or better justified

Description:
Pause App Store submission and keep shipping direct builds only until the accelerometer review story is materially improved.

Pros:

- Avoids submitting with a known review gray area.
- Keeps product behavior consistent in the meantime.
- Buys time to harden architecture and documentation properly.

Cons:

- Delays App Store release.
- Does not itself reduce engineering risk unless the time is used well.

Use this option if:

- You do not want to maintain split capability lanes.
- You are not comfortable submitting with undocumented-driver dependencies.

Required if chosen:

- [ ] Set an explicit reevaluation milestone.
- [ ] Document the decision so it does not become indefinite drift.

Assessment:
Cleanest for product integrity, worst for timeline.

Decision:

- [ ] Choose Option C
- [ ] Reject Option C

Notes:

-
-

## Decision 2: Notification content and age-rating strategy

### Option A: Keep the current suggestive notification tone

Pros:

- Preserves the intended voice of the app.
- No product-tone redesign.

Cons:

- Forces metadata, age-rating, and content-rating answers to change.
- Increases App Review scrutiny and narrows audience positioning.
- May create mismatch with current site and support framing.

Required if chosen:

- [ ] Rework App Store metadata to match actual content.
- [ ] Re-answer content-rating questions honestly.
- [ ] Review all locales, not just English.

Assessment:
Possible, but materially changes the submission posture.

Decision:

- [ ] Choose Option A
- [ ] Reject Option A

Notes:

-
-

### Option B: Tone down notification strings for App Store compatibility

Pros:

- Simplifies age-rating and metadata alignment.
- Reduces review risk immediately.
- Easier to explain publicly and translate consistently.

Cons:

- Changes part of the app’s personality.
- Requires coordinated copy edits across 40 locales.

Required if chosen:

- [ ] Rewrite English source strings and translator comments.
- [ ] Re-review all localized variants for tone drift.
- [ ] Align site copy and support docs.

Assessment:
Best option if App Store distribution is the priority.

Decision:

- [x] Choose Option B
- [ ] Reject Option B

Notes:

-
-

## Engineering checklist

### 1. Publish blockers

- [ ] Resolve the mismatch between notification content and App Store content rating.
  Notes:

  -
  -

- [ ] Reframe the accelerometer risk in [APP_STORE_RELEASE.md](./APP_STORE_RELEASE.md) and [APP_STORE_METADATA.md](./APP_STORE_METADATA.md) so the wording matches the actual uncertainty and distinguishes public symbols from undocumented behavior.
  Notes:

  -
  -

- [ ] Ensure the App Store metadata describes the actual shipped response modes and capability surface.
  Notes:

  -
  -

### 2. State-model cleanup

- [ ] Remove `screenFlash` as an independent long-term source of truth.
  Why this matters:
  `screenFlash` and `visualResponseMode` currently encode overlapping state and are only synchronized from the UI layer.
  Working direction:
  keep any legacy `screenFlash` support only as a migration input, then converge on a single persisted response-settings model.
  Notes:

  -
  -

- [ ] Define a single source of truth for visual-response enablement.
  Working direction:
  use a richer response-settings model instead of a single enum, so `overlay` and `notification` can be independently toggleable.
  Candidate shape:
  `visualResponses = { overlayEnabled, notificationEnabled }`
  plus a separate always-on reaction class for menu bar / dock face feedback.
  Notes:

  -
  -

- [ ] Define whether menu bar / dock face reactions are part of "visual response" or a separate reaction class.
  Why this matters:
  Today "Visual Response: Off" still permits menu bar and dock icon changes.
  Working direction:
  menu bar and dock reactions should remain active as baseline app feedback; overlay and notification should be optional supplemental responses.
  Notes:

  -
  -

### 3. API and abstraction cleanup

- [x] Replace or rename `FlashResponder` so the protocol matches current responsibilities. → renamed to `VisualResponder`.
  Options:
  - Rename to something neutral like `VisualResponder`.
  - Replace the long parameter list with a typed request/context object.
  - Keep overlay and notification as separate protocols if the inputs diverge further.
  Working direction:
  rename it and move toward a typed request object.
  Notes:

  -
  -

- [ ] Update stale comments in core control-flow and protocol definitions.
  Minimum scope:
  - `Sources/YameteCore/Domain.swift`
  - `Sources/YameteApp/ImpactController.swift`
  - release docs that still describe only "audio + flash"
  Notes:

  -
  -

### 4. Concurrency and type-safety hardening

- [ ] Make the codebase clean under `-strict-concurrency=complete`.
  Confirmed warning areas:
  - `OnceCleanup<T>` generic sendability
  - `LogStore.State`
  - `FaceRenderer.Palette`
  - `FaceRenderer.currentPalette` reading `NSApp`
  - static formatter closures in `MenuBarView`
  Notes:

  -
  -

- [ ] Decide whether AppKit-touching rendering helpers should be explicitly `MainActor`.
  Why this matters:
  `NSApp` is UI-actor-isolated in the SDK, and the current helpers rely on that implicitly.
  Notes:

  -
  -

- [ ] Add a CI or local verification target that runs strict-concurrency checking, even if warnings are initially allowed.
  Working direction:
  warnings should not remain indefinitely; use the verification target to drive cleanup to zero.
  Notes:

  -
  -

### 5. Memory-safety and HID lifecycle hardening

- [ ] Replace unaligned `withMemoryRebound` reads in the accelerometer report decoder with an unaligned-safe decode strategy.
  Why this matters:
  The current byte offsets are not 4-byte aligned.
  Notes:

  -
  -

- [ ] Decide whether to keep the run-loop HID lifecycle or move to the documented dispatch-queue activation/cancel model.
  Option A:
  Keep the run-loop path, add explicit shutdown coordination and tests.
  Option B:
  Migrate to `IOHIDManagerSetDispatchQueue` / `IOHIDManagerActivate` / cancel-handler style lifecycle.
  Working direction:
  prefer the documented dispatch-queue lifecycle if it can support the same behavior cleanly.
  Notes:

  -
  -

- [ ] Add a focused teardown stress test for repeated open/close cycles of the accelerometer stream.
  Goal:
  Catch callback-after-free style failures that unit tests and TSAN may miss in shallow runs.
  Notes:

  -
  -

### 6. Notification behavior and copy accuracy

- [ ] Decide whether notification mode should promise "cleanup from Notification Center" or "banner disappears."
  Why this matters:
  Apple documents delivered-notification removal from Notification Center, not exact live-banner dismissal timing.
  Working direction:
  promise Notification Center cleanup, not exact banner-dismiss timing.
  Notes:

  -
  -

- [ ] Add direct tests for notification locale resolution, fallback behavior, and replacement/cleanup behavior.
  Notes:

  -
  -

- [ ] Review translator comments for tone, clarity, and maintainability.
  Rule:
  Comments should explain intent and constraints without becoming editorial, sexualized, or overprescriptive.
  Working direction:
  keep comments brief, behavioral, and translator-oriented.
  Notes:

  -
  -

### 7. Documentation and site alignment

- [ ] Align site copy, privacy/support pages, and App Store metadata with the chosen accelerometer and notification strategy.
  Notes:

  -
  -

- [ ] Remove any sentence that presents review-sensitive behavior as settled fact when it is really a risk-managed choice.
  Notes:

  -
  -

- [ ] Keep the docs factual, concise, and reviewer-oriented.
  Avoid:
  - overclaiming safety
  - oversimplifying technical caveats
  - translator instructions that read like fan-fiction instead of localization guidance
  Notes:

  -
  -

## Final go/no-go sign-off

Product decision:

- [ ] We are comfortable with the App Store capability surface.
- [ ] We are comfortable with the toned-down notification tone and resulting age rating.
- [ ] We are comfortable with the accelerometer review risk.

Engineering decision:

- [ ] State model is coherent.
- [ ] Concurrency warnings are addressed or consciously waived.
- [ ] Memory-safety hazards are addressed or consciously waived.
- [ ] Release docs match the shipped app.

Submission decision:

- [ ] Go
- [ ] No-go

Decision owner:

-

Date:

-

Final notes:

-
-
