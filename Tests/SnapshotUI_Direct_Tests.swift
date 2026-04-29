#if DIRECT_BUILD
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

/// Pixel-baseline snapshots for the **Direct-build-only** menu UI surface.
///
/// `SnapshotUI_Tests` covers the App Store build's UI. The Direct build adds
/// surface that never ships on the Store and therefore never gets exercised
/// by the App Store snapshot suite:
///
/// - `AccelTuningSection` / `MicTuningSection` / `HeadphoneTuningSection`
///   wrappers — the production `Section` views that compose an
///   `AccordionCard` around their `*TuningContent` body. Direct builds
///   surface these as standalone collapsibles whose collapsed/expanded
///   geometry must stay stable.
/// - `FooterSection` under `#if DIRECT_BUILD` — the right column renders
///   `Updater.state` (idle by default in tests) plus a "check for updates"
///   chevron pill, which the App Store baseline doesn't capture.
/// - `ResponseSection`'s audio card with `volumeSpikeEnabled` — the
///   `EnableToggleRow` for "Volume Override" is gated on `DIRECT_BUILD`
///   and only renders when the audio card is expanded under that flag.
/// - A composite snapshot of the three tuning sections + Direct-flavoured
///   footer stacked vertically — locks the panel-rebuild geometry that
///   `MatrixAccordionExpansionSize_Tests` asserts numerically but doesn't
///   pixel-anchor.
///
/// The whole file is `#if DIRECT_BUILD`-gated so default `swift test`
/// builds skip every cell here without seeing this file's symbols at all.
///
/// ## Determinism strategy
///
/// Same precision/perceptualPrecision values as `SnapshotUI_Tests`
/// (0.99 / 0.98) so the tolerated subpixel-hinting drift is identical.
/// Skip rules:
///
/// 1. **Locale**: `XCTSkipUnless` host's preferred localization starts
///    with `en` — every Direct-only label flows through
///    `NSLocalizedString` and non-English glyph widths shift the layout
///    enough to invalidate English baselines.
/// 2. **Updater state**: `Updater()` initializes with `.idle` state and
///    a `currentVersion` resolved from `Bundle.main` at construction
///    time. Under the SPM `xctest` runner that bundle has a stable
///    `infoDictionary` (or returns nil → the `?? "1.0.0"` fallback in
///    `Updater.currentVersion(bundle:)` engages, which is also stable).
///    No cell in this file calls `Updater.checkForUpdates()`, so state
///    stays `.idle` for the entire snapshot capture and the right
///    column renders the "info.circle + version + chevron" composition.
/// 3. **No NSApplication mutation**: cells render into `NSHostingView`
///    without instantiating `NSApp.run()`; `SMAppService.mainApp.status`
///    queried in `FooterSection.@State init` returns `.notRegistered`
///    outside an `.app` bundle, which is stable.
/// 4. **No clock pinning**: no Direct-only view formats a `Date()`.
///    `MenuBarFace.impactCount` defaults to 0 and the snapshot fixtures
///    never trigger `recordCount(at:)`.
/// 5. **Color schemes**: rendered explicitly via
///    `.preferredColorScheme(.light)` / `.dark`.
///
/// ## Cell index
///
/// 1. accelTuningSection — collapsed + expanded (light + dark)
/// 2. micTuningSection — collapsed + expanded (light + dark)
/// 3. headphoneTuningSection — collapsed + expanded (light + dark)
/// 4. footerSection_directBuild — light + dark
/// 5. responseSection_audio_volumeSpikeOn — DIRECT_BUILD-only audio-card
///    expanded variant capturing the `EnableToggleRow` for Volume Override
/// 6. directOnlyComposite — three tuning sections + Direct footer stacked
@MainActor
final class SnapshotUI_Direct_Tests: XCTestCase {

    // MARK: - Configuration

    private static let imagePrecision: Float = 0.99
    private static let perceptualPrecision: Float = 0.98
    private static let recordMode: SnapshotTestingConfiguration.Record = .missing

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

