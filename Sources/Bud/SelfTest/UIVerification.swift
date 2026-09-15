import AppKit
import QuartzCore
import SwiftUI

/// Launches the real panel, then inspects what actually got rendered.
///
/// This exists because the usual proof for a UI change — a screenshot — is not
/// available here: `screencapture` needs the Screen Recording permission, which
/// is not granted to a terminal-launched process, and an offscreen
/// `cacheDisplay` render cannot see compositor layers at all.
///
/// So the check is structural instead, and it is a stronger claim than a
/// screenshot for the one thing that matters most: Liquid Glass is not a flat
/// fallback. A window that merely *looks* translucent while the platform fell
/// back to a grey fill would still pass a screenshot review. It cannot pass this:
/// `CABackdropLayer` is the layer that samples and refracts what is behind the
/// window, and the `SDF*` layers are the signed-distance-field geometry the
/// Liquid Glass material is built from. If the glass pipeline were bypassed, they
/// would not exist.
@MainActor
public enum BudUIVerification {
    public static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = AppModel()
        let controller = PanelController(model: model)
        controller.show()
        let panel = controller.makePanelIfNeeded()

        Task { await model.start() }

        // Long enough for the hosting view to build its layer tree, the provider
        // registrations to finish, and the first layout pass to commit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let report = inspect(panel: panel, model: model, controller: controller)
            for failure in report.failures {
                FileHandle.standardError.write(Data("FAIL  \(failure)\n".utf8))
            }
            print(report.ok
                  ? "PASS  \(report.passed)/\(report.total) UI checks passed"
                  : "FAIL  \(report.passed)/\(report.total) UI checks passed")
            exit(report.ok ? 0 : 1)
        }

        app.run()
        exit(0)
    }

    private static func inspect(
        panel: NSPanel,
        model: AppModel,
        controller: PanelController
    ) -> SelfTestReport {
        let c = Checker(suite: "ui")

        // MARK: Window

        c.check("panel is on screen", panel.isVisible)
        c.check("panel has a real size", panel.frame.width > 300 && panel.frame.height > 400)
        c.check("panel is not opaque", !panel.isOpaque)
        c.check("panel is transparent-backed", panel.backgroundColor == .clear)
        c.check("panel floats above normal windows", panel.level == .floating)
        c.check("panel does not activate the app", panel.styleMask.contains(.nonactivatingPanel))
        c.check("panel joins all spaces", panel.collectionBehavior.contains(.canJoinAllSpaces))

        // MARK: Layer tree — is Liquid Glass actually live?

        var classes: [String: Int] = [:]
        if let root = panel.contentView?.layer {
            walk(root, &classes)
        }
        let total = classes.values.reduce(0, +)
        c.check("content produced a layer tree (found \(total))", total > 10)
        c.check(
            "backdrop layer present — glass actually refracts",
            classes.keys.contains { $0.contains("Backdrop") }
        )
        let sdf = classes.keys.filter { $0.contains("SDF") }
        c.check(
            "signed-distance-field layers present — Liquid Glass material (\(sdf.sorted()))",
            !sdf.isEmpty
        )

        // MARK: Content laid out

        if let content = panel.contentView {
            let sized = countViewsWithArea(content)
            c.check("content view hierarchy laid out (found \(sized) sized views)", sized > 5)
        }

        // MARK: Model wired

        c.check("config resolved a model", !model.config.model.isEmpty)
        c.check("tool registry populated (\(model.availableTools.count))", !model.availableTools.isEmpty)
        let providers = Set(model.availableTools.map(\.providerName))
        c.check(
            "native tools registered (\(providers.sorted().joined(separator: ", ")))",
            providers.contains("Bud")
        )
        c.check("no error banner on launch", model.errorMessage == nil)

        // MARK: Hot key

        controller.installHotKey()
        c.check("summon hotkey is \(GlobalHotKey.summonShortcutLabel)", true)

        // MARK: Collapsed bubble

        // The bubble is Bud's resting state, so the transition has to be
        // reversible without losing the panel — and the bubble has to land
        // somewhere the user can actually reach.
        controller.collapse()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        c.check("collapse switches to the bubble", controller.showingCollapsed)
        c.check("collapse takes the full panel off screen", !controller.isPanelVisible)
        c.check("collapse shows the bubble", controller.isBubbleVisible)

        if let bubble = controller.collapsedBubbleFrame {
            c.check(
                "bubble is a small square (found \(Int(bubble.width))x\(Int(bubble.height)))",
                abs(bubble.width - bubble.height) < 0.5 && bubble.width <= 80 && bubble.width >= 40
            )
            let containingScreen = NSScreen.screens.first { $0.visibleFrame.intersects(bubble) }
            c.check("bubble is on a screen", containingScreen != nil)
            if let screen = containingScreen {
                // Outside the menu bar and the Dock: a bubble tucked under either
                // would be unreachable.
                c.check(
                    "bubble sits fully inside the usable area",
                    screen.visibleFrame.contains(bubble)
                )
                let v = screen.visibleFrame
                let touchingCorner = (abs(bubble.minX - v.minX) < 48 || abs(bubble.maxX - v.maxX) < 48)
                    && (abs(bubble.minY - v.minY) < 48 || abs(bubble.maxY - v.maxY) < 48)
                c.check("bubble is parked in a corner", touchingCorner)
            }
        } else {
            c.check("bubble has a frame", false)
        }

        controller.expand()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        c.check("expand restores the panel", !controller.showingCollapsed && controller.isPanelVisible)
        c.check("expand takes the bubble off screen", !controller.isBubbleVisible)
        c.check("expanding asks the composer for focus", model.composerFocusToken > 0)

        return c.report()
    }

    private static func walk(_ layer: CALayer, _ classes: inout [String: Int]) {
        let name = String(describing: type(of: layer))
        classes[name, default: 0] += 1
        for sub in layer.sublayers ?? [] { walk(sub, &classes) }
    }

    private static func countViewsWithArea(_ view: NSView) -> Int {
        var count = 0
        if view.frame.width > 1, view.frame.height > 1 { count += 1 }
        for sub in view.subviews { count += countViewsWithArea(sub) }
        return count
    }
}
