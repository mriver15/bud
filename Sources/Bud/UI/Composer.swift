import SwiftUI

/// The message input: auto-growing field, glass send/stop control, a compact
/// toolbar, and a slash-command palette.
///
/// Focus is owned internally rather than injected. Bud renders the composer
/// exactly once, in one panel, so threading a `FocusState` binding through the
/// view tree would add a parameter without ever being used to move focus
/// anywhere else.
public struct Composer: View {
    @Bindable private var model: AppModel
    @FocusState private var isFocused: Bool

    @BudState private var highlightedCommand = 0
    @BudState private var dismissedQuery: String?
    @BudState private var showsTools = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 6) {
            if isCommandMenuVisible {
                commandMenu
            }

            GlassCard(cornerRadius: Bud.Radius.card, padding: 10) {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    if isKeyMissing {
                        KeyMissingBanner { model.openSettings(tab: .general) }
                    }
                    input
                    toolbar
                }
            }
        }
        .onAppear { isFocused = true }
        .onChange(of: model.composerFocusToken) { _, _ in
            // Set when Bud expands from the collapsed bubble: the panel window is
            // ordered back in, so the caret has to be placed explicitly.
            isFocused = true
        }
    }

    // MARK: - Input

    private var input: some View {
        TextField("Ask Bud anything…", text: $model.composerText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Bud.Font.body)
            .lineLimit(1...10)
            .focused($isFocused)
            .disabled(isKeyMissing)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                if isCommandMenuVisible, let command = highlightedCommandValue {
                    run(command)
                    return .handled
                }
                send()
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { press in
                guard isCommandMenuVisible else { return .ignored }
                switch press.key {
                case .upArrow:
                    highlightedCommand = max(0, highlightedCommand - 1)
                case .downArrow:
                    highlightedCommand = min(max(0, filteredCommands.count - 1), highlightedCommand + 1)
                case .escape:
                    dismissedQuery = slashQuery
                default:
                    return .ignored
                }
                return .handled
            }
            .onChange(of: model.composerText) { _, _ in
                if highlightedCommand >= filteredCommands.count { highlightedCommand = 0 }
            }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            GlassChip(model.config.model, systemImage: "cpu")

            Button {
                showsTools = true
            } label: {
                ToolCountBadge(count: model.availableTools.count, isActive: showsTools)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsTools, arrowEdge: .bottom) { toolList }

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    GlassIconButton(systemImage: "command", help: "Slash commands") {
                        openCommandMenu()
                    }
                    sendButton
                }
            }
        }
    }

    private var sendButton: some View {
        Button {
            if model.isStreaming {
                model.stop()
            } else {
                send()
            }
        } label: {
            Image(systemName: model.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(sendTint.opacity(0.85)))
        .glassEffect(.regular.tint(sendTint).interactive(), in: .circle)
        .opacity(model.isStreaming || canSend ? 1 : 0.4)
        .disabled(!model.isStreaming && !canSend)
        .help(model.isStreaming ? "Stop" : "Send")
    }

    /// A saturated accent at half opacity still reads as an active control, which
    /// invites a click that does nothing. The disabled state drops the accent
    /// entirely rather than only dimming it.
    private var sendTint: Color {
        if model.isStreaming { return Bud.Palette.danger }
        return canSend ? Bud.Palette.accent : Color.secondary
    }

    // MARK: - Tools

    private var toolList: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader(
                    "Tools",
                    subtitle: "\(model.availableTools.count) available",
                    systemImage: "wrench.and.screwdriver"
                )
                Spacer(minLength: 0)
                GlassIconButton(systemImage: "arrow.clockwise", help: "Reload tools") {
                    Task { await model.refreshTools() }
                }
            }

            Divider().opacity(0.3)

            if groupedTools.isEmpty {
                Text("No tools yet. Connect an MCP server, then reload.")
                    .font(Bud.Font.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Bud.Space.md) {
                        ForEach(groupedTools, id: \.name) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.name.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(.secondary)
                                ForEach(group.tools) { tool in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name).font(Bud.Font.mono)
                                        if !tool.description.isEmpty {
                                            Text(tool.description)
                                                .font(Bud.Font.caption)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(.trailing, Bud.Space.xs)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(Bud.Space.md)
        .frame(width: 320)
    }

    private var groupedTools: [ToolGroup] {
        Dictionary(grouping: model.availableTools, by: \.providerName)
            .map { ToolGroup(name: $0.key, tools: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Slash commands

    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                Button {
                    run(command)
                } label: {
                    HStack(spacing: Bud.Space.sm) {
                        Image(systemName: command.systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16)
                        Text(command.name).font(Bud.Font.mono)
                        Text(command.summary)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                            .fill(index == highlightedCommand ? Bud.Palette.accent.opacity(0.18) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Bud.Space.xs)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.card, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                }
        }
    }

    /// Non-nil only while the input is a bare command token: `/`, `/to`, …
    private var slashQuery: String? {
        let text = model.composerText
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        return rest.lowercased()
    }

    private var filteredCommands: [SlashCommand] {
        guard let query = slashQuery else { return [] }
        if query.isEmpty { return SlashCommand.allCases }
        return SlashCommand.allCases.filter { $0.name.dropFirst().hasPrefix(query) }
    }

    private var isCommandMenuVisible: Bool {
        guard let query = slashQuery, query != dismissedQuery, !isKeyMissing else { return false }
        return !filteredCommands.isEmpty
    }

    private var highlightedCommandValue: SlashCommand? {
        let commands = filteredCommands
        return commands.indices.contains(highlightedCommand) ? commands[highlightedCommand] : nil
    }

    private func openCommandMenu() {
        model.composerText = "/"
        dismissedQuery = nil
        highlightedCommand = 0
        isFocused = true
    }

    private func run(_ command: SlashCommand) {
        model.composerText = ""
        dismissedQuery = nil
        highlightedCommand = 0
        Task { await command.run(on: model) }
    }

    // MARK: - Sending

    private var isKeyMissing: Bool {
        model.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !isKeyMissing
            && !model.isStreaming
            && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The field is cleared before the send starts so the next thought can be
    /// typed while the current one is still streaming.
    private func send() {
        guard canSend else { return }
        let text = model.composerText
        model.composerText = ""
        dismissedQuery = nil
        highlightedCommand = 0
        Task { await model.send(text) }
    }
}

// MARK: - Command catalog

private enum SlashCommand: String, CaseIterable, Identifiable {
    case clear, tools, settings, mcp, marketplace, agents

    var id: String { rawValue }
    var name: String { "/" + rawValue }

    var summary: String {
        switch self {
        case .clear: return "Clear the transcript"
        case .tools: return "Reload tools from every provider"
        case .settings: return "Open general settings"
        case .mcp: return "Manage MCP servers"
        case .marketplace: return "Browse the MCP registry"
        case .agents: return "Review subagent runs"
        }
    }

    var systemImage: String {
        switch self {
        case .clear: return "eraser"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        case .mcp: return "server.rack"
        case .marketplace: return "square.grid.2x2"
        case .agents: return "person.2"
        }
    }

    @MainActor
    func run(on model: AppModel) async {
        switch self {
        case .clear: model.clearTranscript()
        case .tools: await model.refreshTools()
        case .settings: model.openSettings(tab: .general)
        case .mcp: model.openSettings(tab: .mcp)
        case .marketplace: model.openSettings(tab: .marketplace)
        case .agents: model.openSettings(tab: .subagents)
        }
    }
}

// MARK: - Helpers

private struct ToolGroup {
    let name: String
    let tools: [ToolDescriptor]
}
