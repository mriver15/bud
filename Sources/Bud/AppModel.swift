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

    /// Bumped whenever something wants the caret in the composer — currently
    /// expanding Bud from the collapsed bubble, so a click on it lands ready to
    /// type. A counter rather than a flag because the request has to be
    /// observable even when it repeats.
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
        let providers: [any ToolProvider] = [
            NativeToolsProvider(),
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

    /// Saved conversations, most recently touched first.
    public private(set) var conversations: [Conversation] = []
    /// The conversation the live transcript belongs to.
    public private(set) var currentConversationID: String?

    private var saveTask: Task<Void, Never>?

    public func newConversation() {
        persistConversations()
        currentConversationID = UUID().uuidString
        runtime.clear()
        composerText = ""
        errorMessage = nil
    }

    public func openConversation(id: String) {
        guard id != currentConversationID else { return }
        persistConversations()
        currentConversationID = id
        guard let saved = conversations.first(where: { $0.id == id }) else { return }
        runtime.restore(turns: saved.turns, history: saved.messages)
        errorMessage = nil
    }

    public func deleteConversation(id: String) {
        conversations.removeAll { $0.id == id }
        if currentConversationID == id {
            currentConversationID = nil
            runtime.clear()
        }
        persistConversations()
    }

    /// Folds the live transcript into the archive and writes it.
    public func persistConversations() {
        captureCurrentConversation()
        ConversationStore.save(
            ConversationArchive(currentID: currentConversationID, conversations: conversations)
        )
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

        let messages = runtime.modelHistory
        let now = Date()
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].turns = turns
            conversations[index].messages = messages
            conversations[index].updatedAt = now
            conversations[index].title = Conversation.title(from: turns)
        } else {
            conversations.insert(
                Conversation(
                    id: id,
                    title: Conversation.title(from: turns),
                    createdAt: now,
                    updatedAt: now,
                    turns: turns,
                    messages: messages
                ),
                at: 0
            )
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Brings back the conversation that was open when Bud last quit.
    private func restoreConversations() {
        let archive = ConversationStore.load()
        conversations = archive.conversations
        guard let id = archive.currentID,
              let saved = conversations.first(where: { $0.id == id })
        else {
            // Nothing to resume — a first run, or an archive that was cleared.
            // There still has to be an open conversation to write into, or the
            // first thing the user says has nowhere to go and the archive stays
            // empty for ever, which is exactly what it did.
            currentConversationID = UUID().uuidString
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
