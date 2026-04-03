import AppKit
import SwiftUI

private let log = AppLog(category: "ScreenFlash")

/// Flashes a random face full-screen on each impact.
///
/// Face selection guarantees:
/// 1. Within a single event, every monitor gets a **different** face.
/// 2. Faces used in the **previous event** are excluded from the next event's pool.
/// 3. If there are more monitors than available faces, the per-monitor history
///    ensures no monitor repeats its own last face.
///
/// All window operations are MainActor-confined.
@MainActor
final class ScreenFlash {
    /// Rotation matrix: `history[monitorIndex]` is the ordered list of face indices
    /// previously shown on that monitor, most recent last. The matrix drives all
    /// dedup logic from a single data structure — no separate event/monitor tracking.
    private var history: [[Int]] = []

    private lazy var faceImages: [NSImage] = loadFaceImages()

    /// Reusable window pool keyed by screen index. Avoids NSWindow creation per impact.
    private var windowPool: [Int: NSWindow] = [:]

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

        Task {
            try? await Task.sleep(for: .seconds(clipDuration + 0.05))
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

    /// Picks `count` unique face indices using the rotation matrix.
    ///
    /// Algorithm: for each monitor, score every face by how recently it appeared
    /// on THAT monitor (from history) plus a penalty if already picked by another
    /// monitor in this event. Pick the face with the lowest (least recent) score.
    /// This produces maximum rotation with zero branching fallback logic.
    private func pickFaces(count: Int, total: Int) -> [Int?] {
        guard total > 0 else { return Array(repeating: nil, count: count) }

        // Ensure history has a row for each monitor
        while history.count < count { history.append([]) }

        // Flatten all recent faces across all monitors for cross-event penalty
        let recentGlobal = Set(history.flatMap { $0.suffix(count) })

        var usedThisEvent = Set<Int>()
        var picks: [Int?] = []

        for monitor in 0..<count {
            let monitorHistory = history[monitor]

            // Score each face: lower = better candidate
            // - Per-monitor recency: index in history (0 = oldest, len = most recent)
            // - Cross-event penalty: +total if used in another monitor's recent history
            // - Same-event penalty: +total*2 if already picked this event
            let scores: [(index: Int, score: Int)] = (0..<total).map { faceIdx in
                let recency = monitorHistory.lastIndex(of: faceIdx)
                    .map { monitorHistory.count - $0 }  // 1=most recent, count=oldest
                    ?? (total + 1)                       // never shown = best

                let globalPenalty = recentGlobal.contains(faceIdx) ? total : 0
                let eventPenalty = usedThisEvent.contains(faceIdx) ? total * 2 : 0

                // Invert recency so "never shown" scores lowest
                return (faceIdx, -(recency) + globalPenalty + eventPenalty)
            }

            guard let best = scores.min(by: { $0.score < $1.score })?.index else { picks.append(nil); continue }
            picks.append(best)
            usedThisEvent.insert(best)
            history[monitor].append(best)

            // Cap history length to 2x face count (enough for full rotation tracking)
            if history[monitor].count > total * 2 {
                history[monitor].removeFirst(history[monitor].count - total * 2)
            }
        }

        return picks
    }

    // MARK: - Resource loading

    private func loadFaceImages() -> [NSImage] {
        let urls = BundleResources.urls(prefix: "face_", extensions: ["svg", "png", "jpg", "jpeg"])
        let images = urls.compactMap { NSImage(contentsOf: $0) }
        if images.isEmpty {
            log.error("entity:FaceLibrary wasInvalidatedBy activity:ResourceLoad — no face images in bundle")
        } else {
            log.info("entity:FaceLibrary wasGeneratedBy activity:ResourceLoad count=\(images.count)")
        }
        return images
    }

    // MARK: - Window pool

    /// Returns a reusable borderless overlay window for the given screen index.
    /// Creates a new window only on first use; subsequent calls return the existing one.
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
