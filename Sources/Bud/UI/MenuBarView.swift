import AppKit
import SwiftUI

/// The menu bar dropdown. Everything the panel can do, plus the actions that
/// only make sense when the panel is hidden.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            header
            Divider().opacity(0.3)
            panelActions
            updateActions
            recentActions
            Divider().opacity(0.3)
            settingsActions
            Divider().opacity(0.3)
            footer
        }
        .padding(Bud.Space.md)
        .frame(width: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            HStack(spacing: Bud.Space.snug) {
                Image(systemName: "sparkle")
                    .font(Bud.Font.callout.weight(.semibold))
                    .foregroundStyle(Bud.Palette.accent)
                Text("Bud").font(Bud.Font.body.weight(.semibold))
                Spacer()
                if model.isStreaming {
                    StreamingIndicator()
                }
            }
            HStack(spacing: Bud.Space.snug) {
                Text(model.config.model)
                Text("·")
                Text("\(model.availableTools.count) tools")
                Text("·")
                Text("\(model.mcp.servers.count) servers")
            }
            .font(Bud.Font.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var panelActions: some View {
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
            MenuActionRow(
                symbol: "macwindow",
                title: "Open Bud",
                shortcut: GlobalHotKey.summonShortcutLabel
            ) {
                NotificationCenter.default.post(name: .budTogglePanel, object: nil)
            }
            MenuActionRow(symbol: "eye.slash", title: "Hide Bud") {
                NotificationCenter.default.post(name: .budHidePanel, object: nil)
            }
            MenuActionRow(symbol: "square.and.pencil", title: "New chat") {
                model.clearTranscript()
                // The panel keeps its surface while it is hidden, so a chat that
                // was started from here has to say which surface it belongs on.
                NotificationCenter.default.post(name: .budShowChat, object: nil)
                NotificationCenter.default.post(name: .budTogglePanel, object: nil)
            }
            // The archive the Recent list below is only an extract of. Always
            // present, even with nothing saved: an empty history is a real answer,
            // and a row that only appeared after the first conversation would be
            // one nobody knows to look for.
            MenuActionRow(symbol: "clock.arrow.circlepath", title: "All conversations…") {
                NotificationCenter.default.post(name: .budShowPanel, object: nil)
                NotificationCenter.default.post(name: .budShowHistory, object: nil)
            }
            if model.isStreaming {
                MenuActionRow(symbol: "stop.fill", title: "Stop generating") {
                    model.stop()
                }
            }
        }
    }

    /// Shown only when there is something the user can do.
    ///
    /// Bud starts hidden and the menu bar is where it gets noticed, so an
    /// available update has to surface here rather than only behind a settings
    /// tab nobody opens on a hunch. A permanent "up to date" row would be noise
    /// in a menu that is otherwise entirely actions.
    @ViewBuilder
    private var updateActions: some View {
        switch model.update.phase {
        case .available(let manifest):
            Divider().opacity(0.3)
            MenuActionRow(symbol: "arrow.down.circle", title: "Update to \(manifest.version)…") {
                model.openSettings(tab: .about)
            }
        case .installed:
            Divider().opacity(0.3)
            MenuActionRow(symbol: "arrow.clockwise.circle", title: "Restart to finish updating") {
                model.update.relaunch()
            }
        default:
            EmptyView()
        }
    }

    /// The last few conversations, so yesterday's chat is one click from
    /// wherever Bud is rather than something to go looking for.
    ///
    /// Capped because a menu is not a browser: nobody reads a dropdown of two
    /// hundred, and the full archive is one row away for the conversations this
    /// one leaves out. The current one is marked, because a list of titles with
    /// no indication of which is open reads as five places to go rather than
    /// four places and where you already are.
    private static let recentLimit = 5

    @ViewBuilder
    private var recentActions: some View {
        let recent = Array(model.conversations.prefix(Self.recentLimit))
        if !recent.isEmpty {
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                Text("Recent")
                    .font(Bud.Font.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Bud.Space.snug)
                    .padding(.bottom, Bud.Space.hairline)
                ForEach(recent) { conversation in
                    let isCurrent = conversation.id == model.currentConversationID
                    MenuActionRow(
                        symbol: isCurrent ? "bubble.left.fill" : "bubble.left",
                        title: conversation.title
                    ) {
                        model.openConversation(id: conversation.id)
                        NotificationCenter.default.post(name: .budShowChat, object: nil)
                        NotificationCenter.default.post(name: .budShowPanel, object: nil)
                    }
                }
            }
        }
    }

    private var settingsActions: some View {
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
            ForEach(SettingsTab.allCases) { tab in
                MenuActionRow(symbol: tab.symbol, title: tab.label) {
                    model.openSettings(tab: tab)
                    openWindow(id: BudApp.settingsWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
            HStack {
                Text(model.usageSummary).font(Bud.Font.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            MenuActionRow(symbol: "power", title: "Quit Bud") {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct MenuActionRow: View {
    let symbol: String
    let title: String
    var shortcut: String?
    let action: () -> Void

    @BudState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: symbol)
                    .font(Bud.Font.caption.weight(.regular))
                    .frame(width: 16)
                Text(title).font(Bud.Font.body)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(Bud.Font.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Bud.Space.snug)
            .padding(.vertical, Bud.Space.xs)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.10) : .clear)
        }
        .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    /// Show Bud if it is on screen, hide it if it is not.
    static let budTogglePanel = Notification.Name("bud.togglePanel")
    /// Take Bud off screen.
    static let budHidePanel = Notification.Name("bud.hidePanel")
    /// Put Bud on screen. Distinct from toggling: something arriving from
    /// outside the panel wants it visible, and must not hide it if it already
    /// is, which is what toggling would do.
    static let budShowPanel = Notification.Name("bud.showPanel")
    /// Park Bud in a screen corner as the bubble. Only the panel's own collapse
    /// control asks for this; nothing does it on the user's behalf.
    static let budCollapsePanel = Notification.Name("bud.collapsePanel")
    /// Put the panel on its history surface: the full archive, beyond the few
    /// the menu bar shows. The panel keeps its surface while it is hidden, so
    /// this is a separate signal from showing the panel at all.
    static let budShowHistory = Notification.Name("bud.showHistory")
    /// Put the panel back on the transcript. Posted by everything that opens or
    /// starts a conversation, so the panel is never left sitting on History
    /// showing a chat the user has already asked for.
    static let budShowChat = Notification.Name("bud.showChat")
}
