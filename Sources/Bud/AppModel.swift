import Foundation
import Observation

public enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case general, mcp, marketplace, subagents, tools, about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .mcp: return "Connections"
        case .marketplace: return "Marketplace"
        case .subagents: return "Subagents"
        case .tools: return "Tools"
        case .about: return "About"
        }
    }

    public var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .marketplace: return "square.grid.2x2"
        case .subagents: return "person.3.sequence"
        case .tools: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

/// The panel's top-level surfaces.
///
/// Lives here rather than inside the view that draws it because it is reachable
/// from outside that view — the menu bar switches to History, and `bud://history`
/// does the same. As view-local state those requests could only be delivered by
/// notification, and a notification posted before the panel has ever been shown
/// has no subscriber and is dropped on the floor.
public enum Surface: String, CaseIterable, Sendable, Identifiable {
    case chat, agents, history

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .chat: return "Chat"
        case .agents: return "Agents"
        case .history: return "History"
        }
    }

    public var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .agents: return "person.3.sequence"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Root application state. Owns the subsystems, exposes one coherent surface to
/// the views, and is the only writer of the live config.
@MainActor
@Observable
public final class AppModel {
    // MARK: Subsystems

    public let env: AppEnvironment
    public let runtime: AgentRuntime
    public let mcp: MCPManager
    public let marketplace: MarketplaceStore
    public let subagents: SubagentSupervisor
    public let update: UpdateModel

    // MARK: UI state

    public var composerText: String = ""
    public var errorMessage: String?
    public var availableTools: [ToolDescriptor] = []
    public var settingsTab: SettingsTab = .general
    public var showingSettings = false
    /// Which surface the panel is showing.
    public var surface: Surface = .chat
    public var showingSubagents = false

    /// Live config. Mirrored into `env` on every write so background work always
    /// reads what the user last saved, and persisted only when the user commits
    /// (a per-keystroke file write would be wasteful).
    public var config: BudConfig {
        didSet {
            guard config != oldValue else { return }
            env.config = config
            // The API key and model are read per-request, so a change takes
            // effect on the next turn without any further plumbing.
        }
    }

    /// Bumped whenever something wants the caret in the composer: text arriving
    /// from outside the panel, so a Services invocation or a dropped file lands
    /// ready to send rather than one click short of it. A counter rather than a
    /// flag because the request has to be observable even when it repeats.
    public var composerFocusToken = 0

    public func focusComposer() {
        composerFocusToken &+= 1
    }

