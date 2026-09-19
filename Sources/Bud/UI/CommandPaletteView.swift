import AppKit
import SwiftUI

/// The ⌘K command palette: the panel's ten commands, every connected MCP server,
/// and every installed skill behind one searchable, keyboard-first surface.
///
/// It is the keyboard-complete mirror of the header. The surfaces and settings
/// panes that are a click away are reachable here by name, plus the two actions
/// — toggling reasoning and compacting context — that otherwise live behind a
/// scroll. Selecting a skill stages a natural-language hint in the composer and
/// never runs anything: the composer is where a request is still the user's to
/// finish.
///
/// Presented as an overlay on `RootView`, so it floats above whatever surface is
/// showing without leaving it. Like the onboarding gate, it never presents in a
/// scratch or headless run.
struct CommandPaletteView: View {
    private let model: AppModel
    private let onClose: () -> Void

    @FocusState private var isQueryFocused: Bool
    @BudState private var query = ""
    @BudState private var selectedIndex = 0
    @BudState private var installedSkills: [Skill] = []

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    /// Whether the palette may present at all. Mirrors the onboarding gate: a
    /// scratch or headless run — the self-test, the measurement CLIs, or
    /// `BUD_SCRATCH_STORE=1` — has no panel for the palette to float over, and
    /// the identifier gate keeps it out of helper binaries that report *some*
    /// bundle identifier but are not the installed app.
    static var isAvailable: Bool {
        !OnboardingState.isScratchStore && BudConfigLoader.usesKeychain
    }

