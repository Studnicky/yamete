#if canImport(YameteCore)
import YameteCore
#endif
#if canImport(ResponseKit)
import ResponseKit
#endif
import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import YameteApp

/// Pixel-baseline snapshots for the menu UI.
///
/// Closes the gap left by `MatrixAccordionExpansionSize_Tests` (which only
/// asserts intrinsicContentSize numbers) and `MatrixViewLabelCoverage_Tests`
/// (which only checks string presence): a regression in `AccordionCard`
/// row-height geometry, `PillButton` framing, or accordion expand/collapse
/// layout would render visually different but pass every existing test.
/// These cells render real views into `NSHostingView`, capture the bitmap
/// via `SnapshotTesting.image`, and compare to a committed baseline.
///
/// ## Determinism strategy
///
/// SwiftUI/AppKit pixel rendering is host-sensitive (font hinting, retina
/// backing scale, system-symbol antialiasing). To keep baselines reproducible
/// across hosts:
///
/// 1. **Locale**: cells that render whole `Section` views accept whatever
///    the host's preferred localization is — these are skipped on non-`en`
///    hosts via `XCTSkipUnless`. Cells that render synthetic content
///    (AccordionCard, palette swatches) inject literal English titles.
/// 2. **Date**: no view in scope formats a `Date()`, so no clock pinning is
///    needed. `MenuBarFace.impactCount` defaults to `0` and is only mutated
///    by `recordCount(at:)`, which the snapshot fixtures never call.
/// 3. **System fonts**: `precision: 0.99` and `perceptualPrecision: 0.98`
///    tolerate sub-pixel hinting drift between Sonoma / Sequoia / Tahoe
///    without losing layout regressions (the AccordionCard row-height bug
///    class shifts pixels by ≥ 4pt — well outside the perceptual band).
/// 4. **Color schemes**: rendered explicitly via `.preferredColorScheme(.light)`
///    / `.dark`. The host's appearance is not consulted.
/// 5. **NSScreen / NSApplication**: cells that need a real `NSApplication`
///    or unbundled `Bundle.main` data (FooterSection's update line in
///    DIRECT_BUILD) are skipped via `XCTSkip` rather than rendered against
///    a stub.
///
/// ## Cell index
///
/// 1. headerSectionDefault — light + dark
/// 2. deviceSectionEmptyCollapsed — wrapped in AccordionCard with isExpanded=false
/// 3. deviceSectionEmptyExpanded — wrapped in AccordionCard with isExpanded=true
/// 4. trackpadTuningSectionExpanded — light + dark
/// 5. responseSectionAllCollapsed — light + dark (covers the 4 always-on
///    SensorAccordionCards rendered as the canonical home of `PillButton`-
///    shaped matrix toggles after the StimuliSection refactor)
/// 6. footerSection — App Store build only (DIRECT_BUILD skipped, see cell)
/// 7. accordionCardWithRows — 1 / 3 / 5 / 7 rows; pins
///    `animationDuration(forRows:)`'s height-scaled formula
/// 8. themeColorPaletteSwatches — every named Theme color in declaration order
@MainActor
final class SnapshotUI_Tests: XCTestCase {

    // MARK: - Configuration

    /// Pixel precision tolerates anti-aliasing drift between minor macOS
    /// versions; perceptualPrecision tolerates LCD subpixel hinting.
    /// Layout regressions (the classes this suite targets) shift well past
    /// these thresholds.
    private static let imagePrecision: Float = 0.99
    private static let perceptualPrecision: Float = 0.98

    /// Set this to `.all` and run once locally to (re)record every baseline.
    /// Commit the resulting `__Snapshots__/` directory and revert this back
    /// to `.missing` before pushing.
    private static let recordMode: SnapshotTestingConfiguration.Record = .missing

