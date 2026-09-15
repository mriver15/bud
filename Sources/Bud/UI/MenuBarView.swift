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
            Divider().opacity(0.3)
            settingsActions
            Divider().opacity(0.3)
            footer
        }
        .padding(Bud.Space.md)
        .frame(width: 280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Bud.Palette.accent)
                Text("Bud").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isStreaming {
                    StreamingIndicator()
                }
            }
            HStack(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 2) {
            MenuActionRow(symbol: "macwindow", title: "Show Bud", shortcut: GlobalHotKey.summonShortcutLabel) {
                NotificationCenter.default.post(name: .budTogglePanel, object: nil)
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

    private var settingsActions: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        VStack(alignment: .leading, spacing: 2) {
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
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title).font(Bud.Font.body)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(Bud.Font.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
    static let budTogglePanel = Notification.Name("bud.togglePanel")
}
