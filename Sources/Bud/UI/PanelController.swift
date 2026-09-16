import AppKit
import SwiftUI

/// Bud's windows.
///
/// Two shapes with opposite jobs. The full panel is an ordinary window: it comes
/// forward when clicked, goes behind when anything else is activated, and takes
/// part in Cmd-Tab and the window menu like every other app's. It used to be a
/// non-activating panel pinned above everything on every Space, which made it
/// impossible to work behind — an assistant you cannot put down is one you close.
///
/// The collapsed bubble keeps the widget behaviour, because that is what it is
/// for: parked in a corner, answering a click from whatever you are doing. It is
/// only ever reached by asking for it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !isCompact }

    /// Called when the user presses Escape. The controller decides what that
    /// means — collapsing back to the bubble, not vanishing.
    var onCancel: (() -> Void)?

    private let isCompact: Bool

    /// A compact bubble is borderless and has no resize chrome; the full panel is
    /// a titled, resizable window. Everything else about the two is identical.
    init(contentRect: NSRect, compact: Bool = false) {
        self.isCompact = compact
        super.init(
            contentRect: contentRect,
            styleMask: compact
                ? [.nonactivatingPanel, .borderless]
                : [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        if compact {
            isFloatingPanel = true
            // Above normal windows, below the menu bar and system alerts.
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            // `.normal` and no `canJoinAllSpaces` are the whole change: the panel
            // now has an order in the window stack that the user controls.
            isFloatingPanel = false
            level = .normal
            collectionBehavior = [.fullScreenAuxiliary]
        }
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The panel draws its own glass; the window must be invisible so the
        // backdrop layer can composite the desktop through it.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The bubble is dragged by its own SwiftUI gesture, not by the window
        // server, because a window-background drag would swallow the click that
        // expands it.
        isMovableByWindowBackground = !compact
        hidesOnDeactivate = false
        animationBehavior = compact ? .utilityWindow : .documentWindow
        // Reopened rather than recreated: the controller hides this window when
        // it is closed, and a closed `NSWindow` cannot be ordered back on screen.
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

/// Which screen corner the collapsed bubble parks in.
enum PillCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isRight: Bool { self == .topRight || self == .bottomRight }
    /// AppKit's y axis grows upward, so "top" is the larger y.
    var isTop: Bool { self == .topLeft || self == .topRight }
}

/// Owns both shapes Bud can wear, and the transition between them.
///
/// Two windows rather than one resizing window: the full panel keeps its
/// transcript, scroll position and tab selection while collapsed, because
/// ordering a window out does not tear down its SwiftUI state. Resizing a single
/// window would rebuild the view tree on every collapse.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var pill: FloatingPanel?
    private let model: AppModel

    private var isCollapsed = false
    /// Where the bubble was when a drag began, so the drag can be applied as an
    /// absolute offset rather than accumulated deltas.
    private var dragOrigin: NSPoint?

    private static let frameAutosaveName = "BudFloatingPanel"

    /// Bumped whenever the panel's default shape changes.
    ///
    /// The saved frame is the user's, and normally deserves to win. But it was
    /// saved against a different default, and someone who has opened Bud before
    /// would otherwise never see the new one — their window would simply keep the
    /// old proportions for ever.
    private static let layoutVersion = 2
    private static let layoutVersionKey = "BudPanelLayoutVersion"
    private static let pillCornerKey = "bud.pillCorner"
    private static let pillDiameter: CGFloat = 56
    private static let pillInset: CGFloat = 18

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool {
        isCollapsed ? (pill?.isVisible ?? false) : (panel?.isVisible ?? false)
    }

    var showingCollapsed: Bool { isCollapsed }

    /// The bubble window, or nil before it has ever been shown. Exposed so the
    /// two window behaviours can be told apart by assertion rather than by
    /// reading the constructor.
    var bubbleWindow: NSPanel? { pill }

    /// The bubble's frame, or nil before it has ever been shown. Exposed so
    /// placement can be asserted rather than eyeballed.
    var collapsedBubbleFrame: NSRect? { pill?.frame }

    /// The full panel's frame, or nil before it has ever been shown.
    var expandedPanelFrame: NSRect? { panel?.frame }

    /// Whether the full panel window is on screen right now.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// Whether the bubble window is on screen right now.
    var isBubbleVisible: Bool { pill?.isVisible ?? false }

    // MARK: - Full panel

    func makePanelIfNeeded() -> FloatingPanel {
        if let panel { return panel }
        let size = NSSize(width: Bud.panelWidth, height: Bud.panelHeight)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
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
        // A frame saved by an older layout describes a panel that no longer
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

    // MARK: - Collapsed bubble

    private func makePillIfNeeded() -> FloatingPanel {
        if let pill { return pill }
        let side = Self.pillDiameter
        let pill = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            compact: true
        )
        pill.contentView = NSHostingView(
            rootView: CollapsedPill(
                model: model,
                onExpand: { [weak self] in self?.expand() },
                onDrag: { [weak self] translation in self?.dragPill(by: translation) },
                onDragEnd: { [weak self] in self?.endPillDrag() }
            )
        )
        pill.onCancel = { [weak self] in self?.expand() }
        self.pill = pill
        placePill(at: storedCorner(), on: screenContainingPanel())
        return pill
    }

    private func dragPill(by translation: CGSize) {
        guard let pill else { return }
        let start = dragOrigin ?? pill.frame.origin
        dragOrigin = start
        // SwiftUI reports a downward-positive y; AppKit's origin is bottom-left.
        pill.setFrameOrigin(
            NSPoint(x: start.x + translation.width, y: start.y - translation.height)
        )
    }

    private func endPillDrag() {
        dragOrigin = nil
        guard let pill else { return }
        if let screen = screenContainingPanel() ?? NSScreen.screens.first {
            let corner = nearestCorner(for: pill.frame, in: screen)
            UserDefaults.standard.set(corner.rawValue, forKey: Self.pillCornerKey)
            placePill(at: corner, on: screen)
        }
    }

    private func nearestCorner(for frame: NSRect, in screen: NSScreen) -> PillCorner {
        let visible = screen.visibleFrame
        let isRight = frame.midX > visible.midX
        let isTop = frame.midY > visible.midY
        switch (isTop, isRight) {
        case (true, true): return .topRight
        case (true, false): return .topLeft
        case (false, true): return .bottomRight
        case (false, false): return .bottomLeft
        }
    }

    private func storedCorner() -> PillCorner {
        guard let raw = UserDefaults.standard.string(forKey: Self.pillCornerKey),
              let corner = PillCorner(rawValue: raw) else { return .topRight }
        return corner
    }

    private func placePill(at corner: PillCorner, on screen: NSScreen?) {
        guard let pill, let screen = screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let side = Self.pillDiameter
        let inset = Self.pillInset
        let origin = NSPoint(
            x: corner.isRight ? visible.maxX - side - inset : visible.minX + inset,
            y: corner.isTop ? visible.maxY - side - inset : visible.minY + inset
        )
        pill.setFrameOrigin(origin)
    }

    private func screenContainingPanel() -> NSScreen? {
        let reference = panel?.frame ?? pill?.frame
        guard let reference else { return NSScreen.screens.first }
        return NSScreen.screens.first { $0.visibleFrame.intersects(reference) }
            ?? NSScreen.screens.first
    }

    // MARK: - State

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Brings up the full panel.
    ///
    /// Always the panel, never the bubble: Bud starts hidden, so summoning it
    /// should hand over the thing you can talk to rather than a 56pt circle you
    /// then have to click a second time.
    func show() {
        isCollapsed = false
        let panel = makePanelIfNeeded()
        pill?.orderOut(nil)
        // A regular app is allowed to come forward, and a window that arrives
        // behind whatever you were reading is one you have to hunt for. This is
        // the difference between launching Bud and merely having launched it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Takes Bud off screen entirely. This is what Escape does, and what the
    /// menu bar's Hide does — the resting state is now the menu bar, not a
    /// window.
    func hide() {
        panel?.orderOut(nil)
        pill?.orderOut(nil)
    }

    /// Parks Bud in a screen corner as a bubble.
    ///
    /// Only ever reached from the panel's own collapse control. Nothing does this
    /// on the user's behalf, because a window that puts itself back on screen
    /// after being dismissed is the definition of intrusive.
    func collapse() {
        isCollapsed = true
        let pill = makePillIfNeeded()
        panel?.orderOut(nil)
        pill.orderFrontRegardless()
    }

    /// Restores the full panel and puts the caret in the composer, so a click on
    /// the bubble lands ready to type.
    func expand() {
        show()
        model.focusComposer()
    }

    func close() {
        panel?.close()
        pill?.close()
        panel = nil
        pill = nil
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
