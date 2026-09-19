import AppKit
import SwiftUI

public struct BudApp: App {
    public static let settingsWindowID = "bud-settings"


    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: delegate.model)
        } label: {
            // The label is the one view that exists from launch, so the settings
            // handler has to be registered here. Registering it in the panel
            // instead — as it was — meant `bud://settings` silently did nothing
            // until the panel had been opened at least once, because the panel
            // is now created lazily and Bud starts hidden.
            BudMenuBarLabel(model: delegate.model)
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
            // In the menu, not on a hidden button: this is the only place the
            // shortcuts are discoverable at all, and a shortcut nobody can find
            // is a shortcut nobody has.
            CommandGroup(after: .toolbar) {
                Button("Find in Chat") {
                    NotificationCenter.default.post(name: .budShowPanel, object: nil)
                    NotificationCenter.default.post(name: .budShowChat, object: nil)
                    NotificationCenter.default.post(name: .budFindInChat, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Command Palette") {
                    NotificationCenter.default.post(name: .budShowPanel, object: nil)
                    NotificationCenter.default.post(name: .budShowChat, object: nil)
                    NotificationCenter.default.post(name: .budCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

/// The menu bar icon, which also wires up settings presentation.
private struct BudMenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "sparkle")
            .task {
                model.onPresentSettings = { tab in
                    model.settingsTab = tab
                    openWindow(id: BudApp.settingsWindowID)
                    NSApp.activate(ignoringOtherApps: true)
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
    private var showObserver: NSObjectProtocol?
    private var hideObserver: NSObjectProtocol?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no app switcher entry. Bud is summoned, not
        // launched into — this is the difference between a widget and an app.

        // Quitting is what makes an update stick. `open` on an app that is still
        // running only brings the old instance forward, so the updater spawns a
        // helper and then has to actually stop — which it could not do, because
        // nothing had ever given it a way out.
        model.onQuit = { NSApp.terminate(nil) }

        let panels = PanelController(model: model)
        self.panels = panels
        // Launching Bud opens Bud.
        //
        // It used to open nothing at all — the app was a menu bar agent that had
        // to be summoned, on the theory that anything which reappeared unbidden
        // every login would be resented. It is not that any more: nothing starts
        // it but a person, so arriving from the Dock or Spotlight and getting no
        // window is indistinguishable from a launch that failed.
        panels.show()

        toggleObserver = NotificationCenter.default.addObserver(
            forName: .budTogglePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.toggle() }
        }

        showObserver = NotificationCenter.default.addObserver(
            forName: .budShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.show() }
        }

        hideObserver = NotificationCenter.default.addObserver(
            forName: .budHidePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.hide() }
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

        // The Services entry ("Ask Bud about this") is declared in the bundle's
        // NSServices list; this is what gives it an object to message. The
        // dynamic-services update is what makes a freshly-built bundle's entry
        // appear without a relaunch or a log out — the services database holds
        // the copy it read the last time this app was registered.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        Task { await model.start() }
    }

    /// `bud://ask?text=…` stages a question in the composer, `bud://toggle` shows
    /// or hides Bud, `bud://settings?tab=marketplace` opens that settings pane,
    /// `bud://history` shows the archive, and `bud://new` starts a fresh
    /// conversation. Anything else is ignored — an unrecognised link must never
    /// leave the app in a half-open state.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated { handle(url) }
    }

    /// Internal rather than private so the self-test can put a link through it.
    /// What each route is allowed to do is the point of the whole function, and
    /// the one that matters most — `ask` — is the one a regression would turn
    /// back into running on its own.
    func handle(_ url: URL) {
        let route = url.host()?.lowercased() ?? ""
        switch route {
        case "ask":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let text = items.first { $0.name == "text" }?.value ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Staged, never sent. Any local process, script or Shortcuts action
            // can open a `bud://` link, and the agent this would have started is
            // one with `run_shell` in its hands — so the question waits in the
            // composer for a person to press Send, exactly as the Services entry
            // does. The scheme, the route and the `?text=` parameter are
            // unchanged; who confirms is what changed.
            model.compose(trimmed, reveal: true)

        case "toggle":
            panels?.toggle()

        case "settings":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let requested = items.first { $0.name == "tab" }?.value ?? ""
            model.openSettings(tab: SettingsTab(rawValue: requested) ?? .general)
            NSApp.activate(ignoringOtherApps: true)

        case "history":
            model.surface = .history
            panels?.show()

        case "new":
            model.surface = .chat
            model.clearTranscript()
            panels?.show()

        default:
            break
        }
    }

    /// Services entry point for "Ask Bud about this".
    ///
    /// The selector name has to match `NSMessage` in the bundle's NSServices
    /// declaration, and the selection arrives on the general pasteboard rather
    /// than as an argument. Both out-parameters are optional because the system
    /// passes nil for a service that declares neither user data nor an error —
    /// a non-optional bridge would trap on the first invocation.
    ///
    /// Staged, never sent. The entry exists so that a selection can be carried
    /// across without a copy and paste; it is not an answer to a question the
    /// user has not finished asking.
    @objc func askBud(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else { return }
        model.compose(text, reveal: true)
    }

    /// Clicking the Dock icon with no window up brings the panel back. Without
    /// this the icon does nothing once the window has been closed, which is the
    /// one moment a person is most likely to click it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { panels?.show() }
        return true
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
