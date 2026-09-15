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

    /// The header adapts by dropping its least important words rather than by
    /// measuring and comparing against a threshold. `ViewThatFits` asks the
    /// layout directly, so there is no magic number to get wrong and no state
    /// that can be one layout pass stale.
    ///
    /// Three steps, because two are not enough: the panel can be dragged down to
    /// 380pt, where even the label-less status text leaves the row wider than its
    /// space.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsStatusText: true, showsTabLabels: true)
            headerRow(showsStatusText: false, showsTabLabels: true)
            headerRow(showsStatusText: false, showsTabLabels: false)
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.top, Bud.Space.md)
        .padding(.bottom, Bud.Space.sm)
    }

    /// Three groups, spaced so the grouping is unambiguous: identity, then the
    /// metadata that describes this session, then the controls. Everything at one
    /// spacing reads as a single undifferentiated row, which is what makes a
    /// header feel flat.
    private func headerRow(showsStatusText: Bool, showsTabLabels: Bool) -> some View {
        HStack(spacing: Bud.Space.md) {
            // Drag region: the panel is borderless from the user's perspective,
            // so the header doubles as the grab handle.
            HStack(spacing: Bud.Space.snug) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Bud.Palette.accent)
                Text("Bud")
                    .font(Bud.Font.title)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .help("Drag to move")

            // What Bud is running on, as one unit. Kept tight internally so it
            // reads as a single fact rather than two competing chips.
            HStack(spacing: Bud.Space.xs) {
                modelMenu
                connectionPill(showsText: showsStatusText)
            }

            Spacer(minLength: Bud.Space.xs)

            GlassEffectContainer(spacing: Bud.Space.md) {
                // The gear is spaced clear of the segmented control so it does
                // not read as a third segment of it.
                HStack(spacing: Bud.Space.md) {
                    surfacePicker(showsLabels: showsTabLabels)

                    // Collapsing is a first-class action, not a window control:
                    // the bubble is where Bud lives when it is not being read.
                    GlassIconButton(
                        systemImage: "arrow.down.right.and.arrow.up.left",
                        help: "Collapse to the corner (\(GlobalHotKey.summonShortcutLabel))"
                    ) {
                        NotificationCenter.default.post(name: .budTogglePanel, object: nil)
                    }

                    GlassIconButton(
                        systemImage: "gearshape",
                        help: "Settings (⌘,)"
                    ) {
                        model.openSettings(tab: .general)
                    }
                }
            }
        }
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

    private func connectionPill(showsText: Bool) -> some View {
        let ready = model.readyServerCount
        let total = model.mcp.servers.count
        let color: Color = total == 0
            ? .secondary
            : (ready == total ? Bud.Palette.success : (ready > 0 ? Bud.Palette.warning : Bud.Palette.danger))
        return HStack(spacing: Bud.Space.xs) {
            StateDot(color: color, pulsing: model.mcp.statuses.values.contains { $0.state == .connecting })
            // The words are the cheapest thing in the header to lose: the dot
            // already carries the state, and the tooltip still spells it out.
            if showsText {
                Text(total == 0 ? "No servers" : "\(ready)/\(total)")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(total == 0
              ? "No MCP servers connected"
              : "\(ready) of \(total) MCP servers ready · \(model.availableTools.count) tools")
    }

    private func surfacePicker(showsLabels: Bool) -> some View {
        HStack(spacing: Bud.Space.hairline) {
            ForEach(Surface.allCases, id: \.self) { option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { surface = option }
                } label: {
                    HStack(spacing: Bud.Space.xs) {
                        Image(systemName: option.symbol).font(.system(size: 10, weight: .medium))
                        if showsLabels {
                            Text(option.label).font(Bud.Font.caption).lineLimit(1)
                        }
                        if option == .agents, model.runningSubagentCount > 0 {
                            Text("\(model.runningSubagentCount)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, Bud.Space.xs)
                                .padding(.vertical, Bud.Space.hairline)
                                .background(Capsule().fill(Bud.Palette.accent.opacity(0.35)))
                        }
                    }
                    // Narrower side padding when the label is gone, so an
                    // icon-only tab is a neat capsule rather than a wide one.
                    .padding(.horizontal, showsLabels ? Bud.Space.sm : Bud.Space.xs)
                    .padding(.vertical, Bud.Space.xs)
                    // Never wraps or truncates: a two-line "Agents" is worse than
                    // anything else in the header giving up its space.
                    .fixedSize()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Keeps the meaning discoverable when the label is dropped.
                .help(option.label)
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
