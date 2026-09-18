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
        VStack(spacing: Bud.Space.snug) {
            if isCommandMenuVisible {
                commandMenu
            }

            GlassCard(cornerRadius: Bud.Radius.card, padding: Bud.Space.md) {
                // The gap between the field and its controls is deliberately wider
                // than the gaps inside the control row. When both are the same,
                // the chips read as part of the text field rather than as
                // controls below it.
                VStack(alignment: .leading, spacing: Bud.Space.md) {
                    if let problem = model.config.setupProblem {
                        KeyMissingBanner(problem: problem) { model.openSettings(tab: .general) }
                    }
                    attachments
                    input
                    toolbar
                }
            }
        }
        .onAppear { isFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .budCommandPalette)) { _ in
            openCommandMenu()
        }
        .onChange(of: model.composerFocusToken) { _, _ in
            // Text staged from outside the panel, or the panel ordered back on
            // screen: either way the caret has to be placed rather than assumed.
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

    // MARK: - Attachments

    /// What a drop took, shown so the drop is visibly something that happened.
    ///
    /// A thumbnail for an image rather than only a filename, because a preview
    /// is the whole point of dropping a picture — and the same chip says plainly
    /// that Bud cannot read it yet, which is better learned here than from an
    /// answer about a filename.
    @ViewBuilder
    private var attachments: some View {
        if !model.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Bud.Space.xs) {
                    ForEach(model.attachments) { file in
                        attachmentChip(file)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 46)
        }
    }

    private func attachmentChip(_ file: DroppedFile) -> some View {
        HStack(spacing: Bud.Space.xs) {
            if file.isImage, let image = NSImage(contentsOfFile: file.path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: file.isImage ? "photo" : "doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(file.isImage ? Bud.Palette.warning : .secondary)
                    .frame(width: 26, height: 26)
            }

            Text(file.name)
                .font(Bud.Font.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)

            Button { model.removeAttachment(id: file.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, Bud.Space.xs)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .help(file.isImage
              ? "\(file.path)\nBud reads the text inside a picture; it cannot see the picture itself."
              : file.path)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Bud.Space.snug) {
            GlassChip(model.config.model, systemImage: "cpu")

            effortMenu

            Button {
                showsTools = true
            } label: {
                ToolCountBadge(count: model.availableTools.count, isActive: showsTools)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsTools, arrowEdge: .bottom) { toolList }

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: Bud.Space.sm) {
                HStack(spacing: Bud.Space.snug) {
                    GlassIconButton(systemImage: "command", help: "Slash commands") {
                        openCommandMenu()
                    }
                    sendButton
                }
            }
        }
    }

    /// How hard the model should think before answering.
    ///
    /// Here rather than only in Settings because it is a per-question decision: a
    /// lookup does not need the depth a design question does, and having to go
    /// into settings between turns is enough friction that nobody ever would.
    private var effortMenu: some View {
        Menu {
            Button("Automatic") { setEffort(nil) }
            Divider()
            ForEach(Self.effortLevels, id: \.self) { level in
                Button(Self.effortLabel(level)) { setEffort(level) }
            }
        } label: {
            GlassChip(Self.effortLabel(model.config.reasoningEffort), systemImage: "brain")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How much thinking the model does before answering")
    }

    /// The levels every provider understands. `max` and `xhigh` are accepted by
    /// one of them, so a value already set there is shown but not offered here.
    private static let effortLevels = ["low", "medium", "high"]

    private static func effortLabel(_ effort: String?) -> String {
        switch effort?.lowercased() {
        case .none, "": return "Auto"
        case "low": return "Quick"
        case "medium": return "Balanced"
        case "high", "xhigh", "max": return "Deep"
        default: return effort ?? "Auto"
        }
    }

    private func setEffort(_ effort: String?) {
        model.config.reasoningEffort = effort
        model.persistConfig()
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
                        Spacer(minLength: Bud.Space.sm)
                        if let shortcut = command.shortcut {
                            Text(shortcut)
                                .font(Bud.Font.mono)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, Bud.Space.md)
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

    /// True when the active provider cannot be called yet — a missing key, a
    /// missing base URL for the custom entry, or no model chosen.
    private var isKeyMissing: Bool {
        model.config.setupProblem != nil
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
        model.clearAttachments()
        dismissedQuery = nil
        highlightedCommand = 0
        Task { await model.send(text) }
    }
}

// MARK: - Command catalog

private enum SlashCommand: String, CaseIterable, Identifiable {
    case new, tools, settings, mcp, marketplace, agents

    var id: String { rawValue }
    var name: String { "/" + rawValue }

    var summary: String {
        switch self {
        case .new: return "Start a new chat"
        case .tools: return "Reload tools from every provider"
        case .settings: return "Open general settings"
        case .mcp: return "Manage MCP servers"
        case .marketplace: return "Browse the MCP registry"
        case .agents: return "What Bud can delegate to, and what it has"
        }
    }

    /// Shown beside the command. Only the ones that are real: a column of
    /// invented shortcuts would be worse than an empty one.
    var shortcut: String? {
        switch self {
        case .new: return "⌘N"
        case .settings: return "⌘,"
        case .tools, .mcp, .marketplace, .agents: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .new: return "square.and.pencil"
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
        case .new: model.newConversation()
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
