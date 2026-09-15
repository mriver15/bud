import AppKit
import SwiftUI

public struct BudApp: App {
    public static let settingsWindowID = "bud-settings"

    /// Models offered in the header picker. DeepSeek accepts other aliases and
    /// silently maps unknown names to flash, so the Settings field stays free-text.
    public static let selectableModels: [(id: String, label: String)] = [
        ("deepseek-v4-flash", "DeepSeek V4 Flash"),
        ("deepseek-v4-pro", "DeepSeek V4 Pro"),
    ]

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: delegate.model)
        } label: {
            Image(systemName: "sparkle")
        }
        .menuBarExtraStyle(.window)

        Window("Bud", id: Self.settingsWindowID) {
            SettingsHost(model: delegate.model)
        }
        .defaultSize(width: 900, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    delegate.model.openSettings(tab: .general)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("New Chat") { delegate.model.clearTranscript() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

/// Hosts the settings surface in its own window, including the glass panel
/// chrome so it matches the floating panel rather than looking like a stock
/// settings sheet.
private struct SettingsHost: View {
    @Bindable var model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        GlassPanel(cornerRadius: 18) {
            SettingsView(model: model, initialTab: model.settingsTab)
                .frame(minWidth: 820, minHeight: 560)
        }
        .padding(Bud.Space.md)
        .background(Color.clear)
        .task { await model.start() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panels: PanelController?
    private var toggleObserver: NSObjectProtocol?
    private var hideObserver: NSObjectProtocol?
    private var collapseObserver: NSObjectProtocol?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no app switcher entry. Bud is summoned, not
        // launched into — this is the difference between a widget and an app.
        NSApp.setActivationPolicy(.accessory)

        let panels = PanelController(model: model)
        self.panels = panels
        panels.installHotKey()
        // Deliberately no window at launch. Bud lives in the menu bar and puts
        // nothing on screen until it is asked to — an assistant that reappears
        // in the corner every time you log in is one you learn to resent.
        // `⌥⌘B`, the menu bar, or a bud:// link bring it up.

        toggleObserver = NotificationCenter.default.addObserver(
            forName: .budTogglePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.toggle() }
        }

        hideObserver = NotificationCenter.default.addObserver(
            forName: .budHidePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.hide() }
        }

        collapseObserver = NotificationCenter.default.addObserver(
            forName: .budCollapsePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.collapse() }
        }

        // `bud://` links arrive as Apple events. Handled here rather than through
        // SwiftUI's `onOpenURL` because that requires a Window scene to be the
        // focus, and Bud is normally driven entirely from the panel.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        Task { await model.start() }
    }

    /// `bud://ask?text=…` sends a message, `bud://toggle` collapses or expands,
    /// `bud://collapse` and `bud://expand` set the shape explicitly,
    /// `bud://settings?tab=marketplace` opens that settings pane, and `bud://new`
    /// starts a fresh transcript. Anything else is ignored — an
    /// unrecognised link must never leave the app in a half-open state.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated { handle(url) }
    }

    private func handle(_ url: URL) {
        let route = url.host()?.lowercased() ?? ""
        switch route {
        case "ask":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let text = items.first { $0.name == "text" }?.value ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Expand rather than `show()`: asking from a link is a deliberate
            // question, so the answer should be on screen when it arrives.
            panels?.expand()
            Task { await model.send(trimmed) }

        case "toggle":
            panels?.toggle()

        case "collapse":
            panels?.collapse()

        case "expand":
            panels?.expand()

        case "settings":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let requested = items.first { $0.name == "tab" }?.value ?? ""
            model.openSettings(tab: SettingsTab(rawValue: requested) ?? .general)
            NSApp.activate(ignoringOtherApps: true)

        case "new":
            model.clearTranscript()
            panels?.show()

        default:
            break
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Task {
            // Give MCP child processes a chance to die cleanly rather than
            // leaving orphaned node/python servers behind after quit.
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
