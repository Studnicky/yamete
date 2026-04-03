import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(ImpactController.self) var controller

    var body: some View {
        FaceIcon()
            .opacity(controller.isEnabled ? 1.0 : 0.4)
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