        // `#file` under SwiftPM Swift 6 reports `<module>/<basename>.swift`,
        // which would steer the default snapshot directory at the module
        // name (e.g. `YameteTests/__Snapshots__/`) instead of the file's
        // actual on-disk neighbour. Forward `#filePath` (the real
        // filesystem path) into `verifySnapshot`'s `file:` argument so
        // baselines land at `Tests/__Snapshots__/SnapshotUI_Direct_Tests/*.png`
        // next to this file, mirroring `SnapshotUI_Tests`'s layout.
        withSnapshotTesting(record: Self.recordMode) {
            let failure = verifySnapshot(
                of: host as NSView,
                as: .image(
                    precision: Self.imagePrecision,
                    perceptualPrecision: Self.perceptualPrecision,
                    size: size
                ),
                named: name,
                file: filePath,
                testName: testName,
                line: line
            )
            if let message = failure {
                XCTFail(message, file: filePath, line: line)
            }
        }
    }

    private func skipIfNonEnglishLocale() throws {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        try XCTSkipUnless(lang.hasPrefix("en"),
            "snapshot baselines are recorded under English; preferred=\(lang)")
    }

    // MARK: - Cell 1: AccelTuningSection collapsed / expanded

    /// `AccelTuningSection` wraps `AccelTuningContent` in an `AccordionCard`.
    /// Collapsed: only the header bar contributes pixels. Expanded variants
    /// render the full eight-row tuning body (frequency band, confirmations,
    /// crest factor, report interval, rise rate, spike threshold, warmup).
    func test_cell_accelTuningSection_collapsed() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"),
            isExpanded: .constant(false)
        ) {
            AccelTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 60)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 60))
    }

    func test_cell_accelTuningSection_expanded_lightScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"),
            contentRowCount: 14,
            isExpanded: .constant(true)
        ) {
            AccelTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 540)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 540))
    }

    func test_cell_accelTuningSection_expanded_darkScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"),
            contentRowCount: 14,
            isExpanded: .constant(true)
        ) {
            AccelTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 540)
        .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 540))
    }

    // MARK: - Cell 2: MicTuningSection collapsed / expanded

    func test_cell_micTuningSection_collapsed() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"),
            isExpanded: .constant(false)
        ) {
            MicTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 60)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 60))
    }

    func test_cell_micTuningSection_expanded_lightScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"),
            contentRowCount: 10,
            isExpanded: .constant(true)
        ) {
            MicTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 400)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 400))
    }

    func test_cell_micTuningSection_expanded_darkScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"),
            contentRowCount: 10,
            isExpanded: .constant(true)
        ) {
            MicTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 400)
        .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 400))
    }

    // MARK: - Cell 3: HeadphoneTuningSection collapsed / expanded

    func test_cell_headphoneTuningSection_collapsed() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"),
            isExpanded: .constant(false)
        ) {
            HeadphoneTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 60)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 60))
    }

    func test_cell_headphoneTuningSection_expanded_lightScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"),
            contentRowCount: 10,
            isExpanded: .constant(true)
        ) {
            HeadphoneTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 400)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 400))
    }

    func test_cell_headphoneTuningSection_expanded_darkScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let view = AccordionCard(
            title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"),
            contentRowCount: 10,
            isExpanded: .constant(true)
        ) {
            HeadphoneTuningContent()
        }
        .environment(settings)
        .frame(width: Theme.menuWidth, height: 400)
        .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.menuWidth, height: 400))
    }

    // MARK: - Cell 4: FooterSection under DIRECT_BUILD
    //
    // Under DIRECT_BUILD, FooterSection's right column renders the
    // `Updater.state` composition (icon + version line + check chevron).
    // `Updater()` initializes with `.idle`; no cell here transitions
    // it. The version string is whatever `Updater.currentVersion(bundle:
    // .main)` resolves to under the SPM `xctest` runner — stable across
    // runs on the same host (either the bundle's
    // `CFBundleShortVersionString` or, when nil, the `"1.0.0"` literal
    // fallback exercised by `UIGatesPhase7B_Tests`'s `NilInfoBundle`).

    func test_cell_footerSection_directBuild_lightScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let updater = Updater()
        let view = FooterSection()
            .environment(settings)
            .environment(updater)
            .frame(width: Theme.twoColumnMenuWidth, height: 120)
            .preferredColorScheme(.light)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.twoColumnMenuWidth, height: 120))
    }

    func test_cell_footerSection_directBuild_darkScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let updater = Updater()
        let view = FooterSection()
            .environment(settings)
            .environment(updater)
            .frame(width: Theme.twoColumnMenuWidth, height: 120)
            .preferredColorScheme(.dark)
        assertImageSnapshot(of: view, size: CGSize(width: Theme.twoColumnMenuWidth, height: 120))
    }

    // MARK: - Cell 5: Audio card with Volume Override (DIRECT_BUILD)
    //
    // The "volume-spike threshold slider section" called out in the plan
    // does not exist as its own section — under DIRECT_BUILD the audio
    // SensorAccordionCard inside ResponseSection adds an
    // `EnableToggleRow` for `volumeSpikeEnabled` below the volume range
    // slider. Capture the full ResponseSection rendered with all
    // hardware-gated cards off so only the Direct-flavoured audio card +
    // flash + notifications + keyboard cards show. This pins the
    // Direct-only `EnableToggleRow` row-height contribution.

    func test_cell_responseSection_directBuild_audioVolumeSpikeOn_lightScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        // Drive the Direct-only sub-toggle on so its colored icon + label
        // composition is part of the baseline (vs. the dimmed-off variant).
        settings.volumeSpikeEnabled = true
        let yamete = Yamete(settings: settings)
        // Hardware-gated cards off → 4 always-on cards rendered (audio,
        // flash, notifications, keyboard LED). Audio is collapsed in
        // ResponseSection's @State default; this snapshot anchors the
        // collapsed-stack layout where every Direct-only divergence in
        // the volume card affects the visible header strip.
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

    func test_cell_responseSection_directBuild_audioVolumeSpikeOn_darkScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        settings.volumeSpikeEnabled = true
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

    // MARK: - Cell 6: Composite — every Direct-only section expanded
    //
    // One snapshot stacking the three tuning sections (all expanded) +
    // the Direct-flavoured FooterSection. Locks the cumulative panel
    // height a Direct user sees when every collapsible is open. A
    // regression in any single section's row-height geometry,
    // AccordionCard inner padding, or FooterSection right-column
    // composition shifts pixels here without needing per-section cells
    // to all fail individually.

    func test_cell_directOnlyComposite_allExpanded_lightScheme() throws {
        try skipIfNonEnglishLocale()
        let settings = SettingsStore()
        let updater = Updater()
        let composite = VStack(spacing: 0) {
            AccordionCard(
                title: NSLocalizedString("section_accel_tuning", comment: "Accelerometer tuning section header"),
                contentRowCount: 14,
                isExpanded: .constant(true)
            ) {
                AccelTuningContent()
            }
            Divider()
            AccordionCard(
                title: NSLocalizedString("section_mic_tuning", comment: "Microphone tuning section header"),
                contentRowCount: 10,
                isExpanded: .constant(true)
            ) {
                MicTuningContent()
            }
            Divider()
            AccordionCard(
                title: NSLocalizedString("section_hp_tuning", comment: "Headphone tuning section header"),
                contentRowCount: 10,
                isExpanded: .constant(true)
            ) {
                HeadphoneTuningContent()
            }
            Divider()
            FooterSection()
                .environment(updater)
        }
        .environment(settings)
        .environment(updater)
        .frame(width: Theme.twoColumnMenuWidth, height: 1500)
        .preferredColorScheme(.light)
        assertImageSnapshot(of: composite,
                            size: CGSize(width: Theme.twoColumnMenuWidth, height: 1500))
    }
}
#endif
