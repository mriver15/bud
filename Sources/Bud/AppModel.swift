import Foundation
import Observation

/// Memory sits straight after General. Both tabs are about Bud rather than about
/// something Bud connects to, and it is the first place somebody looks for what
/// it knows. Further down the rail it would read as a property of the servers or
/// the tool inventory instead of as the assistant's own.
public enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case general, memory, mcp, marketplace, skills, subagents, tools, about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .memory: return "Memory"
        case .mcp: return "Connections"
        case .marketplace: return "Marketplace"
        case .skills: return "Skills"
        case .subagents: return "Agents"
        case .tools: return "Tools"
        case .about: return "About"
        }
    }

    public var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .memory: return "brain"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .marketplace: return "square.grid.2x2"
        case .skills: return "sparkles.rectangle.stack"
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
    case chat, agents, browser, history

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .chat: return "Chat"
        case .agents: return "Agents"
        case .browser: return "Browser"
        case .history: return "History"
        }
    }

    public var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .agents: return "person.3.sequence"
        case .browser: return "globe"
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
    /// The one execution gate (Phase 7): native tools and MCP mutations both
    /// ask through it, and the runtime feeds it the round's execution
    /// assessment and injection advisories.
    public let harness: ExecutionHarness
    /// What can be delegated to: the built-ins, plus whatever the installed skills
    /// and connected servers add. Rebuilt whenever either changes.
    public let agents = AgentRegistry()
    /// Reports a long turn that finished while Bud was not in front.
    private let notifier = CompletionNotifier()

    /// Installed skills and where new ones come from.
    public let skills = SkillRegistry()

    /// The one browser. The tools drive the same view the Browser surface shows,
    /// so what the model is reading and what is on screen are the same page
    /// rather than two that happen to agree.
    public let browser = BrowserEngine()
    public let update: UpdateModel

    // MARK: UI state

    public var composerText: String = ""
    /// Sent commands, oldest first — the composer's history, like a shell's.
    /// Shared across chats; capped so a long session cannot grow it without
    /// bound.
    public var composerHistory: [String] = []
    /// Where history navigation stands: nil while editing fresh text.
    public private(set) var historyCursor: Int?
    /// The draft being edited when navigation began, restored when the cursor
    /// walks back past the newest entry — so browsing history never eats what
    /// was half-written.
    public private(set) var historyDraft = ""

    /// The command-line history's ceiling. Fifty is more than a session of
    /// retries and tweaks, and small enough to scan by eye.
    static let composerHistoryLimit = 50
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

    // MARK: - Agreeing to something

    /// The request waiting for an answer, if there is one. The UI shows this.
    public private(set) var pendingConfirmation: ToolConfirmation?

    /// Requests that have arrived but are not on screen yet, in the order they
    /// asked. A turn can run several tools at once, and two subagents can each be
    /// waiting, so the gate is a queue rather than a single slot: the second one
    /// waits its turn instead of overwriting the first, which would leave a tool
    /// suspended forever on a continuation nobody still holds.
    private var queuedConfirmations: [(ToolConfirmation, CheckedContinuation<ToolConfirmation.Decision, Never>)] = []

    /// Tools the user has said yes to for the rest of this session. Not persisted,
    /// because agreeing once mid-task is not the same act as setting a preference.
    private var sessionApprovedTools: Set<String> = []

    /// One tool, allowed inside one directory, for the rest of this session.
    ///
    /// Keyed by tool *and* directory so a write to `~/Projects/foo` being allowed
    /// does not also clear the way for a shell command in `~` — a different class,
    /// and a different place. In memory like the session scope, because it is a
    /// working-set decision ("this folder is where I am working now"), not a
    /// standing policy.
    private struct DirectoryApproval: Hashable {
        let tool: String
        let directory: String
    }

    private var directoryApprovedTools: Set<DirectoryApproval> = []

    /// Asks before a tool that changes the machine.
    ///
    /// Called from the tool, not from the UI, so a subagent's calls are gated too —
    /// a subagent runs in its own context but on the same machine.
    public func requestConfirmation(_ request: ToolConfirmation) async -> ToolConfirmation.Decision {
        guard config.confirmDangerousTools else { return .allow }
        if isApproved(request) { return .allow }

        return await withCheckedContinuation { continuation in
            queuedConfirmations.append((request, continuation))
            presentNextConfirmation()
        }
    }

    /// Whether a session- or directory-scoped approval already covers this
    /// request, so it can run without being put on screen.
    private func isApproved(_ request: ToolConfirmation) -> Bool {
        if sessionApprovedTools.contains(request.tool) { return true }
        guard let directory = request.scopeDirectory else { return false }
        return directoryApprovedTools.contains(
            DirectoryApproval(tool: request.tool, directory: directory)
        )
    }

    /// Answers the request on screen.
    ///
    /// Safe to call when nothing is pending: a double answer, a click that raced a
    /// keyboard shortcut, or an answer arriving after a cancellation all land here
    /// and do nothing, because the alternative is a crash on a stray click.
    public func answerConfirmation(_ decision: ToolConfirmation.Decision) {
        guard !queuedConfirmations.isEmpty else { return }
        let (request, continuation) = queuedConfirmations.removeFirst()
        switch decision {
        case .allowForSession:
            sessionApprovedTools.insert(request.tool)
        case .allowForDirectory:
            if let directory = request.scopeDirectory {
                directoryApprovedTools.insert(
                    DirectoryApproval(tool: request.tool, directory: directory)
                )
            }
        case .allow, .deny:
            break
        }
        pendingConfirmation = nil
        continuation.resume(returning: decision)
        presentNextConfirmation()
    }

    /// Puts the next queued request on screen, skipping any the user has already
    /// covered for this session while it waited.
    private func presentNextConfirmation() {
        guard pendingConfirmation == nil else { return }

        while let (request, continuation) = queuedConfirmations.first {
            if isApproved(request) {
                queuedConfirmations.removeFirst()
                continuation.resume(returning: .allow)
                continue
            }
            pendingConfirmation = request
            // The panel may be hidden, or behind something. A question nobody can
            // see is a hang, so asking brings it forward.
            NotificationCenter.default.post(name: .budShowPanel, object: nil)
            return
        }
    }

    /// Denies everything waiting. Called when a turn is stopped: the tools a turn
    /// is blocked on are part of that turn, and leaving one suspended would leave
    /// the runtime waiting on an answer that is never coming.
    private func cancelPendingConfirmations() {
        if pendingConfirmation != nil { pendingConfirmation = nil }
        let waiting = queuedConfirmations
        queuedConfirmations = []
        for (_, continuation) in waiting {
            continuation.resume(returning: .deny)
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
        self.subagents = SubagentSupervisor(env: env, agents: agents)
        self.update = UpdateModel()
        // One execution gate for native tools and MCP mutations (Phase 7). The
        // dialog asker is wired after `self` is complete — it captures the
        // panel — and both providers share the one gate.
        self.harness = ExecutionHarness()
        // Wired here because this is the first moment `self` is complete enough
        // to be captured. The closure reads `onQuit` when it is called, not when
        // it is set, so the app delegate can still be the one to fill it in.
        update.onQuit = { [weak self] in self?.onQuit?() }
        runtime.onTurnFinished = { [weak self] in
            self?.scheduleConversationSave()
            self?.turnFinished()
        }
        // Stopping the conversation stops the work it spawned: subagents are
        // its arms, and a stopped question needs no more findings.
        runtime.onStop = { [weak self] in
            self?.subagents.cancelAll()
        }
        harness.setConfirmation { [weak self] request in
            // No model means no panel and nobody to ask. An unasked question
            // is not a yes, so a tool that needs an answer does not get one.
            guard let self else { return .deny }
            return await self.requestConfirmation(request)
        }
        mcp.harness = harness
        runtime.harness = harness
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
        // What can be delegated to is the built-ins plus whatever is installed and
        // connected, so it is assembled from those rather than declared.
        agents.source = { [weak self] in
            (SkillStore.installed(), self?.mcp.servers ?? [])
        }
        // The summary each server agent is described by comes from the tools the
        // server actually offers, read from the manager's live cache at rebuild
        // time. `refresh()` re-reads here, so a server whose tools change gets a
        // refreshed summary on the next rebuild without anyone remembering to
        // update a snapshot.
        agents.serverTools = { [weak self] server in
            self?.mcp.serverTools(id: server.id) ?? []
        }
        agents.refresh()

        let providers: [any ToolProvider] = [
            NativeToolsProvider(harness: harness),
            MemoryToolsProvider(),
            mcp,
            subagents,
            GenUIToolProvider(),
            BrowserToolProvider(engine: browser),
            SkillToolProvider(),
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

    /// Files a sent command into the history: newest last, repeats not
    /// stacked, capped. Kept as its own method so the cap and dedupe are
    /// testable without sending a turn.
    public func recordComposerHistory(_ message: String) {
        if composerHistory.last != message {
            composerHistory.append(message)
            if composerHistory.count > Self.composerHistoryLimit {
                composerHistory.removeFirst()
            }
        }
        historyCursor = nil
        historyDraft = ""
    }

    /// Up/down through the history, shell-style. Returns whether the press did
    /// anything, so the field can keep the caret's own up/down when there is
    /// no history to walk.
    @discardableResult
    public func navigateComposerHistory(previous: Bool) -> Bool {
        guard !composerHistory.isEmpty else { return false }
        if previous {
            let target: Int
            switch historyCursor {
            case nil:
                historyDraft = composerText
                target = composerHistory.count - 1
            case 0:
                return false
            case let cursor?:
                target = cursor - 1
            }
            historyCursor = target
            composerText = composerHistory[target]
        } else {
            guard let cursor = historyCursor else { return false }
            if cursor + 1 < composerHistory.count {
                historyCursor = cursor + 1
                composerText = composerHistory[cursor + 1]
            } else {
                historyCursor = nil
                composerText = historyDraft
                historyDraft = ""
            }
        }
        return true
    }

    /// Cmd-Backspace and Escape: erase the composer, and forget where history
    /// navigation stood. Returns whether there was anything to erase.
    @discardableResult
    public func clearComposer() -> Bool {
        historyCursor = nil
        historyDraft = ""
        let hadContent = !composerText.isEmpty
        composerText = ""
        return hadContent
    }

    public func send(_ text: String? = nil) async {
        let message = (text ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !runtime.isStreaming else { return }
        // Consumed here rather than later so a refused send (over budget) does not
        // leave the paths to attach themselves to the next, unrelated message.
        let attachmentPaths = stagedAttachmentPaths
        stagedAttachmentPaths = []
        // Refused here rather than inside the runtime so the reason is visible: a
        // turn that started and then declined to call the model would look like a
        // failure rather than a limit. The ceiling is on the conversation, so a
        // new chat clears it without anything being reset by hand.
        if isOverBudget {
            errorMessage = "This conversation has spent its "
                + "\(BudFormat.tokens(conversationTokens)) token budget. "
                + "Raise it in Settings › General, or start a new chat."
            return
        }
        recordComposerHistory(message)
        composerText = ""
        errorMessage = nil
        turnStarted()
        runtime.send(
            message,
            context: ToolPlanningContext(
                surface: surface.rawValue,
                attachmentPaths: attachmentPaths
            )
        )
        // The runtime runs the turn on its own task so the caller (a button, a
        // slash command, a generated-UI action) is never blocked by it.
    }

    public func stop() {
        notifier.turnCancelled()
        // A tool blocked on a confirmation is part of the turn being stopped, so
        // stopping has to answer it. Leaving it suspended would leave the runtime
        // waiting on a question that is no longer on screen.
        cancelPendingConfirmations()
        runtime.stop()
    }

    // MARK: - Completion

    /// Remembers when a turn began, so a finished one can be reported only if it
    /// took long enough to have been worth waiting for.
    private func turnStarted() { notifier.turnStarted() }

    private func turnFinished() {
        let answer = turns.last(where: { $0.role == .assistant })?.plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (answer?.isEmpty == false)
            ? String(answer!.prefix(140))
            : "Bud finished this turn."
        notifier.turnFinished(summary: summary)
    }

    // MARK: - Attachments

    /// Files staged by a drop, in the order they were dropped.
    ///
    /// The composer already carried their paths as text; this is the same fact
    /// kept in a form that can be shown. A drop that produces no visible change
    /// is indistinguishable from a drop that failed.
    public private(set) var attachments: [DroppedFile] = []

    /// The paths staged for the turn in flight. The composer clears the chips
    /// before the asynchronous send reads them, so the paths are captured at
    /// clear time and handed to the runtime there.
    private var stagedAttachmentPaths: [String] = []

    /// Stages dropped files and returns the lines to insert into the composer.
    public func stage(files: [DroppedFile]) -> String {
        for file in files where !attachments.contains(where: { $0.id == file.id }) {
            attachments.append(file)
        }
        return files.map(\.stagingLine).joined(separator: "\n")
    }

    /// Removes one attachment, along with the line it put in the composer.
    ///
    /// One line per file is what makes this exact: the chip stands for a line,
    /// and removing the chip removes the line rather than leaving a path behind
    /// for a file the user just took off.
    public func removeAttachment(id: String) {
        guard let file = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        composerText = composerText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != file.stagingLine }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func clearAttachments() {
        stagedAttachmentPaths = attachments.map(\.path)
        attachments.removeAll()
    }

    // MARK: - Cost

    /// What the open conversation has spent, prompt and completion together.
    public var conversationTokens: Int {
        let usage = env.conversationUsage
        return usage.prompt + usage.completion
    }

    public var conversationUsage: (prompt: Int, completion: Int) { env.conversationUsage }

    /// The ceiling for one conversation, or nil when none is set.
    public var conversationBudget: Int? {
        config.conversationTokenBudget > 0 ? config.conversationTokenBudget : nil
    }

    /// Whether the conversation has spent its ceiling.
    public var isOverBudget: Bool {
        guard let budget = conversationBudget else { return false }
        return conversationTokens >= budget
    }

    /// What is left before Bud stops asking, as a fraction of the ceiling.
    public var budgetFraction: Double? {
        guard let budget = conversationBudget else { return nil }
        return min(1, Double(conversationTokens) / Double(budget))
    }

    /// Whether the conversation has spent at least 80% of its ceiling — the point
    /// at which the composer warns rather than waits for the hard stop. Four
    /// fifths is enough warning to compact or raise the ceiling before the next
    /// question bounces, and not so early that the banner is ever-present.
    public var isNearBudget: Bool {
        guard let fraction = budgetFraction else { return false }
        return fraction >= 0.8
    }

    // MARK: - Message actions

    /// Whether this turn can be retried or dropped.
    ///
    /// A turn from an exchange this session ran has a checkpoint, which carries
    /// the exact history snapshot. A restored conversation has none, so its
    /// boundaries are re-derived from the archive: user turns delimit exchanges,
    /// and each pairs with the user message that started it. Both paths answer
    /// the same question — is this turn in a completed exchange — and the
    /// checkpoint is only preferred because it holds the exact pre-exchange
    /// history rather than a prefix reconstructed from what was saved.
    public func canRewind(from turn: Turn) -> Bool {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return false }
        if runtime.canRewind(toTurnAt: index) { return true }
        return boundary(forTurnAt: index) != nil
    }

    /// Asks the same question again, discarding the answer being looked at.
    public func retry(_ turn: Turn) {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return }
        if runtime.canRewind(toTurnAt: index) {
            turnStarted()
            runtime.retry(turnAt: index)
            return
        }
        guard !runtime.isStreaming, let boundary = boundary(forTurnAt: index) else { return }
        turnStarted()
        apply(boundary)
        runtime.send(boundary.prompt)
    }

    /// Drops this turn and everything after it from the conversation. The
    /// archive is written immediately: there is no streaming turn to coalesce
    /// with, and a delete that only reached the screen would come back on
    /// relaunch.
    public func deleteFrom(_ turn: Turn) {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return }
        if runtime.canRewind(toTurnAt: index) {
            guard runtime.deleteFrom(turnAt: index) else { return }
            persistConversations()
            return
        }
        guard !runtime.isStreaming, let boundary = boundary(forTurnAt: index) else { return }
        apply(boundary)
        persistConversations()
    }

    /// The exchange boundary a turn belongs to, re-derived from the archive when
    /// the runtime holds no checkpoint for it. The last boundary at or before the
    /// turn is the exchange that produced it.
    private func boundary(forTurnAt index: Int) -> ExchangeBoundary? {
        Conversation.exchangeBoundaries(turns: runtime.turns, messages: runtime.modelHistory)
            .last { $0.turnCount <= index }
    }

    /// Puts the conversation back to how it stood before an exchange began.
    ///
    /// `restore` is the same truncation the runtime's own checkpoint apply
    /// performs, reached through its public surface rather than a checkpoint:
    /// both projections are cut to the boundary's prefixes, and the runtime's
    /// state (streaming, summary) is reset with them.
    private func apply(_ boundary: ExchangeBoundary) {
        runtime.restore(
            turns: Array(runtime.turns.prefix(boundary.turnCount)),
            history: Array(runtime.modelHistory.prefix(boundary.historyCount))
        )
    }

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
        // Before the id changes, so the conversation being left keeps its figure.
        env.resetConversationUsage()
        currentConversationID = UUID().uuidString
        runtime.clear()
        composerText = ""
        errorMessage = nil
        BudStore.setCurrentConversation(currentConversationID)
        conversationQuery = ""
        // The panel is about this conversation, so it opens on this
        // conversation's activity — which is nothing, for one just started.
        subagents.loadRecentRuns()
        refreshConversations()
    }

    public func openConversation(id: String) {
        guard id != currentConversationID else { return }
        persistConversations()
        // Seeded from the saved conversation, so the figure the header shows is
        // the one this conversation cost rather than the one this session has
        // spent since it was opened.
        let summary = conversations.first { $0.id == id }
        env.resetConversationUsage(
            prompt: summary?.promptTokens ?? 0,
            completion: summary?.completionTokens ?? 0
        )
        currentConversationID = id
        BudStore.setCurrentConversation(id)
        // Before the transcript is restored, so the panel shows this
        // conversation's runs rather than the ones just left behind.
        subagents.loadRecentRuns()
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
        // The deleted conversation's runs went with it, so the panel is re-read
        // either way — what it was showing may no longer exist.
        subagents.loadRecentRuns()
        refreshConversations()
    }

    /// Keeps a conversation at the top of the archive, or lets it fall back into
    /// date order.
    public func togglePin(id: String) {
        let pinned = conversations.first { $0.id == id }?.isPinned ?? false
        BudStore.setPinned(!pinned, id: id)
        refreshConversations()
    }

    /// Renames a conversation.
    ///
    /// A blank name is refused rather than stored: the automatic title is what
    /// the archive falls back on, and an empty row would have nothing to click.
    public func renameConversation(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        BudStore.setTitle(trimmed, id: id)
        refreshConversations()
    }

    /// The conversation as Markdown, or nil when it is no longer in the archive.
    public func markdown(for id: String) -> String? {
        guard let saved = BudStore.load(id: id) else { return nil }
        let summary = conversations.first { $0.id == id }
        return Conversation(
            id: saved.id,
            title: summary?.title ?? Conversation.title(from: saved.turns),
            createdAt: saved.createdAt,
            updatedAt: saved.updatedAt,
            turns: saved.turns,
            messages: saved.messages,
            promptTokens: summary?.promptTokens ?? 0,
            completionTokens: summary?.completionTokens ?? 0,
            isPinned: summary?.isPinned ?? false
        ).markdown()
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

    /// Writes the archive, coalescing bursts, off the main actor.
    ///
    /// A turn mutates the transcript dozens of times while it streams, and the
    /// file is rewritten whole, so saving on every change would rewrite the
    /// entire history for every token. The snapshot is taken before the sleep:
    /// the encode and the write must agree with each other, and once a
    /// conversation grows the encode is the slow part — it does not belong on
    /// the thread the UI is animating on.
    private func scheduleConversationSave() {
        saveTask?.cancel()
        guard let id = currentConversationID else { return }
        let turns = runtime.turns
        guard !turns.isEmpty else { return }
        let snapshot = (
            id: id,
            turns: turns,
            messages: runtime.modelHistory,
            summary: runtime.contextSummary,
            prompt: env.conversationUsage.prompt,
            completion: env.conversationUsage.completion
        )
        saveTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let previous = BudStore.header(id: snapshot.id)
            BudStore.save(Conversation(
                id: snapshot.id,
                title: previous?.title ?? Conversation.title(from: snapshot.turns),
                createdAt: previous?.createdAt ?? Date(),
                updatedAt: Date(),
                turns: snapshot.turns,
                messages: snapshot.messages,
                promptTokens: snapshot.prompt,
                completionTokens: snapshot.completion,
                contextSummary: snapshot.summary
            ))
            await MainActor.run { self?.refreshConversations() }
        }
    }

    private func captureCurrentConversation() {
        guard let id = currentConversationID else { return }
        let turns = runtime.turns
        // Nothing worth keeping yet. Recording an empty conversation would fill
        // the history with rows that open onto a blank panel.
        guard !turns.isEmpty else { return }

        // The header, not the archive: only the stored title and creation date
        // are preserved, and decoding the whole conversation to read two fields
        // made saving cost as much as reading it back.
        let previous = BudStore.header(id: id)
        let spent = env.conversationUsage
        BudStore.save(Conversation(
            id: id,
            // A stored title wins once there is one. It is derived from the first
            // thing said, and recomputing it on every save would silently undo a
            // rename — the one edit the archive offers — on the next turn.
            title: previous?.title ?? Conversation.title(from: turns),
            createdAt: previous?.createdAt ?? Date(),
            updatedAt: Date(),
            turns: turns,
            messages: runtime.modelHistory,
            promptTokens: spent.prompt,
            completionTokens: spent.completion,
            contextSummary: runtime.contextSummary
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

    // MARK: MCP app actions

    /// An MCP app asked to send a message to the agent. Confirmed first — an app
    /// is not the user — then run as a follow-up without touching the composer,
    /// so whatever the person was typing stays theirs.
    func handleAppMessage(serverID: String, params: JSONValue) async -> JSONValue {
        let text = Self.appMessageText(params)
        guard !text.isEmpty else {
            return Self.appError("The app sent an empty message.")
        }
        let serverName = mcp.servers.first(where: { $0.id == serverID })?.name ?? serverID
        let request = ToolConfirmation.appMessage(server: serverName, message: text)
        let decision = await requestAppMessageConfirmation(request)
        guard decision.isAllowed else {
            return Self.appError("The message was not sent.")
        }
        guard !runtime.isStreaming else {
            return Self.appError("Bud is busy; the message was not sent.")
        }
        await followUp(ToolProvenance.appData(serverName, text))
        return .object([:])
    }

    /// Stores context an MCP app pushed for future turns.
    func updateAppModelContext(serverID: String, params: JSONValue) {
        runtime.setAppModelContext(server: serverID, content: Self.appContextText(params))
    }

    /// Records an action an MCP app took, so the agent sees its output on the
    /// next turn instead of only the app's iframe knowing. Returns the result's
    /// text, for the transcript to show once the app is culled.
    @discardableResult
    func recordAppAction(serverID: String, tool: String, result: JSONValue) -> String {
        let text = Self.appResultText(result)
        let serverName = mcp.servers.first(where: { $0.id == serverID })?.name ?? serverID
        runtime.recordAppAction(server: serverName, tool: tool, result: text)
        return text
    }

    /// Starts a turn for a follow-up the user did not type, without touching the
    /// composer. The budget still applies; only the person's draft is spared.
    func followUp(_ message: String) async {
        guard !runtime.isStreaming else { return }
        if isOverBudget {
            errorMessage = "This conversation has spent its "
                + "\(BudFormat.tokens(conversationTokens)) token budget. "
                + "Raise it in Settings › General, or start a new chat."
            return
        }
        errorMessage = nil
        turnStarted()
        runtime.send(message, context: ToolPlanningContext(surface: surface.rawValue))
    }

    /// Always asks, unlike `requestConfirmation`, which a global "don't confirm"
    /// can silence: an app message is not a tool the user configured, it is the
    /// app reaching for the agent.
    private func requestAppMessageConfirmation(
        _ request: ToolConfirmation
    ) async -> ToolConfirmation.Decision {
        await withCheckedContinuation { continuation in
            queuedConfirmations.append((request, continuation))
            presentNextConfirmation()
        }
    }

    // MARK: MCP app payload helpers

    /// The text an app's `ui/message` carries: a single `{type,text}` block, a
    /// `ContentBlock[]` array, or a bare `text` field.
    private static func appMessageText(_ params: JSONValue) -> String {
        if let text = params["text"]?.stringValue { return text }
        if let content = params["content"], let text = contentText(content) { return text }
        return ""
    }

    /// The text of a `ui/update-model-context` update: structured content wins,
    /// then the content blocks.
    private static func appContextText(_ params: JSONValue) -> String {
        if let structured = params["structuredContent"], !structured.isNull {
            return structured.encodedString()
        }
        if let content = params["content"], let text = contentText(content) { return text }
        return ""
    }

    /// The human-readable text of an app's tool result.
    private static func appResultText(_ result: JSONValue) -> String {
        if let content = result["content"], let text = contentText(content) { return text }
        if let structured = result["structuredContent"], !structured.isNull {
            return structured.encodedString()
        }
        return ""
    }

    /// The text of a content block: either one `{type,text}` object or an array
    /// of them.
    private static func contentText(_ content: JSONValue) -> String? {
        if let text = content["text"]?.stringValue { return text }
        let texts = (content.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        let joined = texts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// An app-facing `CallToolResult` shaped error, so the app's SDK rejects the
    /// promise rather than inventing an empty answer.
    private static func appError(_ message: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    // MARK: Tools

    public func refreshTools() async {
        // The roster is rebuilt with the tool list because they change for the same
        // reasons: a server connected, a skill installed. Reading them together
        // keeps the panel from showing a delegate that no longer exists.
        agents.refresh()
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
