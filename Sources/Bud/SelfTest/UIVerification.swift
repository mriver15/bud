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
        // A normal window, and these are what "normal" means: it sits at the
        // ordinary level so anything can be put in front of it, it activates the
        // app so clicking it does not leave focus in another window, and it
        // stays on the Space it was opened on instead of following the user
        // everywhere. The floating panel these replaced was the feature; it made
        // Bud impossible to work behind.
        c.check("panel is an ordinary window, not a floating one", panel.level == .normal)
        c.check("panel activates the app", !panel.styleMask.contains(.nonactivatingPanel))
        c.check("panel does not follow across spaces", !panel.collectionBehavior.contains(.canJoinAllSpaces))
        c.check("panel can become the main window", panel.canBecomeMain)
        c.check("panel is not a floating panel", !panel.isFloatingPanel)
        c.check(
            "panel has standard window controls",
            panel.styleMask.contains(.miniaturizable) && panel.styleMask.contains(.closable)
        )

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

        // MARK: Starting a new chat

        // Now the most prominent control in the header and the `/new` command,
        // and it had no coverage at all. What is worth pinning is the part that
        // fails silently: the conversation being left behind has to be written
        // out first, or starting a chat loses one.
        let leaving = model.currentConversationID
        model.newConversation()
        c.check(
            "a new chat mints a new conversation",
            model.currentConversationID != nil && model.currentConversationID != leaving
        )
        c.check("a new chat starts an empty transcript", model.turns.isEmpty)
        c.check("a new chat clears the composer", model.composerText.isEmpty)

        // MARK: A generated surface can be screenshotted

        // Seeded through the same restore path a reopened conversation uses,
        // so the block is drawn by the real transcript rather than a fixture.
        let surfaceSpec: JSONValue = .object([
            "title": .string("Screenshot check"),
            "components": .array([
                .object([
                    "type": .string("text"),
                    "value": .string("This block can be captured to a file."),
                ]),
            ]),
        ])
        model.runtime.restore(
            turns: [
                Turn(role: .assistant, segments: [
                    .text(id: "surface-prose", text: "Here is the surface:"),
                    .ui(id: "surface-block", payload: surfaceSpec),
                ]),
            ],
            history: []
        )
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        if let content = panel.contentView, let anchor = findAnchor(in: content) {
            c.check("a surface block carries its capture anchor", true)
            if let png = SurfaceCapture.png(for: surfaceSpec, size: anchor.bounds.size) {
                c.check("the block captures to real pixels (\(BudFormat.count(png.count)) bytes)",
                        png.count > 1_000)
                c.check("...and they decode as a PNG image", NSBitmapImageRep(data: png) != nil)
                c.check("...with real content, not a blank fill (\(distinctColours(png)) colours)",
                        distinctColours(png) >= 8)
                if let url = SurfaceCapture.save(png) {
                    c.check("...and the capture lands in the screenshots directory",
                            FileManager.default.fileExists(atPath: url.path))
                    try? FileManager.default.removeItem(at: url)
                } else {
                    c.check("...and the capture lands in the screenshots directory", false)
                }
            } else {
                c.check("the block captures to real pixels", false)
            }
        } else {
            c.check("a surface block carries its capture anchor", false)
        }

        // MARK: Hiding and coming back

        // Closing hides Bud and leaves the window object alone, because the way
        // back is the Dock icon — a closed `NSWindow` cannot be ordered back on
        // screen, so an app that destroyed its window here would answer the icon
        // with nothing.
        controller.hide()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        c.check("hiding takes the panel off screen", !controller.isPanelVisible)
        c.check("the window survives being closed", panel.isReleasedWhenClosed == false)

        controller.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Not `isKeyWindow`: whether a window can become key depends on the
        // session having an active app, and this harness may run with the screen
        // locked. That the hidden window becomes visible again is the claim worth
        // making here, and it is the one that breaks if the window was destroyed.
        c.check("the panel comes back after being hidden", controller.isPanelVisible)
        c.check("the panel can take key focus", panel.canBecomeKey)

        // MARK: The directives writer renders in Memory settings

        // The standing-instructions field is the writer side of the directive
        // retrieval path. Settings opens as a WindowGroup scene, which this
        // harness does not run — so the pane is hosted in a scratch window the
        // same way the render tool hosts surfaces. SwiftUI's TextField is a
        // real NSTextField on macOS, so the placeholder is checkable in the
        // view tree once the pane has laid out.
        let memoryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        memoryWindow.contentView = NSHostingView(rootView: MemorySettingsView())
        memoryWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        c.check("the directives field renders in the memory pane",
                memoryWindow.contentView.map { findDirectiveField(in: $0) } == true)
        memoryWindow.close()

        // MARK: The Jev model field renders in Settings

        // The same scratch-window technique, for the row that pins the model a
        // Jev call is sent to. Worth a real render rather than trust: the field
        // is one line in a pane of twenty, and a row that never appears is
        // indistinguishable from a pin that was never applied. The pane's stack
        // is not lazy, so the row is built whether or not it is scrolled into
        // view — which is what makes the placeholder a usable marker.
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        settingsWindow.contentView = NSHostingView(
            rootView: SettingsView(model: model, initialTab: .general)
        )
        settingsWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        c.check(
            "the Jev model field renders in settings",
            settingsWindow.contentView.map {
                containsTextField(placeholderContaining: JevDecisionEngine.defaultModel, in: $0)
            } == true
        )
        settingsWindow.close()

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

    private static func findAnchor(in view: NSView) -> NSView? {
        if view is SurfaceAnchorView { return view }
        for sub in view.subviews {
            if let found = findAnchor(in: sub) { return found }
        }
        return nil
    }

    private static func findDirectiveField(in view: NSView) -> Bool {
        containsTextField(placeholderContaining: "destructive", in: view)
    }

    /// Whether a text field with a placeholder containing `text` is in the tree.
    ///
    /// SwiftUI's `TextField` is a real `NSTextField` on macOS, so a rendered
    /// field is checkable by the placeholder it was given — which is the only
    /// part of a plain field that identifies it in the view tree.
    private static func containsTextField(placeholderContaining text: String, in view: NSView) -> Bool {
        if let field = view as? NSTextField,
           field.placeholderString?.contains(text) == true { return true }
        return view.subviews.contains { containsTextField(placeholderContaining: text, in: $0) }
    }

    /// Counts distinct quantised colours in a coarse sample of a PNG. A flat
    /// fill yields one or two; anything real — text, tints, glass edges —
    /// yields dozens. The same guard `--render-ui` uses before it accepts a
    /// render as non-blank.
    private static func distinctColours(_ png: Data) -> Int {
        guard let rep = NSBitmapImageRep(data: png) else { return 0 }
        let step = max(1, rep.pixelsWide / 120)
        var distinct: Set<Int> = []
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let colour = rep.colorAt(x: x, y: y) {
                    let r = Int(colour.redComponent * 31)
                    let g = Int(colour.greenComponent * 31)
                    let b = Int(colour.blueComponent * 31)
                    let a = Int(colour.alphaComponent * 31)
                    distinct.insert(r << 15 | g << 10 | b << 5 | a)
                }
                x += step
            }
            y += step
        }
        return distinct.count
    }
}
