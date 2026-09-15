import AppKit
import SwiftUI

/// The panel's root: a compact header over a switchable body.
///
/// The header is the only chrome — model, connection health and agent activity
/// are all legible at a glance so the user never has to open Settings to know
/// whether Bud can actually reach anything.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private enum Surface: String, CaseIterable {
        case chat, agents

        var label: String { self == .chat ? "Chat" : "Agents" }
        var symbol: String { self == .chat ? "bubble.left.and.text.bubble.right" : "person.3.sequence" }
    }

    @BudState private var surface: Surface = .chat

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        GlassPanel {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.25)
                content
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .preferredColorScheme(nil)
        .task {
            model.onPresentSettings = { [openWindow] _ in
                openWindow(id: BudApp.settingsWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            await model.start()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Bud.Space.sm) {
            // Drag region: the panel is borderless from the user's perspective,
            // so the header doubles as the grab handle.
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Bud.Palette.accent)
                Text("Bud")
                    .font(.system(size: 13, weight: .semibold))
            }
            .contentShape(Rectangle())
            .help("Drag to move")

            modelMenu

            connectionPill

            Spacer(minLength: Bud.Space.sm)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    surfacePicker

                    GlassIconButton(
                        systemImage: "gearshape",
                        help: "Settings (⌘,)"
                    ) {
                        model.openSettings(tab: .general)
                    }
                }
            }
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.top, Bud.Space.md)
        .padding(.bottom, Bud.Space.sm)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(BudApp.selectableModels, id: \.id) { option in
                Button {
                    model.setModel(option.id)
                } label: {
                    if option.id == model.config.model {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shortModelName)
                    .font(Bud.Font.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model: \(model.config.model)")
    }

    private var shortModelName: String {
        let name = model.config.model
        if name.contains("pro") { return "Pro" }
        if name.contains("flash") { return "Flash" }
        return name
    }

    private var connectionPill: some View {
        let ready = model.readyServerCount
        let total = model.mcp.servers.count
        let color: Color = total == 0
            ? .secondary
            : (ready == total ? Bud.Palette.success : (ready > 0 ? Bud.Palette.warning : Bud.Palette.danger))
        return HStack(spacing: 5) {
            StateDot(color: color, pulsing: model.mcp.statuses.values.contains { $0.state == .connecting })
            Text(total == 0 ? "No servers" : "\(ready)/\(total)")
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
        }
        .help(total == 0
              ? "No MCP servers connected"
              : "\(ready) of \(total) MCP servers ready · \(model.availableTools.count) tools")
    }

    private var surfacePicker: some View {
        HStack(spacing: 2) {
            ForEach(Surface.allCases, id: \.self) { option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { surface = option }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: option.symbol).font(.system(size: 10, weight: .medium))
                        Text(option.label).font(Bud.Font.caption)
                        if option == .agents, model.runningSubagentCount > 0 {
                            Text("\(model.runningSubagentCount)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Bud.Palette.accent.opacity(0.35)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(surface == option ? .primary : .secondary)
                .glassEffect(
                    surface == option
                        ? .regular.tint(Bud.Palette.accent.opacity(0.45)).interactive()
                        : .identity,
                    in: .capsule
                )
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .chat:
            ChatView(model: model)
        case .agents:
            SubagentPanel(supervisor: model.subagents, model: model)
        }
    }
}