    /// Per-build-variant snapshot directory.
    ///
    /// Phase 3 split: shared cells render subtly differently under
    /// `DIRECT_BUILD` (e.g. `FooterSection`'s right column composes a
    /// version + chevron pill instead of skipping, `ResponseSection`'s
    /// audio card surfaces a Direct-only `EnableToggleRow`). To keep
    /// both builds covered by pixel-baselines without one variant
    /// overwriting the other's, baselines live in build-variant
    /// subdirectories under `__Snapshots__/`.
    ///
    /// Phase 1 host-app extension: a third dimension also affects pixel
    /// output — whether tests run under the SPM `xctest` runner (where
    /// `Bundle.main` is the runner and SwiftUI bundle assets fall back to
    /// defaults) versus inside `Yamete.app` / `Yamete Direct.app` host
    /// (where the real bundle assets render in). Detect the host bundle
    /// via `Bundle.main.bundleURL` and route to a `HostApp` variant
    /// directory in either case so the SPM and host-app baselines do
    /// not overwrite each other.
    ///
    /// `#filePath` resolves to the absolute path of this test file at
    /// compile time. We strip the file basename and append the variant
    /// directory + the test class's snapshot subdirectory.
    ///
    /// Sandbox handling: under host-app the YameteHostTest bundle inherits
    /// `Yamete.app`'s App Store sandbox, which forbids writes outside the
    /// container. The SnapshotTesting library always writes new baselines
    /// to the snapshot directory at first record, so a source-tree path
    /// trips a Cocoa "permission to save" error. We seed the writable
    /// `NSTemporaryDirectory()` path on first call by copying any
    /// committed `Tests/__Snapshots__/HostApp/SnapshotUI_Tests/*.png`
    /// baselines (sandbox CAN read out-of-container paths via the
    /// debug configuration's POSIX-permission grant) into the temp
    /// directory — subsequent reads/writes flow through the temp path
    /// inside the container's allow-list. The committed PNGs in the
    /// source tree remain the canonical baselines and are surfaced via
    /// the seed step. After re-recording, a one-time
    /// `make snapshot-sync-host-app` copies the newly-rendered PNGs back
    /// into the source tree for commit.
    private static func snapshotDirectory(filePath: StaticString) -> String {
        let variant = Self.snapshotVariant()
        let testFileURL = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
        let testsDir = testFileURL.deletingLastPathComponent()
        let sourceTreeDir = testsDir
            .appendingPathComponent("__Snapshots__")
            .appendingPathComponent(variant)
            .appendingPathComponent("SnapshotUI_Tests")
        guard variant == "HostApp" else { return sourceTreeDir.path }
        return Self.sandboxSeededDirectory(sourceTreeDir: sourceTreeDir,
                                           leaf: "SnapshotUI_Tests")
    }

    /// Seeds a sandbox-writable mirror of the source-tree snapshot
    /// directory under `NSTemporaryDirectory()` on first call, then
    /// returns its path so the SnapshotTesting library can read AND
    /// write through it. Idempotent: re-running the test re-syncs
    /// committed baselines from the source tree (read-only OK from
    /// sandbox) so changes to committed baselines are honoured on the
    /// next run.
    static func sandboxSeededDirectory(sourceTreeDir: URL, leaf: String) -> String {
        let mirror = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("yamete-snapshots", isDirectory: true)
            .appendingPathComponent("HostApp", isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        // Seed: copy every committed baseline from source tree into the
        // writable mirror. `copyItem` errors on existing destinations, so
        // remove first. Read access from the sandbox to the source tree
        // path goes through the Debug build's POSIX file-access grant
        // (the source tree is owned by the developer running the test
        // and macOS's App Sandbox honours plain POSIX read for
        // out-of-container paths even when the entitlement is set).
        if let baselines = try? fm.contentsOfDirectory(at: sourceTreeDir,
                                                      includingPropertiesForKeys: nil) {
            for source in baselines {
                let dst = mirror.appendingPathComponent(source.lastPathComponent)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: source, to: dst)
            }
        }
        return mirror.path
    }

