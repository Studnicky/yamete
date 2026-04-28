import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted each time the menu bar panel becomes visible, so SwiftUI content
    /// can refresh device lists and other volatile state (mirrors the per-open
    /// `onAppear` behavior of `MenuBarExtra`).
    static let menuBarPanelDidShow = Notification.Name("menuBarPanelDidShow")
    /// Posted when the SwiftUI content tree changes height (accordion expand/collapse).
    static let menuBarContentSizeChanged = Notification.Name("menuBarContentSizeChanged")
    /// Posted when the largest in-flight accordion animation duration changes.
    /// The panel resize uses this duration so its NSAnimationContext matches
    /// the SwiftUI reveal in lockstep — large columns animate slower than
    /// small ones, but the panel and content always finish together.
    static let menuBarAnimationDurationChanged = Notification.Name("menuBarAnimationDurationChanged")
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
    private let yamete: Yamete
    private let templateIcon: NSImage?
    private var currentScreenFrame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 800)
    /// In-flight accordion animation duration, kept in sync with the largest
    /// visible accordion's per-row scaled duration. Defaults to the prior
    /// hardcoded 0.15s so the panel still animates if no preference arrives.
    private var currentAnimationDuration: Double = 0.15
    nonisolated(unsafe) private var contentSizeObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var animationDurationObserver: (any NSObjectProtocol)?

    init(settings: SettingsStore, yamete: Yamete, updater: Updater) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.yamete = yamete

        templateIcon = {
            guard let path = Bundle.main.path(forResource: "menubar_icon", ofType: "png"),
                  let img = NSImage(contentsOfFile: path),
                  let copy = img.copy() as? NSImage else { return nil }
            copy.size = NSSize(width: 18, height: 18)
            copy.isTemplate = true
            return copy
        }()

        panel = MenuBarPanel(
            contentView: MenuBarView()
                .environment(settings)
                .environment(yamete)
                .environment(yamete.menuBarFace)
                .environment(updater)
        )
        panel.onDismiss = { [weak self] in self?.removeMonitor() }

        guard let button = statusItem.button else { return }
        button.action = #selector(togglePanel)
        button.target = self

        applyIcon()
        observeIcon()

        // Block-based observer — StatusBarController is not an NSObject subclass so
        // selector-based addObserver silently drops the call.
        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: .menuBarContentSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let h = (notification.object as? NSNumber).map { CGFloat($0.doubleValue) }
            Task { @MainActor [weak self] in self?.applyContentHeight(h) }
        }

        // Track the largest in-flight accordion animation duration so the panel
        // resize duration matches the SwiftUI reveal. The preference is reduced
        // by max in MenuBarView, so this value is already the worst-case duration.
        animationDurationObserver = NotificationCenter.default.addObserver(
            forName: .menuBarAnimationDurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let d = (notification.object as? NSNumber).map { $0.doubleValue } ?? 0.15
            Task { @MainActor [weak self] in self?.currentAnimationDuration = d }
        }
    }

    deinit {
        if let obs = contentSizeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = animationDurationObserver { NotificationCenter.default.removeObserver(obs) }
        NotificationCenter.default.removeObserver(self)
        removeMonitor()
    }

    // MARK: - Status item icon

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        if let face = yamete.menuBarFace.reactionFace {
            button.image = face
            button.alphaValue = 1.0
        } else {
            button.image = templateIcon
            button.alphaValue = yamete.fusion.isRunning ? 1.0 : 0.4
        }
    }

    private func observeIcon() {
        withObservationTracking {
            _ = yamete.menuBarFace.reactionFace
            _ = yamete.fusion.isRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyIcon()
                self.observeIcon()
            }
        }
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
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }

            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            // Find the button's screen BEFORE sizing so we can pass the correct
            // height cap — NSScreen.main may be a different (larger) display.
            let buttonScreen = NSScreen.screens.first(where: {
                $0.frame.contains(buttonRect.origin)
            }) ?? NSScreen.main ?? NSScreen.screens.first
            let screenFrame = buttonScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            self.currentScreenFrame = screenFrame
            // Cap panel height to available space on this screen (40pt margin below menu bar).
            let maxPanelH = screenFrame.height - 40
            self.panel.sizeToContent(maxHeight: maxPanelH)

            let panelSize = self.panel.frame.size

            // Centre horizontally on the status item, then clamp to screen edges.
            let rawX = buttonRect.midX - panelSize.width / 2
            let clampedX = max(screenFrame.minX + 4, min(rawX, screenFrame.maxX - panelSize.width - 4))
            // Position below menu bar button; if panel is taller than space below, flip above.
            let rawY = buttonRect.minY - panelSize.height
            let clampedY = max(screenFrame.minY + 4, rawY)

            self.panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
            self.panel.makeKeyAndOrderFront(nil)

            // Second sizing pass: intrinsicContentSize may not reflect the final
            // SwiftUI layout until after the first render frame. Re-size after one
            // more yield so the panel snaps to content height on open.
            Task { @MainActor [weak self] in
                await Task.yield()
                await Task.yield()
                self?.applyContentHeight(nil)
            }
        }

        installMonitor()
    }

    private func dismissPanel() {
        panel.orderOut(nil)
        removeMonitor()
    }

    private func applyContentHeight(_ naturalH: CGFloat?) {
        guard panel.isVisible else { return }
        let maxH = currentScreenFrame.height - 40
        let previousTop = panel.frame.maxY
        let targetH: CGFloat
        if let naturalH, naturalH > 0 {
            targetH = min(naturalH, maxH)
        } else {
            // Fallback: query the hosting view directly
            let ideal = panel.intrinsicNaturalHeight()
            targetH = ideal == 0 ? panel.frame.height : min(ideal, maxH)
        }
        // Anchor the top edge: bottom-left origin Y = (top constant) - new height.
        // setFrame(_:display:animate:) uses NSWindow's built-in animator, matched
        // to the SwiftUI accordion animation (duration sourced from
        // `currentAnimationDuration`, set by the AccordionAnimationDurationKey
        // preference) so resize and content reveal happen together without
        // a visible frame snap.
        let newY = max(currentScreenFrame.minY + 4, previousTop - targetH)
        let newFrame = NSRect(x: panel.frame.origin.x, y: newY,
                              width: panel.frame.width, height: targetH)
        // Animate only if the change is small enough to feel like a UI animation;
        // big jumps (e.g., open from .zero) snap immediately.
        if abs(panel.frame.height - targetH) < 200 && panel.frame.height > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = currentAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: false)
        }
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

    /// Sizes the panel frame to the SwiftUI content's intrinsic size,
    /// capped to `maxHeight` so it never overflows the screen it lives on.
    func sizeToContent(maxHeight: CGFloat = .infinity) {
        // intrinsicContentSize returns SwiftUI's ideal unconstrained size.
        // fittingSize is constrained by the hosting view's current AutoLayout frame
        // and returns the panel's current height instead of the content height.
        let ideal = hostingView.intrinsicContentSize
        let h = maxHeight == .infinity ? ideal.height : min(ideal.height, maxHeight)
        setFrame(NSRect(origin: frame.origin, size: CGSize(width: ideal.width, height: h)), display: false)
    }

    /// Hosting view's intrinsic content height (SwiftUI ideal).
    /// Used by StatusBarController as a fallback when no notification height value is available.
    func intrinsicNaturalHeight() -> CGFloat {
        hostingView.intrinsicContentSize.height
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onDismiss?()
    }

    override var canBecomeKey: Bool { true }
}
