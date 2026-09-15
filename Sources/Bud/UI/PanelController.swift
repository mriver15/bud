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

    /// Called when the user presses Escape. The controller decides what that
    /// means — collapsing back to the bubble, not vanishing.
    var onCancel: (() -> Void)?

    /// A compact bubble is borderless and has no resize chrome; the full panel is
    /// a titled, resizable window. Everything else about the two is identical.
    init(contentRect: NSRect, compact: Bool = false) {
        super.init(
            contentRect: contentRect,
            styleMask: compact
                ? [.nonactivatingPanel, .borderless]
                : [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
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
        // The bubble is dragged by its own SwiftUI gesture, not by the window
        // server, because a window-background drag would swallow the click that
        // expands it.
        isMovableByWindowBackground = !compact
        // A widget should never be the thing that traps the user.
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        if !compact {
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
        }
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
final class PanelController {
    private var panel: FloatingPanel?
    private var pill: FloatingPanel?
    private var hotKey: GlobalHotKey?
    private let model: AppModel

    private var isCollapsed = false
    /// Where the bubble was when a drag began, so the drag can be applied as an
    /// absolute offset rather than accumulated deltas.
    private var dragOrigin: NSPoint?

    private static let frameAutosaveName = "BudFloatingPanel"
    private static let collapsedKey = "bud.collapsed"
    private static let pillCornerKey = "bud.pillCorner"
    private static let pillDiameter: CGFloat = 56
    private static let pillInset: CGFloat = 18

    init(model: AppModel) {
        self.model = model
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.collapsedKey) != nil {
            isCollapsed = defaults.bool(forKey: Self.collapsedKey)
        }
    }

    var isVisible: Bool {
        isCollapsed ? (pill?.isVisible ?? false) : (panel?.isVisible ?? false)
    }

    var showingCollapsed: Bool { isCollapsed }

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
        panel.onCancel = { [weak self] in self?.collapse() }
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

    func installHotKey() {
        guard hotKey == nil else { return }
        // One shortcut for the whole cycle: hidden and collapsed both open, open
        // collapses. Anything else would need the user to remember which shape
        // Bud is currently in.
        hotKey = GlobalHotKey.summon { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        if isCollapsed { expand() } else { collapse() }
    }

    /// Shows Bud in whichever shape it was last left in.
    func show() {
        if isCollapsed {
            makePillIfNeeded().orderFrontRegardless()
        } else {
            let panel = makePanelIfNeeded()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        pill?.orderOut(nil)
    }

    /// Collapses the full panel into the corner bubble.
    func collapse() {
        guard !isCollapsed else { return }
        isCollapsed = true
        UserDefaults.standard.set(true, forKey: Self.collapsedKey)
        let pill = makePillIfNeeded()
        panel?.orderOut(nil)
        pill.orderFrontRegardless()
    }

    /// Restores the full panel and puts the caret in the composer, so a click on
    /// the bubble lands ready to type.
    func expand() {
        guard isCollapsed else {
            show()
            model.focusComposer()
            return
        }
        isCollapsed = false
        UserDefaults.standard.set(false, forKey: Self.collapsedKey)
        let panel = makePanelIfNeeded()
        pill?.orderOut(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusComposer()
    }

    func close() {
        panel?.close()
        pill?.close()
        panel = nil
        pill = nil
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