    var body: some View {
        ZStack {
            // The dimmed scrim both announces the palette and gives the click
            // beside it a way to dismiss it.
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            card
        }
        .onAppear {
            installedSkills = SkillStore.installed()
            isQueryFocused = true
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.25)
            list
        }
        .frame(width: 560)
        .frame(maxHeight: 420)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.card, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
        .padding(Bud.Space.lg)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var searchField: some View {
        HStack(spacing: Bud.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Bud.Font.callout.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField("Search commands, servers and skills…", text: $query)
                .textFieldStyle(.plain)
                .font(Bud.Font.body)
                .focused($isQueryFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { press in
                    switch press.key {
                    case .upArrow:
                        guard !orderedEntries.isEmpty else { return .handled }
                        selectedIndex = max(0, selectedIndex - 1)
                    case .downArrow:
                        guard !orderedEntries.isEmpty else { return .handled }
                        selectedIndex = min(orderedEntries.count - 1, selectedIndex + 1)
                    case .escape:
                        onClose()
                    default:
                        return .ignored
                    }
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    pick(selected)
                    return .handled
                }
                .onChange(of: query) { _, _ in
                    // A new query reshuffles the list; the top result is the one
                    // to start on rather than whatever index the old list had
                    // highlighted, which may no longer exist.
                    selectedIndex = 0
                }
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.vertical, Bud.Space.sm)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Bud.Space.hairline) {
                    ForEach(Array(orderedEntries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isSelected: index == selectedIndex)
                            .id(entry.id)
                    }
                }
                .padding(Bud.Space.xs)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard orderedEntries.indices.contains(newIndex) else { return }
                proxy.scrollTo(orderedEntries[newIndex].id, anchor: .center)
            }
        }
    }

    private func row(_ entry: PaletteEntry, isSelected: Bool) -> some View {
        Button { pick(entry) } label: {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Bud.Palette.accent : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(Bud.Font.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Bud.Space.sm)

                if let shortcut = entry.shortcut {
                    Text(shortcut)
                        .font(Bud.Font.mono)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.kind.label)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, Bud.Space.md)
            .padding(.vertical, Bud.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(isSelected ? Bud.Palette.accent.opacity(0.18) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection

    private var orderedEntries: [PaletteEntry] {
        PaletteRanking.rank(query: query, entries: entries)
    }

    private var selected: PaletteEntry? {
        orderedEntries.indices.contains(selectedIndex) ? orderedEntries[selectedIndex] : nil
    }

    private func pick(_ entry: PaletteEntry?) {
        guard let entry else { return }
        onClose()
        entry.action()
    }

    // MARK: - Entries

    private var entries: [PaletteEntry] {
        commandEntries + serverEntries + skillEntries
    }

    private var commandEntries: [PaletteEntry] {
        let reasoningHidden = model.config.reasoningVisibility == .hidden
        return [
            PaletteEntry(
                id: "command.new",
                title: "New chat",
                detail: "Start a fresh conversation",
                symbol: "square.and.pencil",
                shortcut: "⌘N",
                kind: .command,
                keywords: "new chat conversation start fresh clear",
                action: {
                    model.newConversation()
                    model.surface = .chat
                }
            ),
            PaletteEntry(
                id: "command.history",
                title: "Search history",
                detail: "Find a past conversation",
                symbol: "magnifyingglass",
                shortcut: nil,
                kind: .command,
                keywords: "search history archive find conversations past",
                action: { model.surface = .history }
            ),
            PaletteEntry(
                id: "command.browser",
                title: "Open browser",
                detail: "Browse the web",
                symbol: "globe",
                shortcut: nil,
                kind: .command,
                keywords: "browser web browse open page",
                action: { model.surface = .browser }
            ),
            PaletteEntry(
                id: "command.connections",
                title: "Connections",
                detail: "Manage MCP servers",
                symbol: "point.3.connected.trianglepath.dotted",
                shortcut: nil,
                kind: .command,
                keywords: "connections mcp servers connect",
                action: { model.openSettings(tab: .mcp) }
            ),
            PaletteEntry(
                id: "command.marketplace",
                title: "Marketplace",
                detail: "Browse the MCP registry",
                symbol: "square.grid.2x2",
                shortcut: nil,
                kind: .command,
                keywords: "marketplace registry install servers browse",
                action: { model.openSettings(tab: .marketplace) }
            ),
            PaletteEntry(
                id: "command.agents",
                title: "Agents",
                detail: "What Bud can delegate to",
                symbol: "person.3.sequence",
                shortcut: nil,
                kind: .command,
                keywords: "agents subagents delegate run",
                action: { model.surface = .agents }
            ),
            PaletteEntry(
                id: "command.tools",
                title: "Tools",
                detail: "The tools every provider offers",
                symbol: "wrench.and.screwdriver",
                shortcut: nil,
                kind: .command,
                keywords: "tools inventory schemas reload",
                action: { model.openSettings(tab: .tools) }
            ),
            PaletteEntry(
                id: "command.reasoning",
                title: "Toggle reasoning",
                detail: reasoningHidden ? "Show the model's thinking" : "Hide the model's thinking",
                symbol: "brain",
                shortcut: nil,
                kind: .command,
                keywords: "reasoning thinking show hide toggle",
                action: { toggleReasoning() }
            ),
            PaletteEntry(
                id: "command.compact",
                title: "Compact context",
                detail: "Summarise the older half of this conversation",
                symbol: "compress",
                shortcut: nil,
                kind: .command,
                keywords: "compact context summarise shrink budget history",
                action: {
                    Task { await model.runtime.compactConversationNow() }
                }
            ),
            PaletteEntry(
                id: "command.diagnostics",
                title: "Diagnostics",
                detail: "Copy a redacted diagnostic bundle",
                symbol: "stethoscope",
                shortcut: nil,
                kind: .command,
                keywords: "diagnostics copy bundle debug report",
                action: { copyDiagnostics() }
            ),
        ]
    }

    private var serverEntries: [PaletteEntry] {
        model.mcp.servers
            .filter { model.mcp.statuses[$0.id]?.state == .ready }
            .map { server in
                PaletteEntry(
                    id: "server.\(server.id)",
                    title: server.name,
                    detail: server.summary.isEmpty ? server.transport.label : server.summary,
                    symbol: server.transport.symbol,
                    shortcut: nil,
                    kind: .server,
                    keywords: "mcp server \(server.name)",
                    action: { model.openSettings(tab: .mcp) }
                )
            }
    }

    private var skillEntries: [PaletteEntry] {
        installedSkills.map { skill in
            PaletteEntry(
                id: "skill.\(skill.name)",
                title: skill.name,
                detail: skill.summary,
                symbol: "sparkles",
                shortcut: nil,
                kind: .skill,
                keywords: "skill \(skill.name) \(skill.triggers)",
                action: {
                    // Staged, never sent: the hint names the skill and lands in
                    // the composer for the user to complete and send.
                    model.compose("Use the \(skill.name) skill.")
                }
            )
        }
    }

    // MARK: - Command actions

    private func toggleReasoning() {
        let next: ReasoningVisibility =
            model.config.reasoningVisibility == .hidden ? .whileThinking : .hidden
        model.config.reasoningVisibility = next
        model.persistConfig()
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticBundle.build(model: model), forType: .string)
    }
}

// MARK: - Entries

/// One row in the palette: a command, a connected server, or an installed skill.
///
/// The action is a closure rather than an enum case because the palette is the
/// one place every navigation path in the app is offered side by side, and the
/// paths do not share a shape — some switch the surface, some open a settings
/// pane, two run a small task, and one stages text.
struct PaletteEntry: Identifiable {
    enum Kind {
        case command, server, skill

        var label: String {
            switch self {
            case .command: return "Command"
            case .server: return "Server"
            case .skill: return "Skill"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String?
    let kind: Kind
    let keywords: String
    let action: () -> Void

    /// Everything the matcher scores against: the title, the detail, and the
    /// extra words people type to reach this entry.
    var searchText: String { "\(title) \(detail) \(keywords)" }
}

// MARK: - Ranking

/// Deterministic fuzzy ranking for the palette, built on the same token and
/// overlap utilities every other catalogue search in the app uses.
///
/// The IDF-weighted overlap from `TextRanking` scores a query against the whole
/// catalogue at once, so a word that appears in nearly every entry carries no
/// signal. On top of that, a prefix bonus lets a partial word find its entry —
/// "bro" reaches "Open browser" — which exact token overlap alone would miss.
enum PaletteRanking {
    static func rank(query: String, entries: [PaletteEntry]) -> [PaletteEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        guard !entries.isEmpty else { return [] }

        let terms = TextRanking.tokens(in: needle)
        let documents = entries.map { TextRanking.tokens(in: $0.searchText) }
        let base = TextRanking.scores(terms: terms, documents: documents)

        var scored: [(entry: PaletteEntry, score: Double)] = []
        scored.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            var score = base[index]
            let title = entry.title.lowercased()
            // The title carries the name the user is aiming at, so a partial
            // word against it is worth more than incidental word overlap in the
            // body of the description.
            if title.hasPrefix(needle) {
                score += 2.0
            } else if title.contains(needle) {
                score += 1.0
            } else if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                score += 1.5
            }
            if score > 0 { scored.append((entry, score)) }
        }
        return scored.sorted { $0.score > $1.score }.map(\.entry)
    }
}
