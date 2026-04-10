#if canImport(YameteCore)
import YameteCore
#endif
import AppKit
import SwiftUI

private let log = AppLog(category: "ScreenFlash")

/// Flashes face overlays on impact across selected screens.
/// Uses per-screen history to reduce immediate face repeats.
@MainActor
public final class ScreenFlash: VisualResponder {
    /// Rotation matrix: `history[monitorIndex]` is the ordered list of face indices
    /// previously shown on that monitor, most recent last. The matrix drives all
    /// dedup logic from a single data structure — no separate event/monitor tracking.
    private var history: [[Int]] = []

    public init() {}
    private var cachedFaces: [NSImage] = []
    private var cachedAppearance: NSAppearance.Name?

    private var faceImages: [NSImage] {
        let current = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if cachedFaces.isEmpty || current != cachedAppearance {
            cachedFaces = loadFaceImages()
            cachedAppearance = current
        }
        return cachedFaces
    }

    /// Reusable window pool keyed by screen index. Avoids NSWindow creation per impact.
    private var windowPool: [Int: NSWindow] = [:]
    private var hideTask: Task<Void, Never>?
    private var flashGeneration: UInt64 = 0

    /// Flashes all screens with a face overlay gated inside `clipDuration`.
    /// - Parameter enabledDisplayIDs: display IDs to flash. Empty = all displays.
    public func flash(intensity: Float, opacityMin: Float, opacityMax: Float, clipDuration: Double, dismissAfter _: Double, enabledDisplayIDs: [Int] = []) {
        guard clipDuration > 0 else { return }

        let screens = selectScreens(enabledIDs: enabledDisplayIDs)
        guard !screens.isEmpty else { return }

        let peak = CGFloat(opacityMin + intensity * (opacityMax - opacityMin))
        let env = Self.envelope(clipDuration: clipDuration, intensity: intensity)
        let faces = faceImages
        let picks = pickFaces(count: screens.count, total: faces.count)

        pruneWindowPool(activeCount: screens.count)
        let windows = renderOverlays(screens: screens, faces: faces, picks: picks, peak: peak, env: env)
        scheduleHide(windows: windows, after: clipDuration)
    }

    private func selectScreens(enabledIDs: [Int]) -> [NSScreen] {
        let enabled = Set(enabledIDs)
        return NSScreen.screens.filter { enabled.contains($0.displayID) }
    }

    private func pruneWindowPool(activeCount: Int) {
        for key in windowPool.keys where key >= activeCount {
            windowPool[key]?.orderOut(nil)
            windowPool.removeValue(forKey: key)
        }
    }

    private func renderOverlays(screens: [NSScreen], faces: [NSImage], picks: [Int?],
                                peak: CGFloat, env: (fadeIn: Double, hold: Double, fadeOut: Double)) -> [NSWindow] {
        screens.enumerated().map { i, screen in
            let face = picks[i].map { faces[$0] }
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

    // MARK: - Face selection

    /// Picks face indices using recency scoring across monitors and events.
    private func pickFaces(count: Int, total: Int) -> [Int?] {
        guard total > 0 else { return Array(repeating: nil, count: count) }
        while history.count < count { history.append([]) }

        let recentGlobal = Set(history.flatMap { $0.suffix(count) })
        var usedThisEvent = Set<Int>()
        var picks: [Int?] = []

        for monitor in 0..<count {
            guard let best = FaceScoring.selectBest(
                total: total, monitorHistory: history[monitor],
                recentGlobal: recentGlobal, usedThisEvent: usedThisEvent
            ) else { picks.append(nil); continue }

            picks.append(best)
            usedThisEvent.insert(best)
            history[monitor].append(best)
            FaceScoring.pruneHistory(&history[monitor], maxLength: total * 2)
        }

        return picks
    }

    // MARK: - Resource loading

    private func loadFaceImages() -> [NSImage] {
        let images = FaceRenderer.loadFaces()
        if images.isEmpty {
            log.error("entity:FaceLibrary wasInvalidatedBy activity:ResourceLoad — no face images in bundle/faces")
        } else {
            log.info("entity:FaceLibrary wasGeneratedBy activity:ResourceLoad count=\(images.count)")
        }
        return images
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

// MARK: - Face scoring

private enum FaceScoring {
    static func selectBest(total: Int, monitorHistory: [Int],
                           recentGlobal: Set<Int>, usedThisEvent: Set<Int>) -> Int? {
        let scores = (0..<total).map { idx -> (index: Int, score: Int) in
            let recency = monitorHistory.lastIndex(of: idx)
                .map { monitorHistory.count - $0 } ?? (total + 1)
            let globalPenalty = recentGlobal.contains(idx) ? total : 0
            let eventPenalty = usedThisEvent.contains(idx) ? total * 2 : 0
            return (idx, -(recency) + globalPenalty + eventPenalty)
        }
        return scores.min(by: { $0.score < $1.score })?.index
    }

    static func pruneHistory(_ history: inout [Int], maxLength: Int) {
        if history.count > maxLength {
            history.removeFirst(history.count - maxLength)
        }
    }
}
