#if canImport(YameteCore)
import YameteCore
#endif
import AppKit

/// Loads SVG face templates and resolves color placeholders based on system appearance.
///
/// SVG files use semantic placeholders: {{outline}}, {{blush}}, {{accent}}, {{face}}.
/// These are resolved at load time using the active light/dark appearance.
public enum FaceRenderer {

    public struct Palette: Sendable {
        public let outline: String
        public let blush: String
        public let accent: String
        public let face: String

        public static let dark = Palette(
            outline: "#F296A8",  // lightPink — visible against dark bg
            blush:   "#DD5B85",  // pink
            accent:  "#C878A9",  // mauve — lifted from deepRose for visibility
            face:    "#F296A8")  // lightPink

        public static let light = Palette(
            outline: "#0E0E0E",  // dark — high contrast on light bg
            blush:   "#DD5B85",  // pink
            accent:  "#A42A5B",  // deepRose
            face:    "#C878A9")  // mauve
    }

    /// MainActor-isolated because it reads `NSApp.effectiveAppearance`.
    /// All current call sites are already on the main actor (ImpactController,
    /// MenuBarLabel, ScreenFlash) so this is a no-op at the call site.
    @MainActor
    public static var currentPalette: Palette {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .dark : .light
    }

    /// Loads all face images from the bundle, resolving SVG templates with the
    /// current palette. MainActor-isolated because the default-palette branch
    /// reads `currentPalette`, which is itself MainActor-bound. Callers can
    /// pass an explicit palette from any actor — but the convenience overload
    /// requires main actor.
    @MainActor
    public static func loadFaces(palette: Palette? = nil) -> [NSImage] {
        let p = palette ?? currentPalette
        let urls = BundleResources.urls(in: "faces", extensions: ["svg", "png", "jpg", "jpeg"])
        return urls.compactMap { url -> NSImage? in
            if url.pathExtension == "svg" {
                return resolveSVG(url: url, palette: p)
            }
            return NSImage(contentsOf: url)
        }
    }

    /// Resolves a single SVG template with the given palette.
    public static func resolveSVG(url: URL, palette: Palette) -> NSImage? {
        guard var svg = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        svg = svg.replacingOccurrences(of: "{{outline}}", with: palette.outline)
                 .replacingOccurrences(of: "{{blush}}", with: palette.blush)
                 .replacingOccurrences(of: "{{accent}}", with: palette.accent)
                 .replacingOccurrences(of: "{{face}}", with: palette.face)
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }

}