    /// Text arriving from outside the panel — a Services invocation, or files
    /// dropped on it.
    ///
    /// Deliberately never sent on the user's behalf. An assistant that fires a
    /// request because you right-clicked something is one you learn not to
    /// right-click, so this stages the text and puts the caret after it.
    public func compose(_ text: String, appending: Bool = false, reveal: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if appending, !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerText += composerText.hasSuffix("\n") ? trimmed : "\n" + trimmed
        } else {
            composerText = trimmed
        }
        focusComposer()
        if reveal {
            NotificationCenter.default.post(name: .budShowPanel, object: nil)
        }
    }

    /// Set by the shell to present the settings window.
    public var onPresentSettings: (@MainActor (SettingsTab) -> Void)?
    /// Set by the shell to quit.
    public var onQuit: (@MainActor () -> Void)?

    private var didStart = false

    public init(config: BudConfig = BudConfigLoader.load()) {
        let env = AppEnvironment(config: config)
        self.env = env
        self.config = config
        self.runtime = AgentRuntime(env: env)
        self.mcp = MCPManager()
        self.marketplace = MarketplaceStore()
        self.subagents = SubagentSupervisor(env: env)
        self.update = UpdateModel()
        // Wired here because this is the first moment `self` is complete enough
        // to be captured. The closure reads `onQuit` when it is called, not when
        // it is set, so the app delegate can still be the one to fill it in.
        update.onQuit = { [weak self] in self?.onQuit?() }
        runtime.onTurnFinished = { [weak self] in self?.scheduleConversationSave() }
    }

    // MARK: Derived state

    public var turns: [Turn] { runtime.turns }
    public var isStreaming: Bool { runtime.isStreaming }
    public var statusText: String { runtime.statusText }
    public var modelName: String { config.model }
    /// True when the active provider has everything it needs to be called.
    ///
    /// Local runtimes need no key, the custom entry needs a base URL, and every
    /// provider needs a model — so "has an API key" stopped being the same
    /// question as "is configured". Delegated to the config so the composer and
    /// the settings pane cannot disagree about it.
    public var hasAPIKey: Bool { config.setupProblem == nil }

    public var usageSummary: String {
        let u = env.usage
        guard u.prompt + u.completion > 0 else { return "No usage yet" }
        return "\(BudFormat.tokens(u.prompt)) in · \(BudFormat.tokens(u.completion)) out"
    }

    public var readyServerCount: Int {
        mcp.statuses.values.count { $0.state == .ready }
    }

    public var runningSubagentCount: Int {
        subagents.runs.count { $0.state == .running }
    }

    // MARK: Lifecycle

    /// Registers providers, restores MCP connections and warms the marketplace.
    /// Idempotent — the first window and a menu action can both call it.
    public func start() async {
        guard !didStart else { return }
        didStart = true

        BudConfigLoader.ensureDirectory()
        restoreConversations()
        subagents.loadRecentRuns()
        let providers: [any ToolProvider] = [
            NativeToolsProvider(),
            MemoryToolsProvider(),
            mcp,
            subagents,
            GenUIToolProvider(),
        ]
        for provider in providers {
            await env.registry.register(provider)
        }

        marketplace.isInstalled = { [weak self] server in
            guard let self else { return false }
            return self.mcp.servers.contains { $0.registryName == server.name }
        }

        await refreshTools()
        await mcp.connectAllAutoStart()
        await refreshTools()

        // Anything an earlier update left behind is unreachable the moment this
        // process started, so the tidy-up costs nothing here.
        if let bundle = update.installedBundle {
            UpdateInstaller.cleanupStaleBackups(beside: bundle)
        }
        // After the tools are up, so a slow network never delays a usable app.
        if config.autoCheckUpdates {
            Task { [update, config] in
                await update.check(feed: config.updateFeed, background: true)
            }
        }

        Task { await marketplace.loadInitial() }
    }

    public func shutdown() async {
        runtime.stop()
        // Before the socket closes and before anything else can fail: a turn in
        // flight is still worth keeping, and this is the last moment it exists.
        saveTask?.cancel()
        persistConversations()
        await mcp.shutdown()
        BudConfigLoader.save(config)
    }

    // MARK: Conversation

    public func send(_ text: String? = nil) async {
        let message = (text ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !runtime.isStreaming else { return }
        composerText = ""
        errorMessage = nil
        runtime.send(message)
        // The runtime runs the turn on its own task so the caller (a button, a
        // slash command, a generated-UI action) is never blocked by it.
    }

    public func stop() { runtime.stop() }

    /// Starts a fresh conversation.
    ///
    /// "New chat" has never meant "discard what I just said", so the current one
    /// is folded into the archive before the transcript is cleared. Before this
    /// existed the button was a quiet way to lose the last hour's work.
    public func clearTranscript() {
        newConversation()
    }

    // MARK: Conversations

    /// Saved conversations, most recently touched first. Summaries rather than
    /// transcripts: a history list has no business loading turns it will not
    /// draw.
    public private(set) var conversations: [ConversationSummary] = []
    /// The conversation the live transcript belongs to.
    public private(set) var currentConversationID: String?

    /// Set while a search is narrowing the list, so the switcher can show what
    /// it is actually listing.
    public private(set) var conversationQuery: String = ""

    private var saveTask: Task<Void, Never>?

    public func newConversation() {
        persistConversations()
        currentConversationID = UUID().uuidString
        runtime.clear()
        composerText = ""
        errorMessage = nil
        BudStore.setCurrentConversation(currentConversationID)
        conversationQuery = ""
        refreshConversations()
    }

    public func openConversation(id: String) {
        guard id != currentConversationID else { return }
        persistConversations()
        currentConversationID = id
        BudStore.setCurrentConversation(id)
        guard let saved = BudStore.load(id: id) else { return }
        runtime.restore(turns: saved.turns, history: saved.messages)
        errorMessage = nil
    }

    public func deleteConversation(id: String) {
        BudStore.delete(id: id)
        if currentConversationID == id {
            // Mint a replacement rather than leaving none open. Nothing else
            // re-creates one, and a nil current conversation means
            // `captureCurrentConversation` returns early for ever — every turn
            // after the delete would be silently unsaved. This is the same hole
            // that made the whole feature do nothing on a first run.
            currentConversationID = UUID().uuidString
            runtime.clear()
            BudStore.setCurrentConversation(currentConversationID)
        }
        refreshConversations()
    }

    /// Narrows the history list. An empty query restores the full list.
    public func searchConversations(_ query: String) {
        conversationQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations = trimmed.isEmpty ? BudStore.list() : BudStore.search(trimmed)
    }

    public func refreshConversations() {
        let trimmed = conversationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations = trimmed.isEmpty ? BudStore.list() : BudStore.search(trimmed)
    }

    /// Folds the live transcript into the database.
    public func persistConversations() {
        captureCurrentConversation()
        BudStore.setCurrentConversation(currentConversationID)
    }

    /// Writes the archive, coalescing bursts.
    ///
    /// A turn mutates the transcript dozens of times while it streams, and the
    /// file is rewritten whole, so saving on every change would rewrite the
    /// entire history for every token.
    private func scheduleConversationSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persistConversations()
        }
    }

    private func captureCurrentConversation() {
        guard let id = currentConversationID else { return }
        let turns = runtime.turns
        // Nothing worth keeping yet. Recording an empty conversation would fill
        // the history with rows that open onto a blank panel.
        guard !turns.isEmpty else { return }

        let previous = BudStore.load(id: id)
        BudStore.save(Conversation(
            id: id,
            title: Conversation.title(from: turns),
            createdAt: previous?.createdAt ?? Date(),
            updatedAt: Date(),
            turns: turns,
            messages: runtime.modelHistory
        ))
        refreshConversations()
    }

    /// Brings back the conversation that was open when Bud last quit.
    private func restoreConversations() {
        // The pre-SQLite archive, folded in once. Renamed afterwards, so this
        // costs a file-existence check on every launch after the first.
        BudStore.importLegacyArchive()
        refreshConversations()

        guard let id = BudStore.currentConversationID(),
              let saved = BudStore.load(id: id)
        else {
            // Nothing to resume — a first run, or a history that was cleared.
            // There still has to be an open conversation to write into, or the
            // first thing the user says has nowhere to go and nothing is ever
            // saved, which is exactly what happened the first time round.
            currentConversationID = UUID().uuidString
            BudStore.setCurrentConversation(currentConversationID)
            return
        }
        currentConversationID = id
        runtime.restore(turns: saved.turns, history: saved.messages)
    }

    /// Handles a button press from a generated UI surface: an action carrying a
    /// `prompt` becomes the next user turn, otherwise the action id is reported
    /// back so the model can decide what it means.
    public func submit(action: GenUIAction) async {
        if let prompt = action.payload["prompt"]?.stringValue, !prompt.isEmpty {
            await send(prompt)
        } else {
            await send("The user pressed the “\(action.id)” control.")
        }
    }

    // MARK: Tools

    public func refreshTools() async {
        availableTools = await env.registry.descriptors()
    }

    // MARK: Settings / navigation

    public func openSettings(tab: SettingsTab) {
        settingsTab = tab
        presentingSettings()
    }

    private func presentingSettings() {
        showingSettings = true
        if let onPresentSettings {
            onPresentSettings(settingsTab)
        }
    }

    public func closeSettings() { showingSettings = false }

    public func persistConfig() {
        BudConfigLoader.save(config)
    }

    /// Applies a model switch without touching the rest of the config.
    public func setModel(_ model: String) {
        config.model = model
        env.config = config
        BudConfigLoader.save(config)
    }

    /// Switches provider.
    ///
    /// The model needs no handling: it is stored per provider, so this
    /// automatically lands on whatever was last chosen for the new one — or its
    /// suggested default — instead of carrying a model id the new API has never
    /// heard of.
    public func selectProvider(_ id: String) {
        guard id != config.provider else { return }
        config.provider = id
        env.config = config
        BudConfigLoader.save(config)
        errorMessage = nil
        Task { await refreshTools() }
    }
}
