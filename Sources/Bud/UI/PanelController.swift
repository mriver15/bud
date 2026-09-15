import AppKit
import SwiftUI

/// The floating panel.
///
/// `nonactivatingPanel` is what makes this feel like a widget rather than an app:
/// summoning it does not steal focus from whatever the user was typing in, and
/// clicking it does not pull the whole application forward.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above normal windows, below the menu bar and system alerts.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The panel draws its own glass; the window must be invisible so the
        // backdrop layer can composite the desktop through it.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        // A widget should never be the thing that traps the user.
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Owns the panel's lifetime, placement and visibility.
@MainActor
final class PanelController {
    private var panel: FloatingPanel?
    private var hotKey: GlobalHotKey?
    private let model: AppModel

    private static let frameAutosaveName = "BudFloatingPanel"

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func makePanelIfNeeded() -> FloatingPanel {
        if let panel { return panel }
        let size = NSSize(width: Bud.panelWidth, height: Bud.panelHeight)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = NSHostingView(rootView: RootView(model: model))
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        // `setFrameAutosaveName` gives no way to tell a restored frame from one
        // still sitting at the origin, so the restore is done explicitly and the
        // default placement only applies when there was genuinely nothing to
        // restore — or when what was restored is now off every screen, which
        // happens as soon as a display is unplugged.
        let restored = panel.setFrameUsingName(Self.frameAutosaveName)
        if !restored || !isOnAnyScreen(panel.frame) {
            positionTopTrailing(panel, size: size)
        }
        panel.minSize = NSSize(width: 380, height: 420)
        self.panel = panel
        return panel
    }

    private func isOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    /// Default placement: tucked into the top-right of the screen the user is
    /// working on, inset from the menu bar. Only used when there is no usable
    /// saved frame.
    private func positionTopTrailing(_ panel: NSPanel, size: NSSize) {
        // `NSScreen.main` tracks the key window and is unreliable before any
        // window is key — which is exactly when this runs — so the screen under
        // the pointer is used instead.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let inset: CGFloat = 16
        let origin = NSPoint(
            x: visible.maxX - size.width - inset,
            y: visible.maxY - size.height - inset
        )
        panel.setFrameOrigin(origin)
    }

    func installHotKey() {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey.summon { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = makePanelIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        // Bring the panel forward without activating the app, preserving the
        // non-activating behaviour.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
