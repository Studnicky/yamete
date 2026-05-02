#if !RAW_SWIFTC_LUMP
import YameteCore
#endif
import AppKit
import SwiftUI

private let log = AppLog(category: "ScreenFlash")

/// Flashes face overlays on impact across selected screens.
/// Face selection is pre-resolved by the bus enricher — all screens show the same face.
@MainActor
public final class ScreenFlash: ReactiveOutput {

    public override init() { super.init() }

    // MARK: - ReactiveOutput lifecycle

    override public func shouldFire(_ fired: FiredReaction, provider: OutputConfigProvider) -> Bool {
        let c = provider.flashConfig()
        return c.enabled && c.perReaction[fired.kind] != false
    }

    override public func action(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        let c = provider.flashConfig()
        flash(
            intensity: min(1.0, fired.intensity * multiplier),
            opacityMin: c.opacityMin,
            opacityMax: c.opacityMax,
            clipDuration: fired.clipDuration,
            enabledDisplayIDs: c.enabledDisplayIDs,
            faceIndices: fired.faceIndices,
            activeDisplayOnly: c.activeDisplayOnly
        )
        try? await Task.sleep(for: .seconds(fired.clipDuration + 0.05))
    }

    override public func postAction(_ fired: FiredReaction, multiplier: Float, provider: OutputConfigProvider) async {
        windowPool.values.forEach { $0.orderOut(nil) }
    }

    override public func reset() {
        hideTask?.cancel()
        hideTask = nil
        windowPool.values.forEach { $0.orderOut(nil) }
    }

    /// Reusable window pool keyed by screen index. Avoids NSWindow creation per impact.
    private var windowPool: [Int: NSWindow] = [:]
    private var hideTask: Task<Void, Never>?
    private var flashGeneration: UInt64 = 0

    /// Flashes all screens with a face overlay gated inside `clipDuration`.
    /// - Parameter enabledDisplayIDs: display IDs to flash. Empty = all displays.
    /// - Parameter activeDisplayOnly: when true, flash only NSScreen.main at fire time.
    public func flash(intensity: Float, opacityMin: Float, opacityMax: Float, clipDuration: Double, enabledDisplayIDs: [Int] = [], faceIndices: [Int] = [], activeDisplayOnly: Bool = false) {
        guard clipDuration > 0 else { return }

        let screens = activeDisplayOnly ? [NSScreen.main].compactMap { $0 } : selectScreens(enabledIDs: enabledDisplayIDs)
        guard !screens.isEmpty else { return }

        let peak = CGFloat(opacityMin + intensity * (opacityMax - opacityMin))
        let env = Self.envelope(clipDuration: clipDuration, intensity: intensity)

        pruneWindowPool(activeCount: screens.count)
        let windows = renderOverlays(screens: screens, faceIndices: faceIndices, peak: peak, env: env)
        scheduleHide(windows: windows, after: clipDuration)
    }

    private func selectScreens(enabledIDs: [Int]) -> [NSScreen] {
        let enabled = Set(enabledIDs)
        return NSScreen.screens.filter { enabled.contains($0.displayID) }
    }

    /// Pure helper exposing the screen-selection rules used by `flash(...)`
    /// without binding to live `NSScreen` objects. Mirrors the production
    /// branching exactly:
    ///   - `activeDisplayOnly == true`  → just the main screen if present (else empty)
    ///   - `enabledIDs.isEmpty == true` → empty array (production filter contains nothing)
    ///   - otherwise                    → intersection of allScreenIDs and enabledIDs,
    ///                                    preserving allScreenIDs ordering
    public static func selectScreenIDs(
        allScreenIDs: [Int],
        mainScreenID: Int?,
        enabledIDs: [Int],
        activeDisplayOnly: Bool
    ) -> [Int] {
        if activeDisplayOnly {
            return mainScreenID.map { [$0] } ?? []
        }
        let enabled = Set(enabledIDs)
        return allScreenIDs.filter { enabled.contains($0) }
    }

    private func pruneWindowPool(activeCount: Int) {
        for key in windowPool.keys where key >= activeCount {
            windowPool[key]?.orderOut(nil)
            windowPool.removeValue(forKey: key)
        }
    }

    private func renderOverlays(screens: [NSScreen], faceIndices: [Int],
                                peak: CGFloat, env: (fadeIn: Double, hold: Double, fadeOut: Double)) -> [NSWindow] {
        screens.enumerated().map { i, screen in
            let face = FaceLibrary.shared.image(at: faceIndices.indices.contains(i) ? faceIndices[i] : (faceIndices.first ?? 0))
            let win = windowForScreen(index: i, screen: screen)
            let hosting = NSHostingView(rootView:
                FlashOverlayView(peak: peak, face: face, fadeIn: env.fadeIn, hold: env.hold, fadeOut: env.fadeOut)
                    .frame(width: screen.frame.width, height: screen.frame.height))
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            win.contentView = hosting
            win.setFrame(screen.frame, display: false)
            win.orderFront(nil)
            return win
        }
    }

    private func scheduleHide(windows: [NSWindow], after duration: Double) {
        flashGeneration &+= 1
        let generation = flashGeneration
        hideTask?.cancel()
        hideTask = Task { @MainActor [windows] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            guard !Task.isCancelled, generation == flashGeneration else { return }
            windows.forEach { $0.orderOut(nil) }
        }
    }

    // MARK: - Envelope

    nonisolated static func envelope(clipDuration: Double, intensity: Float) -> (fadeIn: Double, hold: Double, fadeOut: Double) {
        let t = Double(intensity)
        let attack = 0.10 + (1.0 - t) * 0.20
        let decay  = 0.30 + (1.0 - t) * 0.20
        let hold   = 1.0 - attack - decay
        return (fadeIn: clipDuration * attack, hold: clipDuration * hold, fadeOut: clipDuration * decay)
    }

    // MARK: - Window pool

    /// Returns a reusable borderless overlay window for a screen.
    private func windowForScreen(index: Int, screen: NSScreen) -> NSWindow {
        if let existing = windowPool[index] { return existing }
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelKey.screenSaverWindow.rawValue) + 1)
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        windowPool[index] = win
        return win
    }
}

// MARK: - Animated overlay view

private struct FlashOverlayView: View {
    let peak:    CGFloat
    let face:    NSImage?
    let fadeIn:  Double
    let hold:    Double
    let fadeOut: Double

    @State private var opacity: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let cornerRadius = sqrt(pow(geo.size.width / 2, 2) + pow(geo.size.height / 2, 2))
            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: Color(red: 1.0, green: 0.40, blue: 0.60).opacity(opacity * 0.08), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.20, blue: 0.45).opacity(opacity * 0.30), location: 0.45),
                        .init(color: Color(red: 0.75, green: 0.05, blue: 0.25).opacity(opacity * 0.55), location: 0.75),
                        .init(color: Color(red: 0.50, green: 0.0, blue: 0.15).opacity(opacity * 0.70), location: 1.0),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: cornerRadius
                )
                if let img = face {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(geo.size.height * 0.1)
                        .opacity(opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .task {
            withAnimation(.easeIn(duration: fadeIn)) { opacity = peak }
            try? await Task.sleep(for: .seconds(fadeIn + hold))
            withAnimation(.easeOut(duration: fadeOut)) { opacity = 0 }
        }
    }
}

