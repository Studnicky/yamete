import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted each time the menu bar panel becomes visible, so SwiftUI content
    /// can refresh device lists and other volatile state (mirrors the per-open
    /// `onAppear` behavior of `MenuBarExtra`).
    static let menuBarPanelDidShow = Notification.Name("menuBarPanelDidShow")
}

/// Owns the NSStatusItem and its popover panel.
///
/// Replaces SwiftUI's `MenuBarExtra(.window)` with a directly-managed
/// `NSPanel` so we control the backing material, initial frame sizing,
/// and show/hide lifecycle. The panel is sized to its SwiftUI content
/// _before_ it becomes visible, eliminating the blank-gap / resize-flash
/// that `MenuBarExtra` produces when conditional sections change height.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private var monitor: Any?

    init(settings: SettingsStore, controller: ImpactController, updater: Updater) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        panel = MenuBarPanel(
            contentView: MenuBarView()
                .environment(settings)
                .environment(controller)
                .environment(updater)
        )
        panel.onDismiss = { [weak self] in self?.removeMonitor() }

        configureButton(controller: controller)
    }

    deinit {
        removeMonitor()
    }

    // MARK: - Status item button

    /// Sets the button image from the controller's observable state and
    /// re-observes whenever it changes. Uses `withObservationTracking` to
    /// track `reactionFace` and `isEnabled` without embedding an
    /// NSHostingView inside the status bar button (which breaks its layout).
    private func configureButton(controller: ImpactController) {
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePanel)
        button.target = self

        let templateIcon: NSImage? = {
            guard let path = Bundle.main.path(forResource: "menubar_icon", ofType: "png"),
                  let img = NSImage(contentsOfFile: path),
                  let copy = img.copy() as? NSImage else { return nil }
            copy.size = NSSize(width: 18, height: 18)
            copy.isTemplate = true
            return copy
        }()

        func applyIcon() {
            if let face = controller.reactionFace {
                button.image = face
                button.alphaValue = 1.0
            } else {
                button.image = templateIcon
                button.alphaValue = controller.isEnabled ? 1.0 : 0.4
            }
        }

        func observe() {
            withObservationTracking {
                _ = controller.reactionFace
                _ = controller.isEnabled
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard self != nil else { return }
                    applyIcon()
                    observe()
                }
            }
        }

        applyIcon()
        observe()
    }

    // MARK: - Panel toggle

    @objc private func togglePanel() {
        if panel.isVisible {
            dismissPanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Post the refresh notification before sizing so the SwiftUI content
        // updates device lists first, then size the panel to the final layout.
        NotificationCenter.default.post(name: .menuBarPanelDidShow, object: nil)

        // Defer sizing + display to the next run-loop tick so the hosting
        // view's fittingSize reflects the refreshed SwiftUI content tree.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.sizeToContent()

            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let panelWidth = self.panel.frame.width
            let x = buttonRect.midX - panelWidth / 2
            let y = buttonRect.minY - self.panel.frame.height

            self.panel.setFrameOrigin(NSPoint(x: x, y: y))
            self.panel.makeKeyAndOrderFront(nil)
        }

        installMonitor()
    }

    private func dismissPanel() {
        panel.orderOut(nil)
        removeMonitor()
    }

    // MARK: - Outside-click monitor

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.dismissPanel()
        }
    }

    private nonisolated func removeMonitor() {
        MainActor.assumeIsolated {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - Panel

/// A borderless, non-activating panel styled like a system menu bar popover.
///
/// Uses `NSVisualEffectView` with `.menu` material for the standard macOS
/// menu bar panel appearance. The panel is `.nonactivatingPanel` so clicking
/// it doesn't steal focus from the frontmost app.
private final class MenuBarPanel: NSPanel {
    private let hostingView: NSView

    /// Called when the panel is dismissed via Escape or resignKey.
    /// StatusBarController sets this to clean up the global event monitor.
    var onDismiss: (() -> Void)?

    init<Content: View>(contentView: Content) {
        hostingView = NSHostingView(rootView: contentView)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        self.contentView = visualEffect
    }

    /// Sizes the panel frame to the SwiftUI content's intrinsic size.
    func sizeToContent() {
        let ideal = hostingView.fittingSize
        let frame = NSRect(origin: frame.origin, size: ideal)
        setFrame(frame, display: false)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onDismiss?()
    }

    override var canBecomeKey: Bool { true }
}
