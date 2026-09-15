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
                NotificationCenter.default.post(name: .budTogglePanel, object: nil)
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
    /// Park Bud in a screen corner as the bubble. Only the panel's own collapse
    /// control asks for this; nothing does it on the user's behalf.
    static let budCollapsePanel = Notification.Name("bud.collapsePanel")
}
