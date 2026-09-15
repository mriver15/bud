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
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no app switcher entry. Bud is summoned, not
        // launched into — this is the difference between a widget and an app.
        NSApp.setActivationPolicy(.accessory)

        let panels = PanelController(model: model)
        self.panels = panels
        panels.installHotKey()
        panels.show()

        toggleObserver = NotificationCenter.default.addObserver(
            forName: .budTogglePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels?.toggle() }
        }

        Task { await model.start() }
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
