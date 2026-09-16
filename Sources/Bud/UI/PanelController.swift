import AppKit
import SwiftUI

/// Bud's window.
///
/// An ordinary one. It comes forward when clicked, goes behind when anything else
/// is activated, and takes part in Cmd-Tab and the window menu like every other
/// app's. It used to be a non-activating panel pinned above everything on every
/// Space, which made it impossible to work behind — an assistant you cannot put
/// down is one you close.
///
/// There was also a compact variant for a corner bubble. It is gone: Bud is in
/// the menu bar, which is the thing that is always there, and a second always-on
/// surface competing with it was one affordance too many.
final class BudWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Called when the user presses Escape. The controller decides what that
    /// means — hiding Bud, not ending it.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The window draws its own glass; the window itself must be invisible so
        // the backdrop layer can composite the desktop through it.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .documentWindow
        // Hidden rather than destroyed when closed: the way back is the Dock icon,
        // and a closed `NSWindow` cannot be ordered back on screen.
        isReleasedWhenClosed = false
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            orderOut(nil)
        }
    }
}

/// Owns Bud's window and its lifetime.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: BudWindow?
    private let model: AppModel

    private static let frameAutosaveName = "BudFloatingPanel"

    /// Bumped whenever the window's default shape changes.
    ///
    /// The saved frame is the user's, and normally deserves to win. But it was
    /// saved against a different default, and someone who has opened Bud before
    /// would otherwise never see the new one — their window would simply keep the
    /// old proportions for ever.
    private static let layoutVersion = 2
    private static let layoutVersionKey = "BudPanelLayoutVersion"

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The panel's frame, or nil before it has ever been shown.
    var expandedPanelFrame: NSRect? { panel?.frame }

    /// Whether the panel window is on screen right now.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    // MARK: - The window

    func makePanelIfNeeded() -> BudWindow {
        if let panel { return panel }
        let size = NSSize(width: Bud.panelWidth, height: Bud.panelHeight)
        let panel = BudWindow(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = NSHostingView(rootView: RootView(model: model))
        panel.onCancel = { [weak self] in self?.hide() }
        if panel.delegate == nil { panel.delegate = self }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        // `setFrameAutosaveName` gives no way to tell a restored frame from one
        // still sitting at the origin, so the restore is done explicitly and the
        // default placement only applies when there was genuinely nothing to
        // restore — or when what was restored is now off every screen, which
        // happens as soon as a display is unplugged.
        //
        // A frame saved by an older layout describes a window that no longer
        // exists. Restoring it would pin the window to the old shape and make a
        // changed default invisible to anyone who had ever opened the app before,
        // which is exactly the person most likely to notice.
        let shapeChanged = UserDefaults.standard.integer(forKey: Self.layoutVersionKey) != Self.layoutVersion
        let restored = shapeChanged ? false : panel.setFrameUsingName(Self.frameAutosaveName)
        // The size has to be set explicitly, not just left to the initial
        // `contentRect`: `setFrameAutosaveName` above restores the saved frame on
        // its own, so by this point the panel is already wearing the old shape
        // and skipping the second restore does not undo it. `positionTopTrailing`
        // only moves the window — it never resizes one.
        if shapeChanged {
            panel.setContentSize(size)
        }
        if !restored || !isOnAnyScreen(panel.frame) {
            positionTopTrailing(panel, size: size)
        }
        if shapeChanged {
            UserDefaults.standard.set(Self.layoutVersion, forKey: Self.layoutVersionKey)
            panel.saveFrame(usingName: Self.frameAutosaveName)
        }
        panel.minSize = NSSize(width: 560, height: 380)
        self.panel = panel
        return panel
    }

    // MARK: - State

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = makePanelIfNeeded()
        // A regular app is allowed to come forward, and a window that arrives
        // behind whatever you were reading is one you have to hunt for. This is
        // the difference between launching Bud and merely having launched it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Takes Bud off screen. This is what Escape does, and what the menu bar's
    /// Hide does — the resting state is the menu bar, not a window.
    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    /// The red button hides Bud; it does not end it.
    ///
    /// Closing the last window of a regular app normally leaves it running with
    /// nothing on screen, which for an assistant with a menu bar item and a Dock
    /// icon is exactly right — the way back is the icon you just used. Tearing the
    /// window down instead would leave `makePanelIfNeeded` returning a closed
    /// window that can never be ordered back on screen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: - Placement

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
}
