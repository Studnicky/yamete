---
title: Testing
description: Every ring of the test pyramid Yamete drives in anger.
---

# Testing

*Every layer, every gate, every reasonable input. The whole point is that an embarrassingly silly app gets an embarrassingly serious test apparatus.*

The test suite is organised as concentric rings, each driving the production code from one layer further out than the previous. Failures isolate to the ring that broke.

        
| Ring / Layer | Files | What it asserts |
|---|---|---|
| Ring 0. bus contract | BusRoutingContractTests.swift | Bus fan-out, enricher, gate matrix in isolation. Drives _testEmit straight to the bus, no source detection. |
| Ring 1. source detection (mocked transport) | Matrix*OSEvents_Tests.swift, Matrix*Source_Tests.swift, StimulusSourceContractTests.swift | Per-source detection pipeline driven through internal seams (_inject*, _injectKeyPress, _injectClick). MockEventMonitor / MockHIDDeviceMonitor stand in for the OS. |
| Ring 2. real OS event tap | MatrixL2_Trackpad_Tests.swift, MatrixL2_Mouse_Tests.swift, MatrixL2_Keyboard_Tests.swift, MatrixL2_System_*_Tests.swift | Same assertions, but synthesised events go through CGEvent.post / NSWorkspace / NotificationCenter so RealEventMonitor and friends fire end-to-end. Cells XCTSkip cleanly when Accessibility/Input-Monitoring TCC is denied. |
| Ring 3. host-app bundle | make test-host-app (xcodebuild scheme YameteHostTest) | Same suite but run inside Yamete.app's real bundle so UNUserNotificationCenter, RealHapticEngineDriver, real Accessibility paths execute. |
| Cross-source conflation | MatrixCrossSourceConflation_Tests.swift, MatrixDeviceAttribution_Tests.swift | Trackpad/mouse/keyboard event-tap conflation regression suite. Catches the kind of bug where one external mouse click would be credited to BOTH MouseActivitySource and TrackpadActivitySource. |
| Concurrent / interleaved fuzz | MatrixConcurrentInterleaved_Tests.swift, CrossBoundaryFaultInjection_Tests.swift | 2+ sources publishing simultaneously under deterministic seeds; cross-boundary kernel-failure injection (USB-fail-during-BT-fail, sleep-mid-tap, IOHID-register-flood-with-listener-fault, etc.). |
| Property-based | PropertyBased_Tests.swift | 8 invariants × 200 deterministic xorshift64 seeds = 1600 cases. Asserts rate-debounce bounds, RMS thresholding, attribution gates, bus delivery order/completeness, coalesce monotonicity, per-mode enable invariants for every random input in the property's domain. |
| State machines | StateMachine_Tests.swift | Exhaustive transition graphs for ProbeStage, ImpactFusion, ReactionBus, OnceCleanup, TrackpadActivitySource. Asserts every reachable transition AND that every illegal transition is rejected (terminal states stay terminal, no-op gates fire). |
| Real-vs-Mock parity | DriverParity_Tests.swift | Every driver protocol's RealXxxDriver and MockXxxDriver assert the same observable contract on the same input shape. Catches Real-vs-Mock divergence that would cause production-only bugs. |
| Snapshot UI (4 variants) | SnapshotUI_Tests.swift, SnapshotUI_Direct_Tests.swift | SwiftUI views rendered into NSHostingView and pixel-compared (precision 0.99, perceptualPrecision 0.98). Per-build baselines: __Snapshots__/AppStore/, Direct/, HostApp/, CI/. |
| Locale rendering | LocaleRendering_Tests.swift | 40 locales × 4 plural axes (count=0/1/2/many) + Polish 4-category sweep + RTL glyph assertions + date / numeric format rendering. Catches stringsdict regressions per CLDR rules. |
| Settings corruption fuzz | SettingsFuzz_Tests.swift | 200-trial random plist fuzz: empty / type-mismatch / truncated / NaN / future-version / NSKeyedUnarchiver malicious input. Pins SettingsStore's sanitize-non-finite-and-pairings pass. |
| Crash boundary audit | CrashHandling_Tests.swift | Arithmetic-trap audit: mach_absolute_time wraparound, atan2(0,0) NaN propagation, zero-frame buffers, divide-by-zero, integer overflow, closed-bus publish, UInt64.max staleness. |
| Performance baselines | Performance_Tests.swift, Tests/Performance/baselines.json | 7 cells with absolute wallclock + memory baselines committed to the repo. make perf-baseline compares each run against the baseline within a 2× tolerance and fails on regression. |
| Mutation testing | Tests/Mutation/mutation-catalog.json, scripts/mutation-test.sh | 130 declarative mutation entries (search/replace pair + expected failing test + substring anchor). make mutate applies each mutation, runs swift test --filter, asserts non-zero exit + substring match, then reverts. make mutate-pr slices the catalog to entries whose targetFile the PR touched (~1-2 min on a typical PR vs ~20 min for the full catalog). The --coverage flag enumerates un-mutated production gates as a punch-list. |

        
Local headline: `swift test` 818 passing / 37 skipped / 0 failures · `make lint` strict-concurrency clean · `make mutate` 130/130 caught · `make test-host-app` 818 / 40 / 0 · `make perf-baseline` 7/7 within tolerance. As of v2.1.1.