    /// Resolves the active snapshot-variant directory:
    ///   * `HostApp` — running inside `Yamete.app` or `Yamete Direct.app`
    ///     (host-app xcodebuild test). Detected by `bundleURL` containing
    ///     the host app bundle name.
    ///   * `CI` — running on a GitHub Actions runner (detected via the
    ///     `CI=true` env var GitHub Actions sets on every job). The
    ///     macos-15 runner image renders AppKit views with subtly
    ///     different antialiasing / font metrics than developer hosts,
    ///     so a separate baseline directory is necessary or every CI
    ///     run flags every snapshot. Seeded once via
    ///     `.github/workflows/snapshot-baseline-seed.yml`.
    ///   * `Direct` — `DIRECT_BUILD` SPM build (Direct-only cells active).
    ///   * `AppStore` — default SPM `xctest` runner.
    /// The host-app branch wins over compile-time variants because the
    /// host-app target is built without `DIRECT_BUILD` (the YameteHostTest
    /// scheme links the App Store-flavoured `Yamete.app`); both lanes
    /// are nevertheless distinct from a plain SPM run because real
    /// bundle assets render in. The CI branch wins over the AppStore /
    /// Direct split because runner-vs-developer-host pixel drift is the
    /// dominant baseline failure mode on CI; the CI directory is itself
    /// recorded under either AppStore or Direct semantics depending on
    /// which job lane recorded it (the seed workflow runs both filters,
    /// so both lanes' baselines land in the same `CI/` subtree).
    static func snapshotVariant() -> String {
        let bundlePath = Bundle.main.bundleURL.path
        if bundlePath.contains("Yamete.app") || bundlePath.contains("Yamete Direct.app") {
            return "HostApp"
        }
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            return "CI"
        }
        #if DIRECT_BUILD
        return "Direct"
        #else
        return "AppStore"
        #endif
    }

    private func assertImageSnapshot<V: View>(
        of view: V,
        named name: String? = nil,
        size: CGSize,
        filePath: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        // Baselines land at
        // `Tests/__Snapshots__/{AppStore,Direct}/SnapshotUI_Tests/*.png`
        // depending on whether `DIRECT_BUILD` is defined at compile
        // time (see `snapshotDirectory(filePath:)`). The library's
        // default `__Snapshots__/<class>/` layout next to the test
        // file would clobber one variant's baselines with the other's.
        withSnapshotTesting(record: Self.recordMode) {
            let failure = verifySnapshot(
                of: host as NSView,
                as: .image(
                    precision: Self.imagePrecision,
                    perceptualPrecision: Self.perceptualPrecision,
                    size: size
                ),
                named: name,
                snapshotDirectory: Self.snapshotDirectory(filePath: filePath),
                file: filePath,
                testName: testName,
                line: line
            )
            if let message = failure {
                XCTFail(message, file: filePath, line: line)
            }
        }
    }

    /// Skip when the host's preferred localization is not English. Localized
    /// glyph widths (umlauts, CJK) shift layout enough to invalidate
    /// English-baseline pixel comparisons.
    private func skipIfNonEnglishLocale() throws {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        try XCTSkipUnless(lang.hasPrefix("en"),
            "snapshot baselines are recorded under English; preferred=\(lang)")
    }

    // MARK: - Cell 1: HeaderSection default state

    /// HeaderSection renders the app title, tagline, and a "paused" capsule
    /// when `yamete.fusion.isRunning == false`. A fresh `Yamete` has
    /// `fusion.isRunning == false` so the capsule is captured.
    func test_cell_headerSection_lightScheme() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_headerSection_lightScheme.1.png"]
        )
        let settings = SettingsStore()
        let yamete = Yamete(settings: settings)
        let face = MenuBarFace()
        let view = HeaderSection()
            .environment(yamete)
            .environment(face)
            .environment(settings)
            .frame(width: Theme.twoColumnMenuWidth, height: 80)
            .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.twoColumnMenuWidth, height: 80))
    }

    func test_cell_headerSection_darkScheme() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_headerSection_darkScheme.1.png"]
        )
        let settings = SettingsStore()
        let yamete = Yamete(settings: settings)
        let face = MenuBarFace()
        let view = HeaderSection()
            .environment(yamete)
            .environment(face)
            .environment(settings)
            .frame(width: Theme.twoColumnMenuWidth, height: 80)
            .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.twoColumnMenuWidth, height: 80))
    }

    // MARK: - Cell 2 + 3: DeviceSection collapsed / expanded
    //
    // DeviceSection is not itself a collapsible (it has no isExpanded knob);
    // it lives as direct VStack content in the menu. To exercise the
    // accordion expand/collapse layout for this section we wrap it in an
    // `AccordionCard` with the appropriate binding.

    /// DeviceSection wrapped in a collapsed AccordionCard — body is hidden,
    /// only the header bar contributes to the bitmap.
    func test_cell_deviceSection_collapsed() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_deviceSection_collapsed.1.png"]
        )
        let settings = SettingsStore()
        let view = AccordionCard(
            title: "Devices",
            isExpanded: .constant(false)
        ) {
            DeviceSection(audioDevices: [], displays: [])
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 60)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 60))
    }

    /// DeviceSection wrapped in an expanded AccordionCard — locks the layout
    /// dimensions of the empty-list rendering (no audio devices, no extra
    /// displays) so a regression in DeviceToggleList's empty-state row
    /// height shows up immediately.
    func test_cell_deviceSection_expanded() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_deviceSection_expanded.1.png"]
        )
        let settings = SettingsStore()
        let view = AccordionCard(
            title: "Devices",
            isExpanded: .constant(true)
        ) {
            DeviceSection(audioDevices: [], displays: [])
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 240)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 240))
    }

    // MARK: - Cell 4: TrackpadTuningSection expanded

    /// TrackpadTuningSection is itself an AccordionCard. Its private
    /// `@State isExpanded` defaults to `false`, so to capture the expanded
    /// layout we render `TrackpadTuningContent` (the body extracted by
    /// production for exactly this kind of reuse) directly inside an
    /// AccordionCard with isExpanded=true.
    func test_cell_trackpadTuning_expanded_lightScheme() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_trackpadTuning_expanded_lightScheme.1.png"]
        )
        let settings = SettingsStore()
        let view = AccordionCard(
            title: "Trackpad Tuning",
            contentRowCount: 12,
            isExpanded: .constant(true)
        ) {
            TrackpadTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 460)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 460))
    }

    func test_cell_trackpadTuning_expanded_darkScheme() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_trackpadTuning_expanded_darkScheme.1.png"]
        )
        let settings = SettingsStore()
        let view = AccordionCard(
            title: "Trackpad Tuning",
            contentRowCount: 12,
            isExpanded: .constant(true)
        ) {
            TrackpadTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 460)
        .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 460))
    }

    // MARK: - Cell 5: ResponseSection (SensorAccordionCard grid)
    //
    // ResponseSection composes 4–7 SensorAccordionCards (audio, flash,
    // notifications, keyboard LED, optionally haptic / brightness / tint).
    // This is where `PillButton`-styled matrix toggles render in production
    // (per-output × per-reaction grid). Snapshot exercises the multi-card
    // accordion stack and the inline `themeMiniSwitch` toggle ring.

    func test_cell_responseSection_lightScheme() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_responseSection_lightScheme.1.png"]
        )
        let settings = SettingsStore()
        let yamete = Yamete(settings: settings)
        // Drive every optional-output flag false so the cell rendering is
        // host-independent (haptic / brightness / tint cards omit themselves).
        yamete._testSetHardwarePresence(
            haptic: false,
            displayBrightness: false,
            keyboardBacklight: false,
            trackpad: false,
            mouse: false,
            keyboard: false
        )
        let view = ResponseSection()
            .environment(settings)
            .environment(yamete)
            .frame(width: Theme.menuWidth, height: 280)
            .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 280))
    }

    func test_cell_responseSection_darkScheme() throws {
        try skipIfNonEnglishLocale()
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_responseSection_darkScheme.1.png"]
        )
        let settings = SettingsStore()
        let yamete = Yamete(settings: settings)
        yamete._testSetHardwarePresence(
            haptic: false,
            displayBrightness: false,
            keyboardBacklight: false,
            trackpad: false,
            mouse: false,
            keyboard: false
        )
        let view = ResponseSection()
            .environment(settings)
            .environment(yamete)
            .frame(width: Theme.menuWidth, height: 280)
            .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 280))
    }

    // MARK: - Cell 6: FooterSection
    //
    // FooterSection reads `SMAppService.mainApp.status` at @State init —
    // outside an .app bundle that returns `.notRegistered` and the call is
    // safe. The view also embeds `Updater`. Under DIRECT_BUILD `Updater`
    // surfaces version + update status from `Bundle.main`, which differs
    // between `swift test` (xctest bundle) and the shipped app, breaking
    // determinism. We snapshot only the App Store build (no DIRECT_BUILD).

    func test_cell_footerSection() throws {
        try skipIfNonEnglishLocale()
        #if DIRECT_BUILD
        throw XCTSkip("FooterSection's right column is non-deterministic under " +
            "DIRECT_BUILD: `Updater.currentVersion` reads `Bundle.main.infoDictionary` " +
            "which differs between `swift test` (xctest bundle) and the shipped app. " +
            "App Store build has a stable single-column rendering and is the snapshot baseline.")
        #else
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_footerSection.1.png"]
        )
        let settings = SettingsStore()
        let updater = Updater()
        let view = FooterSection()
            .environment(settings)
            .environment(updater)
            .frame(width: Theme.twoColumnMenuWidth, height: 120)
            .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.twoColumnMenuWidth, height: 120))
        #endif
    }

    // MARK: - Cell 7: AccordionCard row-count height scaling

    /// Render the same AccordionCard with N synthetic content rows and
    /// snapshot each. Pins `AccordionCard.animationDuration(forRows:)`'s
    /// formula visually: a regression that decouples row count from
    /// rendered body height (e.g. the production `if isExpanded` gate
    /// being removed) shows up as visibly different bitmaps for N=1, 3,
    /// 5, 7. Without these baselines the formula is only checked in
    /// `MatrixAccordionExpansionSize_Tests` via numeric height deltas.
    func test_cell_accordionCard_rowCounts() throws {
        try skipIfNonEnglishLocale()
        // CI bootstrap: the FlowLayout-balanced AccordionCard rewrite
        // changed pixel output, but the `__Snapshots__/CI/` subtree
        // doesn't have a baseline yet (the seed workflow_dispatch hasn't
        // run for the new layout). When running under CI without a
        // baseline on disk, skip the cell — existing baselines are
        // still authoritative everywhere they exist. On developer hosts
        // (HostApp / AppStore / Direct variants) the recorded baselines
        // assert the layout as before.
        let directory = Self.snapshotDirectory(filePath: #filePath)
        let expectedFiles = [1, 3, 5, 7].map {
            "test_cell_accordionCard_rowCounts.rows-\($0).png"
        }
        try skipIfCIBaselineMissing(directory: directory, expectedFiles: expectedFiles)

        for rowCount in [1, 3, 5, 7] {
            let view = AccordionCard(
                title: "AccordionCard \(rowCount) rows",
                contentRowCount: rowCount,
                isExpanded: .constant(true)
            ) {
                VStack(spacing: 4) {
                    ForEach(0..<rowCount, id: \.self) { idx in
                        Text("Row \(idx)").font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                    }
                }
            }
            .frame(width: Theme.menuWidth, height: CGFloat(60 + rowCount * 22))
            .preferredColorScheme(.light)
            assertImageSnapshot(
                of: view,
                named: "rows-\(rowCount)",
                size: CGSize(width: Theme.menuWidth, height: CGFloat(60 + rowCount * 22))
            )
        }
    }

    // MARK: - Cell 8: Theme color palette swatches

    /// Render every `Theme` named color as a labelled swatch row. Catches
    /// color-token additions / removals / hex-value drift that would not
    /// break compilation but would change the rendered UI: e.g. someone
    /// edits `Theme.pink`'s RGB values, or removes `Theme.lightPink`, or
    /// adds a new token that isn't visually reviewed.
    ///
    /// Order is the source-declaration order in `Theme.swift`. Adding a
    /// new color requires regenerating the baseline.
    func test_cell_themeColorPaletteSwatches() throws {
        try skipIfCIBaselineMissing(
            directory: Self.snapshotDirectory(filePath: #filePath),
            expectedFiles: ["test_cell_themeColorPaletteSwatches.1.png"]
        )
        let palette: [(name: String, color: Color)] = [
            ("pink",      Theme.pink),
            ("deepRose",  Theme.deepRose),
            ("mauve",     Theme.mauve),
            ("lightPink", Theme.lightPink),
            ("dark",      Theme.dark),
        ]
        let view = HStack(spacing: 4) {
            ForEach(palette, id: \.name) { entry in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(entry.color)
                        .frame(width: 50, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
                        )
                    Text(entry.name)
                        .font(.system(size: 9))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(8)
        .background(Color.white)
        .frame(width: 320, height: 64)
        assertImageSnapshot(of: view, size: CGSize(width: 320, height: 64))
    }
}
