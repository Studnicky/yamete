import AppKit
import SwiftUI

private let log = AppLog(category: "ScreenFlash")

/// Flashes face overlays on impact across selected screens.
/// Uses per-screen history to reduce immediate face repeats.
@MainActor
final class ScreenFlash: FlashResponder {
    /// Rotation matrix: `history[monitorIndex]` is the ordered list of face indices
    /// previously shown on that monitor, most recent last. The matrix drives all
    /// dedup logic from a single data structure — no separate event/monitor tracking.
    private var history: [[Int]] = []

    private lazy var faceImages: [NSImage] = loadFaceImages()

    /// Reusable window pool keyed by screen index. Avoids NSWindow creation per impact.
    private var windowPool: [Int: NSWindow] = [:]
    private var hideTask: Task<Void, Never>?
    private var flashGeneration: UInt64 = 0

    /// Flashes all screens with a face overlay gated inside `clipDuration`.
    /// - Parameter enabledDisplayIDs: display IDs to flash. Empty = all displays.
    func flash(intensity: Float, opacityMin: Float, opacityMax: Float, clipDuration: Double, enabledDisplayIDs: [Int] = []) {
        guard clipDuration > 0 else { return }

        let peak = CGFloat(opacityMin + intensity * (opacityMax - opacityMin))
        let env  = Self.envelope(clipDuration: clipDuration, intensity: intensity)
        let faces = faceImages

        if faces.isEmpty {
            log.warning("activity:Flash used entity:FaceLibrary — empty, pink wash only")
        }

        let allScreens = NSScreen.screens
        let screens: [NSScreen]
        if enabledDisplayIDs.isEmpty {
            screens = allScreens
        } else {
            let enabled = Set(enabledDisplayIDs)
            screens = allScreens.filter { screen in
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return true }
                return enabled.contains(Int(displayID))
            }
        }
        guard !screens.isEmpty else { return }
        let picks = pickFaces(count: screens.count, total: faces.count)

        var activeWindows: [NSWindow] = []
        for (i, screen) in screens.enumerated() {
            let face = picks[i].map { faces[$0] }
            let win = windowForScreen(index: i, screen: screen)
            let hosting = NSHostingView(rootView:
                FlashOverlayView(peak: peak, face: face,
                                 fadeIn: env.fadeIn, hold: env.hold, fadeOut: env.fadeOut)
                    .frame(width: screen.frame.width, height: screen.frame.height)
            )
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            win.contentView = hosting
            win.setFrame(screen.frame, display: false)
            win.orderFront(nil)
            activeWindows.append(win)
        }

        flashGeneration &+= 1
        let generation = flashGeneration
        hideTask?.cancel()
        hideTask = Task { @MainActor [activeWindows] in
            try? await Task.sleep(for: .seconds(clipDuration + 0.05))
            guard !Task.isCancelled, generation == flashGeneration else { return }
            activeWindows.forEach { $0.orderOut(nil) }
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

        // Ensure one history row per monitor.
        while history.count < count { history.append([]) }

        // Recent faces across monitors for cross-event penalty.
        let recentGlobal = Set(history.flatMap { $0.suffix(count) })

        var usedThisEvent = Set<Int>()
        var picks: [Int?] = []

        for monitor in 0..<count {
            let monitorHistory = history[monitor]

            // Lower score is better: recency + cross-event + same-event penalties.
            let scores: [(index: Int, score: Int)] = (0..<total).map { faceIdx in
                let recency = monitorHistory.lastIndex(of: faceIdx)
                    .map { monitorHistory.count - $0 }
                    ?? (total + 1)

                let globalPenalty = recentGlobal.contains(faceIdx) ? total : 0
                let eventPenalty = usedThisEvent.contains(faceIdx) ? total * 2 : 0

                return (faceIdx, -(recency) + globalPenalty + eventPenalty)
            }

            guard let best = scores.min(by: { $0.score < $1.score })?.index else { picks.append(nil); continue }
            picks.append(best)
            usedThisEvent.insert(best)
            history[monitor].append(best)

            // Cap per-monitor history length.
            if history[monitor].count > total * 2 {
                history[monitor].removeFirst(history[monitor].count - total * 2)
            }
        }

        return picks
    }

    // MARK: - Resource loading

    private func loadFaceImages() -> [NSImage] {
        let urls = BundleResources.urls(in: "faces", extensions: ["svg", "png", "jpg", "jpeg"])
        let images = urls.compactMap { NSImage(contentsOf: $0) }
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
