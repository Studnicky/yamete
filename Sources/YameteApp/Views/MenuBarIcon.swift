import SwiftUI
import AppKit

public struct MenuBarLabel: View {
    @Environment(MenuBarFace.self) var menuBarFace
    @Environment(Yamete.self) var yamete

    public init() {}

    public var body: some View {
        Group {
            if let face = menuBarFace.reactionFace {
                Image(nsImage: face)
                    .resizable()
                    .scaledToFit()
            } else {
                FaceIcon()
                    .opacity(yamete.fusion.isRunning ? 1.0 : 0.4)
            }
        }
        .frame(width: 18, height: 18)
    }
}

struct FaceIcon: View {
    private static let cachedIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "menubar_icon", ofType: "png"),
              let img  = NSImage(contentsOfFile: path) else { return nil }
        guard let t = img.copy() as? NSImage else { return nil }
        t.size = NSSize(width: 18, height: 18)
        t.isTemplate = true
        return t
    }()

    var body: some View {
        if let icon = Self.cachedIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Text("(≧▽≦)")
                .font(.system(size: 10))
        }
    }
}
