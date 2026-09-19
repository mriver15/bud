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
        // Over everything, because a command is paused behind it. The panel is
        // brought forward when the request is made, so this is on screen rather
        // than waiting in a window nobody is looking at.
        .overlay {
            if let request = model.pendingConfirmation {
                ToolConfirmationView(request: request) { decision in
                    model.answerConfirmation(decision)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.pendingConfirmation?.id)
        // The surface is switched from outside the header too — the menu bar's
        // history row, and anything that opens or starts a conversation — so it
        // cannot belong to the picker alone.
        .onReceive(NotificationCenter.default.publisher(for: .budShowHistory)) { _ in
            select(.history)
        }
        .onReceive(NotificationCenter.default.publisher(for: .budShowChat)) { _ in
            select(.chat)
        }
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
        .contentColumn()
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
                providerMenu
                connectionPill(showsText: showsStatusText)
                spendChip(showsText: showsStatusText)
            }

            Spacer(minLength: Bud.Space.xs)

            GlassEffectContainer(spacing: Bud.Space.md) {
                // The gear is spaced clear of the segmented control so it does
                // not read as a third segment of it.
                HStack(spacing: Bud.Space.md) {
                    surfacePicker(showsLabels: showsTabLabels)

                    // A new chat is the most likely thing anyone wants next and
                    // the one action that had no home on this surface at all —
                    // it lived behind ⌘N, a slash command, and a button on the
                    // History tab, which is a strange place to go to start
                    // something new.
                    GlassIconButton(
                        systemImage: "square.and.pencil",
                        help: "New chat (⌘N)"
                    ) {
                        model.newConversation()
                        model.surface = .chat
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

    /// The provider control, which also shows the active model.
    ///
    /// It was a model picker listing DeepSeek's two models — meaningless once
    /// another provider is selected, and actively wrong to offer. Switching
    /// provider is the more useful quick action, and the model follows from the
    /// per-provider choice automatically.
    private var providerMenu: some View {
        Menu {
            ForEach(ProviderRegistry.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.providers) { descriptor in
                        Button {
                            model.selectProvider(descriptor.id)
                        } label: {
                            if descriptor.id == model.config.provider {
                                Label(descriptor.name, systemImage: "checkmark")
                            } else {
                                Text(descriptor.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Set model…") { model.openSettings(tab: .general) }
        } label: {
            HStack(spacing: Bud.Space.xs) {
                Text(shortModelName)
                    .font(Bud.Font.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(model.config.activeProvider.name) · \(model.config.model)")
    }

    /// The model, shortened for a 460pt header.
    ///
    /// Derived rather than looked up: with arbitrary providers there is no
    /// catalogue to map ids to friendly names, and inventing one would go stale.
    private var shortModelName: String {
        let name = model.config.model
        if name.isEmpty { return model.config.activeProvider.name }
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

    /// What this conversation has cost.
    ///
    /// Beside the connection state because both describe the session you are in,
    /// and a figure that only appears once you go looking for it changes no
    /// decision. Absent at zero: a chat that has spent nothing does not need to
    /// say so.
    @ViewBuilder
    private func spendChip(showsText: Bool) -> some View {
        let tokens = model.conversationTokens
        if tokens > 0 {
            let usage = model.conversationUsage
            let fraction = model.budgetFraction
            HStack(spacing: Bud.Space.xs) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 9, weight: .medium))
                // The number is the cheapest thing to lose when space is tight:
                // the tooltip spells the whole thing out either way.
                if showsText {
                    Text(BudFormat.tokens(tokens))
                        .font(Bud.Font.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(spendTint(fraction))
            .help(spendHelp(usage: usage, fraction: fraction))
        }
    }

    private func spendTint(_ fraction: Double?) -> Color {
        guard let fraction else { return .secondary }
        if fraction >= 1 { return Bud.Palette.danger }
        if fraction >= 0.8 { return Bud.Palette.warning }
        return .secondary
    }

    private func spendHelp(usage: (prompt: Int, completion: Int), fraction: Double?) -> String {
        var text = "This conversation: \(BudFormat.tokens(usage.prompt)) in, "
            + "\(BudFormat.tokens(usage.completion)) out"
        if let budget = model.conversationBudget, let fraction {
            text += " · \(Int(fraction * 100))% of a \(BudFormat.tokens(budget)) budget"
        }
        return text
    }

    private func surfacePicker(showsLabels: Bool) -> some View {
        HStack(spacing: Bud.Space.hairline) {
            ForEach(Surface.allCases, id: \.self) { option in
                Button {
                    select(option)
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
                .foregroundStyle(model.surface == option ? .primary : .secondary)
                .glassEffect(
                    model.surface == option
                        ? .regular.tint(Bud.Palette.accent.opacity(0.45)).interactive()
                        : .identity,
                    in: .capsule
                )
            }
        }
    }

    // MARK: Body

    /// One place that changes the surface, so the animation is the same whether
    /// the switch came from the picker or from outside the panel.
    private func select(_ next: Surface) {
        withAnimation(.snappy(duration: 0.18)) { model.surface = next }
    }

    @ViewBuilder
    private var content: some View {
        switch model.surface {
        case .chat:
            ChatView(model: model)
        case .agents:
            SubagentPanel(supervisor: model.subagents, model: model)
                .padding(Bud.Space.lg)
        case .browser:
            BrowserView(model: model)
        case .history:
            ConversationHistoryView(model: model)
        }
    }
}
