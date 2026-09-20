import Foundation
import Observation

/// Drives a full agent turn: stream the model, execute whatever tools it asks
/// for, feed the results back, repeat until it answers in prose.
///
/// Owns the transcript because the transcript *is* the loop's state — the
/// model-facing `history` and the user-facing `turns` are two projections of the
/// same sequence of events, and splitting them across types invites drift.
@MainActor
@Observable
public final class AgentRuntime {
    public private(set) var turns: [Turn] = []
    public private(set) var isStreaming = false
    public private(set) var statusText = ""
    public private(set) var lastError: String?
    public private(set) var lastRoundCount = 0

    private let env: AppEnvironment
    private var history: [ChatMessage] = []
    /// Characters emptied from tool results on the last round, so the UI can say
    /// when the budget is doing something rather than leaving it a silent trim.
    public private(set) var droppedFromHistory = 0
    /// The catalogue currently rendered into the system prompt, and which skills
    /// it promotes. Kept so the front of the prompt only changes when the
    /// ranking does; the compiler consumes what this cache produced.
    private var renderedSkills = ""
    private var promotedSkills: [String] = []

    /// What the panel told the next send: the surface it was on and the files it
    /// had staged. Read at request-build time, when the planner is assembled.
    private var sendSurface: String?
    private var sendAttachments: [String] = []

    /// The data-attributed summary this conversation's older half was folded
    /// into, plus how many messages the history held when it was written. The
    /// count is what makes "the last compaction is current" checkable: a summary
    /// is current only while no message has been added since it was written.
    public private(set) var contextSummary: String?
    private var summaryAtMessageCount: Int?
    /// Set at request-build time when the history crossed the watermark and the
    /// last summary is stale; the actual summarisation runs after the turn.
    private var summarisationOwed = false

    /// Phase 1 of the context-harness rework: every round leaves a shadow
    /// ContextMap describing what the request path decided, without touching the
    /// payload. Kept as a bounded ring so a long conversation leaves its recent
    /// rounds inspectable rather than its oldest.
    public private(set) var shadowMaps: [ContextMap] = []
    /// Planner-vs-map divergences from the shadow runs, newest last. The trace
    /// surface for the phase; a later CapabilityIndex phase reads it as its
    /// baseline.
    public private(set) var shadowDivergences: [String] = []
    private var shadowRound = 1

    /// Phase 2 of the context-harness rework: the assembly seam. The runtime
    /// performs the retrieval (notes, skill ranking) and hands the compiler
    /// typed inputs; the compiler produces the payload the request is built
    /// from, byte-identical to the pre-extraction path.
    private let compiler: any ContextCompiling = ContextCompiler()

    /// Phase 6: adaptive planning state. Sticky evidence admits what succeeded
    /// recently; the decision batch and retrieval from planning feed the
    /// memory resolver; the exposed/used bookkeeping is the planner-regret
    /// telemetry.
    private var stickyEvidence = StickyEvidence()
    private var lastDecisionBatch: DecisionBatch?
    private var lastRetrieval: [MemoryCandidate] = []
    /// Regret signals for the turn that just settled, newest last. The
    /// eval-driven tuning phase mines these rather than guessing at thresholds.
    public private(set) var plannerRegret: [String] = []
    private var exposedToolNames: Set<String> = []
    private var usedToolNames: Set<String> = []
    private var failOpenCount = 0
    private var aliasRecoveries: [String] = []
    private var recallCalls = 0
    /// The execution gate (Phase 7), set by the app: the runtime feeds it the
    /// round's execution assessment and injection advisories; the providers
    /// ask it before anything mutates.
    public var harness: ExecutionHarness?

    /// What was last asked. The catalogue is ranked against the current request,
    /// and the newest user message is the whole of what "current" means here.
    private func latestUserMessage() -> String {
        history.last { $0.role == .user }?.content ?? ""
    }

    /// What the model is currently being sent, before the budget trims it. Shown
    /// against the budget in Settings, because a limit nobody can see the distance
    /// to is a limit nobody can set.
    public var historyCharacterCount: Int { history.reduce(0) { $0 + $1.content.count } }

    /// Folds the conversation's older half into a model-written summary, now.
    ///
    /// The manual form of the same flow the runtime runs on its own when a
    /// request crosses the watermark. Returns what it did as a sentence — the
    /// no-op message when the conversation is under the watermark and there is
    /// nothing to summarise. `turns` and the transcript are untouched.
    public func compactConversationNow() async -> String {
        await compactHistory()
    }

    private var runTask: Task<Void, Never>?

    /// Called when a run settles, however it settled.
    ///
    /// `send` returns as soon as the turn has been started, so the only place
    /// that knows a conversation has stopped changing is the end of the loop.
    /// Persistence is driven from here rather than from the send site, which
    /// would save a transcript that was still being written.
    public var onTurnFinished: (@MainActor () -> Void)?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var messageCount: Int { history.count }

    /// The model-facing half of the transcript, for persistence.
    public var modelHistory: [ChatMessage] { history }

    /// One user message and everything it produced, remembered as it was before
    /// the message was sent.
    ///
    /// Retry and "delete from here" are the same operation with different
    /// endings: put things back how they were, then either ask again or stop.
    /// They cannot be done by unwinding the turns, because the model-facing
    /// history holds messages no turn records — every tool round contributes a
    /// call and a result that exist only in `history`. Snapshotting the
    /// before-state is cheaper than reconstructing it and, unlike a reconstruction,
    /// cannot silently disagree with what was actually sent.
    private struct Checkpoint {
        var turns: [Turn]
        var history: [ChatMessage]
        var prompt: String
        /// How many turns existed before this exchange began, which is how a turn
        /// is traced back to the exchange that produced it.
        var turnCount: Int
    }

    private var checkpoints: [Checkpoint] = []

    /// Replaces the transcript with a saved conversation.
    ///
    /// Stops first. A restore during a live run would leave the loop appending
    /// its next delta to a conversation that is no longer on screen, so the
    /// half of it already in flight lands in the wrong one.
    public func restore(turns savedTurns: [Turn], history savedHistory: [ChatMessage]) {
        stop()
        // A conversation loaded from the archive has no checkpoints: nothing in
        // this session ran it, and the exchange boundaries were not saved.
        checkpoints.removeAll()
        turns = savedTurns
        history = savedHistory
        lastError = nil
        statusText = ""
        lastRoundCount = 0
        isStreaming = false
        summarisationOwed = false
        reestablishSummaryState()
    }

    // MARK: - Public control

    public func clear() {
        stop()
        checkpoints.removeAll()
        turns.removeAll()
        history.removeAll()
        lastError = nil
        statusText = ""
        contextSummary = nil
        summaryAtMessageCount = nil
        summarisationOwed = false
        shadowMaps.removeAll()
        shadowDivergences.removeAll()
        shadowRound = 1
        stickyEvidence = StickyEvidence()
        lastDecisionBatch = nil
        lastRetrieval.removeAll()
        plannerRegret.removeAll()
        exposedToolNames.removeAll()
        usedToolNames.removeAll()
        failOpenCount = 0
        aliasRecoveries.removeAll()
        recallCalls = 0
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        if isStreaming {
            if var last = turns.last, last.isStreaming {
                last.isStreaming = false
                turns[turns.count - 1] = last
            }
            isStreaming = false
            statusText = "Stopped"
        }
    }

    /// Appends a user message and runs the turn to completion.
    ///
    /// `context` carries what only the panel knows — the surface and the staged
    /// attachments. The rest of the planning context (query, recent tools,
    /// connected servers) is derived from the runtime's own state at request time.
    public func send(_ text: String, context: ToolPlanningContext = ToolPlanningContext()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        sendSurface = context.surface
        sendAttachments = context.attachmentPaths

        checkpoints.append(
            Checkpoint(turns: turns, history: history, prompt: trimmed, turnCount: turns.count)
        )
        turns.append(Turn(role: .user, segments: [.text(id: UUID().uuidString, text: trimmed)]))
        history.append(ChatMessage(role: .user, content: trimmed))
        lastError = nil
        isStreaming = true

        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    // MARK: - Rewinding

    /// Whether the turn at `index` belongs to an exchange this session ran.
    public func canRewind(toTurnAt index: Int) -> Bool {
        checkpointIndex(forTurnAt: index) != nil
    }

    /// Re-runs the exchange that produced the turn at `index`, discarding
    /// whatever that exchange had produced.
    ///
    /// Retry means "that answer was wrong, ask again": the transcript and the
    /// model's history both go back to how they stood before the question was
    /// asked, and it is asked once more. Anything after it goes too — leaving it
    /// would put answers ahead of the question that prompted them.
    @discardableResult
    public func retry(turnAt index: Int) -> Bool {
        guard !isStreaming, let position = checkpointIndex(forTurnAt: index) else { return false }
        let checkpoint = checkpoints[position]
        // Dropped before restoring, so the re-send below records itself as the
        // newest exchange rather than being shadowed by the one it replaces.
        checkpoints.removeSubrange(position...)
        apply(checkpoint)
        send(checkpoint.prompt)
        return true
    }

    /// Drops the exchange that produced the turn at `index`, without re-running it.
    @discardableResult
    public func deleteFrom(turnAt index: Int) -> Bool {
        guard !isStreaming, let position = checkpointIndex(forTurnAt: index) else { return false }
        let checkpoint = checkpoints[position]
        checkpoints.removeSubrange(position...)
        apply(checkpoint)
        return true
    }

    /// The exchange that produced the turn at `index`: the last one that began at
    /// or before it.
    private func checkpointIndex(forTurnAt index: Int) -> Int? {
        var found: Int?
        for (offset, checkpoint) in checkpoints.enumerated() where checkpoint.turnCount <= index {
            found = offset
        }
        return found
    }

    private func apply(_ checkpoint: Checkpoint) {
        stop()
        turns = checkpoint.turns
        history = checkpoint.history
        lastError = nil
        statusText = ""
        lastRoundCount = 0
        summarisationOwed = false
        reestablishSummaryState()
    }

    // MARK: - Planning

    /// The plan for one round, plus the pieces the loop needs to fail open.
    private struct RoundPlan {
        let plan: ToolPlan
        let tools: [ToolDescriptor]
        let names: Set<String>
        let allDescriptors: [ToolDescriptor]
        /// The whole inventory, agent-only included: the planner plans over the
        /// offered subset, while the shadow ContextMap also inventories what is
        /// reachable only by delegation.
        let fullInventory: [ToolDescriptor]
        let optOutServers: Set<String>
        let context: ToolPlanningContext
        /// The capability index for fail-open resolution, built when
        /// contextCompilerV2 is on; nil keeps the pre-index fail-open path.
        let index: CapabilityIndex?
    }

    /// What the MCP provider knows about the servers behind it.
    private struct ServerInfo {
        let connected: [String]
        let optOut: Set<String>
    }

    /// Assembles the planner context and asks the planner which tools to offer.
    ///
    /// Descriptors are fetched here, filtered after the await rather than before,
    /// and that ordering is the whole safety argument for the `agentOnly` filter:
    /// building the list is what asks the subagent provider for its descriptors,
    /// which is where the agent roster is rebuilt. A tool hidden here therefore
    /// always has an agent that can still reach it — where filtering first would
    /// have a window in which a delegated server's tools were unreachable by
    /// anything at all.
    private func makePlan() async -> RoundPlan {
        let all = await env.registry.descriptors()
        let offered = all.filter { !$0.agentOnly }
        let servers = await connectedServerInfo()

        var context = ToolPlanningContext()
        context.query = latestUserMessage()
        context.surface = sendSurface
        context.attachmentPaths = sendAttachments
        context.recentToolNames = recentToolNames()
        context.connectedServers = servers.connected

        let plan: ToolPlan
        let index: CapabilityIndex?
        if env.config.contextCompilerV2 {
            // Phase 6: the typed decision batch decides exposure, with sticky
            // evidence and explicit intent feeding the resolver.
            let built = CapabilityIndex.build(descriptors: all, alwaysOn: ToolPlanner.alwaysOnCore)
            index = built
            let state = DecisionState(
                query: context.query,
                surface: context.surface,
                attachmentPaths: context.attachmentPaths,
                recentToolNames: context.recentToolNames,
                connectedServers: context.connectedServers,
                round: shadowRound
            )
            let questions = DecisionQuestions.initial(domains: built.capabilities.map(\.id) + ["none"])
            let batch = (try? await DeterministicDecisionEngine().evaluate(state: state, questions: questions))
                ?? DecisionBatch(engineID: "deterministic", answers: [])
            lastDecisionBatch = batch
            lastRetrieval = MemoryRetriever.retrieve(query: context.query, budget: 600)
            plan = CapabilityResolver.stageA(
                state: state,
                batch: batch,
                descriptors: offered,
                stickyTools: stickyEvidence.activeTools(currentRound: shadowRound)
            ).plan
        } else {
            index = nil
            plan = ToolPlanner.plan(context: context, descriptors: offered)
        }
        return RoundPlan(
            plan: plan,
            tools: applySchemaCompaction(plan.descriptors, optOutServers: servers.optOut),
            names: Set(plan.descriptors.map(\.name)),
            allDescriptors: offered,
            fullInventory: all,
            optOutServers: servers.optOut,
            context: context,
            index: index
        )
    }

    /// The connected MCP servers the registry's provider knows about: their names
    /// (for name-matching) and the set that opted out of schema compaction.
    private func connectedServerInfo() async -> ServerInfo {
        guard let mcp = await env.registry.provider(for: "mcp") as? MCPManager else {
            return ServerInfo(connected: [], optOut: [])
        }
        let readyIDs = Set(mcp.statuses.filter { $0.value.state == .ready }.keys)
        let connected = mcp.servers.filter { readyIDs.contains($0.id) }.map(\.name)
        let optOut = Set(mcp.servers.filter(\.compactOptOut).map(\.name))
        return ServerInfo(connected: connected, optOut: optOut)
    }

    /// Schema compaction, off by default and overridable per server: trims a
    /// descriptor's prose unless its server asked to keep it full.
    private func applySchemaCompaction(
        _ descriptors: [ToolDescriptor],
        optOutServers: Set<String>
    ) -> [ToolDescriptor] {
        guard env.config.compactSchemas else { return descriptors }
        return descriptors.map { descriptor in
            optOutServers.contains(descriptor.providerName) ? descriptor : DescriptorCompactor.compact(descriptor)
        }
    }

    /// The tool names the model used in the previous two tool rounds, which is
    /// the best guess at what it is about to use again.
    private func recentToolNames() -> [String] {
        var names: [String] = []
        let rounds = history.reversed().filter { !$0.toolCalls.isEmpty }
        for message in rounds.prefix(2) {
            names.append(contentsOf: message.toolCalls.map(\.name))
        }
        return names
    }

    // MARK: - Semantic compaction

    /// Whether the summary on record still covers the current history: it is
    /// current only while no message has been added since it was written.
    private var summaryIsCurrent: Bool {
        contextSummary != nil && summaryAtMessageCount == history.count
    }

    /// Marks a summarisation as owed, checked at request-build time.
    private func markSummarisationIfNeeded() {
        guard HistoryCompactor.crossesWatermark(
            characterCount: historyCharacterCount,
            budget: env.config.historyBudgetChars
        ), !summaryIsCurrent else { return }
        summarisationOwed = true
    }

    private func summariseIfOwed() async {
        guard summarisationOwed else { return }
        summarisationOwed = false
        _ = await compactHistory()
    }

    /// The shared flow behind both the automatic and the manual compact: ask the
    /// model for a summary, then fold the older half of the history into it.
    private func compactHistory() async -> String {
        guard HistoryCompactor.crossesWatermark(
            characterCount: historyCharacterCount,
            budget: env.config.historyBudgetChars
        ) else {
            return "Context is under the compaction watermark; nothing to summarise."
        }
        // Nothing older than the newest few messages means nothing to replace: a
        // summary would only add characters to a history that already fits.
        guard history.count > HistoryCompactor.keptMessages else {
            return "Context is under the compaction watermark; nothing to summarise."
        }
        statusText = "Compacting context…"
        guard let summary = await askForSummary() else {
            statusText = ""
            return "Compaction was not completed — the summarisation request failed."
        }
        let before = historyCharacterCount
        history = HistoryCompactor.compact(history, summary: summary)
        contextSummary = HistoryCompactor.summaryMessage(summary).content
        summaryAtMessageCount = history.count
        summarisationOwed = false
        statusText = ""
        return "compacted \(BudFormat.count(before - historyCharacterCount)) characters "
            + "of conversation into a summary"
    }

    /// One internal summarisation request, through the same provider path with no
    /// tools offered. Returns the model's summary, or nil when it failed or came
    /// back empty.
    private func askForSummary() async -> String? {
        let config = env.config
        let compiled = compiler.compile(compileInputs(tools: [], omittedNote: nil))
        droppedFromHistory = compiled.metadata.droppedHistoryCharacters
        var messages = [ChatMessage(role: .system, content: compiled.system)] + compiled.messages
        messages.append(ChatMessage(role: .user, content: HistoryCompactor.summarisePrompt))
        let request = ChatRequest(
            model: config.model,
            messages: messages,
            tools: [],
            temperature: nil,
            maxTokens: nil,
            reasoningEffort: nil
        )
        var text = ""
        do {
            for try await event in env.makeBackend().stream(request) {
                if Task.isCancelled { return nil }
                switch event {
                case .contentDelta(let delta):
                    text += delta
                case .usage(let prompt, let completion, _):
                    env.recordUsage(prompt: prompt, completion: completion)
                default:
                    break
                }
            }
        } catch {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Re-derives the summary state from the head of the history, so a restored or
    /// rewound conversation lands with the right notion of what is already
    /// summarised.
    private func reestablishSummaryState() {
        if let first = history.first, first.role == .user,
           first.content.hasPrefix(HistoryCompactor.summaryPrefix) {
            contextSummary = first.content
            summaryAtMessageCount = history.count
        } else {
            contextSummary = nil
            summaryAtMessageCount = nil
        }
    }

    // MARK: - The loop

    private func runLoop() async {
        let config = env.config
        defer {
            isStreaming = false
            onTurnFinished?()
        }

        await runRounds(limit: max(1, config.maxToolRounds))
        finalizeRegret()
        // The turn has settled; a request that crossed the watermark marked a
        // summarisation as owed, and this is where it is paid.
        await summariseIfOwed()
    }

    /// Turns the turn's exposure/usage bookkeeping into named regret signals,
    /// filed as evidence for the eval-driven tuning phase.
    private func finalizeRegret() {
        var lines: [String] = []
        let unused = exposedToolNames.subtracting(usedToolNames)
        if !unused.isEmpty {
            lines.append("unused_exposed_tool: \(unused.sorted().joined(separator: ", "))")
        }
        if failOpenCount > 0 {
            lines.append("missed_capability: fail-open expanded \(failOpenCount) time(s)")
        }
        for alias in aliasRecoveries {
            lines.append("alias_recovery: \(alias)")
        }
        if recallCalls > 0 {
            lines.append("memory_miss: the model called recall \(recallCalls) time(s) mid-task")
        }
        plannerRegret.append(contentsOf: lines)
        for line in lines {
            CognitiveStore.recordContextEvent(
                requestID: nil,
                sourceType: "planner",
                sourceID: nil,
                action: "regret",
                score: nil,
                reason: line
            )
        }
        exposedToolNames.removeAll()
        usedToolNames.removeAll()
        failOpenCount = 0
        aliasRecoveries.removeAll()
        recallCalls = 0
    }

    private func runRounds(limit: Int) async {
        var round = 0
        while round < limit {
            round += 1
            lastRoundCount = round
            statusText = round == 1 ? "Thinking…" : "Round \(round)…"

            var assistant = Turn(role: .assistant, isStreaming: true)
            turns.append(assistant)
            let turnIndex = turns.count - 1
            let turnStarted = Date()

            let plan = await makePlan()
            var outcome = await streamRound(into: &assistant, turnIndex: turnIndex, plan: plan)

            // Fail-open: the model called a tool the planner held back. Expand its
            // group once and retry the round, telling the transcript it happened.
            if case .toolCalls(let calls) = outcome,
               let missing = calls.first(where: { !plan.names.contains($0.name) }),
               let expandedPlan = ToolPlanner.expanded(
                   for: plan.plan, requestedTool: missing.name, allDescriptors: plan.allDescriptors,
                   capabilities: plan.index
               ) {
                let expanded = RoundPlan(
                    plan: expandedPlan,
                    tools: applySchemaCompaction(expandedPlan.descriptors, optOutServers: plan.optOutServers),
                    names: Set(expandedPlan.descriptors.map(\.name)),
                    allDescriptors: plan.allDescriptors,
                    fullInventory: plan.fullInventory,
                    optOutServers: plan.optOutServers,
                    context: plan.context,
                    index: plan.index
                )
                failOpenCount += 1
                if expandedPlan.reason.contains("(as ") {
                    aliasRecoveries.append(expandedPlan.reason)
                }
                assistant.segments.append(
                    .notice(id: UUID().uuidString, text: expandedPlan.reason, kind: .info)
                )
                turns[turnIndex] = assistant
                outcome = await streamRound(into: &assistant, turnIndex: turnIndex, plan: expanded)
            }

            switch outcome {
            case .failed(let message):
                assistant.isStreaming = false
                assistant.error = message
                assistant.duration = Date().timeIntervalSince(turnStarted)
                turns[turnIndex] = assistant
                lastError = message
                statusText = "Error"

                return

            case .cancelled:
                assistant.isStreaming = false
                assistant.duration = Date().timeIntervalSince(turnStarted)
                turns[turnIndex] = assistant
                statusText = "Stopped"

                // What was streamed before the stop is on screen, so the model
                // should know it said it — otherwise asking it to continue has
                // nothing to continue from.
                recordAnswer(assistant)

                return

            case .answered:
                assistant.isStreaming = false
                assistant.duration = Date().timeIntervalSince(turnStarted)
                turns[turnIndex] = assistant
                statusText = ""
                lastError = nil

                // Phase 8 experiment: under the flag, an envelope in the final
                // answer becomes the surface, and the history records the prose
                // without it.
                if env.config.uiOutputDialect {
                    extractOutputDialect(from: &assistant)
                    turns[turnIndex] = assistant
                }

                recordAnswer(assistant)

                return

            case .toolCalls(let calls):
                assistant.isStreaming = false
                turns[turnIndex] = assistant

                // The assistant message carrying the calls must enter history
                // verbatim; the API rejects a `tool` result whose call id was
                // never announced.
                history.append(
                    ChatMessage(
                        role: .assistant,
                        content: assistant.plainText,
                        toolCalls: calls
                    )
                )

                let results = await execute(calls, turnIndex: turnIndex)
                for (call, result) in zip(calls, results) {
                    // Framed, so text that came back from a page or a server is
                    // not read as something the user asked for.
                    history.append(.toolResult(call, result))
                }
                // This turn's last event is its final tool result landing, so its
                // wall time includes the execution that fills in its tool segments.
                turns[turnIndex].duration = Date().timeIntervalSince(turnStarted)
                continue
            }
        }

        // Round budget exhausted without a prose answer.
        let note = "Stopped after \(round) tool rounds without a final answer. "
            + "Raise the round limit in Settings if this is expected."
        turns.append(Turn(role: .assistant, segments: [.notice(id: UUID().uuidString, text: note, kind: .warning)]))
        statusText = ""
        lastError = note
    }

    // MARK: - One streaming round

    /// Puts a finished answer into the model-facing history.
    ///
    /// Only the tool-call path used to append anything, so an assistant's prose
    /// went on screen and nowhere else: every follow-up was sent with the user's
    /// questions and none of the answers, and "what did you just say?" had
    /// nothing to refer to. The transcript looked like a conversation; the
    /// context was a monologue.
    private func recordAnswer(_ assistant: Turn) {
        let answer = assistant.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, assistant.error == nil else { return }
        history.append(ChatMessage(role: .assistant, content: answer))
    }

    private enum RoundOutcome {
        case answered
        case toolCalls([ToolCall])
        case failed(String)
        case cancelled
    }

    private func streamRound(into turn: inout Turn, turnIndex: Int, plan: RoundPlan) async -> RoundOutcome {
        let config = env.config
        let roundStart = Date()
        // Request-build is the one moment the whole history is in front of us, so
        // this is where the compaction watermark is checked.
        markSummarisationIfNeeded()

        let note = ToolPlanner.omittedNote(plan.plan.omitted)
        exposedToolNames.formUnion(plan.tools.map(\.name))
        let compiled = compiler.compile(compileInputs(tools: plan.tools, omittedNote: note))
        droppedFromHistory = compiled.metadata.droppedHistoryCharacters
        let request = ChatRequest(
            model: config.model,
            messages: [ChatMessage(role: .system, content: compiled.system)] + compiled.messages,
            tools: compiled.tools,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            reasoningEffort: config.reasoningEffort
        )

        // Shadow diagnostics, run only after the payload is final: the map
        // describes the request that was built and never participates in
        // building it. Phase 1's entire safety argument is this ordering.
        await recordShadowMap(plan: plan, compiled: compiled)

        // Tool call fragments arrive keyed by index; names/ids land on the first
        // fragment for that index and arguments dribble in afterwards.
        var pending: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        // Request build ends the moment the provider is handed the request; the
        // first token is the first streamed content after that.
        let providerCalled = Date()
        var firstTokenAt: Date?

        do {
            for try await event in env.makeBackend().stream(request) {
                if Task.isCancelled { return .cancelled }

                switch event {
                case .reasoningDelta(let d):
                    turn.appendReasoning(d)
                    turns[turnIndex] = turn

                case .contentDelta(let d):
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    turn.appendText(d)
                    turns[turnIndex] = turn

                case .toolCallDelta(let index, let id, let name, let fragment):
                    var entry = pending[index] ?? (id: "", name: "", args: "")
                    if let id, !id.isEmpty { entry.id = id }
                    if let name, !name.isEmpty { entry.name = name }
                    entry.args += fragment
                    pending[index] = entry

                case .finish(let reason):
                    finishReason = reason

                case .usage(let prompt, let completion, let cached):
                    env.recordUsage(prompt: prompt, completion: completion)
                    turn.promptTokens = prompt
                    turn.completionTokens = completion
                    turn.cachedTokens = cached
                }
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        if Task.isCancelled { return .cancelled }

        // The phases this round can measure. `synthesis` is left nil: the answer
        // arrives in a later round than the tool results it synthesises, so a
        // single round cannot place its boundary. `toolExecution` is filled in by
        // `execute` when this round asked for tools.
        var phases = turn.phases ?? TurnPhases()
        phases.requestBuild = providerCalled.timeIntervalSince(roundStart)
        if let firstTokenAt {
            phases.firstToken = firstTokenAt.timeIntervalSince(providerCalled)
        }
        turn.phases = phases

        if finishReason == "tool_calls" || !pending.isEmpty {
            let calls = pending.keys.sorted().compactMap { index -> ToolCall? in
                guard let e = pending[index], !e.name.isEmpty else { return nil }
                return ToolCall(
                    id: e.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : e.id,
                    name: e.name,
                    arguments: e.args.isEmpty ? "{}" : e.args
                )
            }
            if !calls.isEmpty { return .toolCalls(calls) }
        }

        return turn.plainText.isEmpty ? .answered : .answered
    }

    // MARK: - Tool execution

    /// Tools in one round are independent by construction — the model asked for
    /// all of them at once — so they run concurrently. The transcript is updated
    /// on the main actor as each finishes, which means a fast tool's result shows
    /// up while a slow sibling is still running.
    private func execute(_ calls: [ToolCall], turnIndex: Int) async -> [ToolResult] {
        let toolStart = Date()
        var segmentIDs: [String: String] = [:]
        var providers: [String: String] = [:]

        for call in calls {
            let id = UUID().uuidString
            segmentIDs[call.id] = id
            let provider = await env.registry.providerName(forTool: call.name)
            providers[call.id] = provider
            // The segment carries the call that is about to run, so its clock is
            // stamped here rather than on a detached copy.
            var stamped = call
            stamped.startedAt = Date()
            turns[turnIndex].segments.append(
                .tool(
                    id: id,
                    call: stamped,
                    providerName: provider,
                    state: .running,
                    resultText: nil,
                    ui: nil
                )
            )
        }

        statusText = calls.count == 1
            ? "Running \(calls[0].name)…"
            : "Running \(calls.count) tools…"

        let registry = env.registry
        var results: [String: ToolResult] = [:]

        await withTaskGroup(of: (String, ToolResult).self) { group in
            for call in calls {
                group.addTask {
                    let result = await registry.invoke(
                        name: call.name,
                        arguments: call.parsedArguments,
                        callID: call.id
                    )
                    return (call.id, result)
                }
            }
            for await (callID, result) in group {
                results[callID] = result
                if let segID = segmentIDs[callID] {
                    updateToolSegment(
                        turnIndex: turnIndex,
                        segmentID: segID,
                        state: result.isError ? .failed : .succeeded,
                        result: result
                    )
                }
            }
        }

        statusText = ""

        // Sticky evidence and regret bookkeeping: what actually ran, and
        // whether it worked.
        usedToolNames.formUnion(calls.map(\.name))
        recallCalls += calls.filter { $0.name == "recall" }.count
        for call in calls {
            if let result = results[call.id] {
                stickyEvidence.record(tool: call.name, succeeded: !result.isError, round: shadowRound)
            }
        }
        // Advisory only: results that read like instructions tighten what the
        // next approval dialog says. The deterministic gate still decides.
        harness?.noteInjectionSuspicion(
            results.values.contains { ExecutionPolicy.looksLikeInstructions($0.text) }
        )

        // Tool execution is this whole span, from the moment the calls were about
        // to run to the moment the last result landed.
        var phases = turns[turnIndex].phases ?? TurnPhases()
        phases.toolExecution = Date().timeIntervalSince(toolStart)
        turns[turnIndex].phases = phases

        return calls.map { results[$0.id] ?? .error("No result produced for \($0.name)") }
    }

    private func updateToolSegment(
        turnIndex: Int,
        segmentID: String,
        state: ToolRunState,
        result: ToolResult
    ) {
        guard turns.indices.contains(turnIndex) else { return }
        let segments = turns[turnIndex].segments
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }),
              case .tool(let id, let call, let provider, _, _, _) = segments[idx] else { return }

        // The call's clock stops the moment its result lands, success or failure.
        var stamped = call
        stamped.endedAt = Date()
        turns[turnIndex].segments[idx] = .tool(
            id: id,
            call: stamped,
            providerName: provider,
            state: state,
            resultText: result.text,
            ui: result.ui
        )
    }

    // MARK: - Prompt construction

    /// Phase 1 shadow recording: runs the deterministic analysis over the same
    /// planning inputs the planner saw, with the budget the compiler measured
    /// for the payload that was actually built. Runs once per round, after
    /// `streamRound` compiled the payload, and writes only to the runtime's own
    /// diagnostics.
    private func recordShadowMap(plan: RoundPlan, compiled: CompiledContext) async {
        var map = RequestAnalyzer.analyze(
            inputs: RequestAnalyzer.Inputs(
                query: plan.context.query,
                surface: plan.context.surface,
                attachmentPaths: plan.context.attachmentPaths,
                recentToolNames: plan.context.recentToolNames,
                connectedServers: plan.context.connectedServers,
                round: shadowRound
            ),
            descriptors: plan.fullInventory,
            plan: plan.plan,
            notesCharacters: compiled.metadata.notesCharacters,
            promotedSkills: compiled.metadata.promotedSkills,
            budget: compiled.metadata.ledger
        )

        // Phase 4 shadow: cognitive-store retrieval joins the map's memory
        // candidates, and each inclusion is filed as an evidence event for the
        // recall evals. Diagnostics only — the payload was already built.
        let retrieval = MemoryRetriever.retrieve(query: plan.context.query, budget: 600)
        map.memories.append(contentsOf: retrieval)
        CognitiveStore.recordContextEvent(
            requestID: map.id.uuidString,
            sourceType: "memory",
            sourceID: nil,
            action: "shadow-retrieval",
            score: nil,
            reason: "retrieved \(retrieval.count) candidate(s) for the round"
        )
        for candidate in retrieval {
            CognitiveStore.recordContextEvent(
                requestID: map.id.uuidString,
                sourceType: candidate.id.split(separator: ":").first.map(String.init) ?? "memory",
                sourceID: candidate.id,
                action: "included",
                score: nil,
                reason: candidate.reason
            )
        }
        // Phase 7: the gate sees the round's posture — advisory context for
        // whatever the person is asked to approve.
        harness?.updateAssessment(map.execution)

        shadowRound += 1
        shadowMaps.append(map)
        if shadowMaps.count > 32 { shadowMaps.removeFirst() }
        shadowDivergences.append(contentsOf: ContextMapTrace.divergences(map: map, plan: plan.plan))

        // Phase 5 shadow: the typed decision batch over the same state, compared
        // against the analyzer's map and filed as evidence. The deterministic
        // engine costs nothing to run; the comparison is the parity check the
        // phase's exit criterion asks for.
        let index = CapabilityIndex.build(
            descriptors: plan.fullInventory, alwaysOn: ToolPlanner.alwaysOnCore
        )
        let state = DecisionState(
            query: plan.context.query,
            surface: plan.context.surface,
            attachmentPaths: plan.context.attachmentPaths,
            recentToolNames: plan.context.recentToolNames,
            connectedServers: plan.context.connectedServers,
            round: shadowRound
        )
        let engine = DeterministicDecisionEngine()
        let decisionStart = Date()
        let questions = DecisionQuestions.initial(
            domains: index.capabilities.map(\.id) + ["none"]
        )
        if let batch = try? await engine.evaluate(state: state, questions: questions) {
            let latencyMs = Date().timeIntervalSince(decisionStart) * 1000
            shadowDivergences.append(contentsOf: DecisionTrace.compare(batch: batch, map: map, plan: plan.plan))
            shadowDivergences.append(
                String(format: "decision batch: %d of %d answers in %.2f ms (%@)",
                       batch.answers.count, questions.count, latencyMs, batch.engineID)
            )
            for answer in batch.answers {
                CognitiveStore.recordContextEvent(
                    requestID: map.id.uuidString,
                    sourceType: "decision",
                    sourceID: answer.questionID,
                    action: "answered",
                    score: answer.confidence,
                    reason: "\(answer.rationale) — " + answer.kindDescription
                )
            }
        }

        // Phase 3 shadow: the capability index's view of the same round, next to
        // the planner's. What the index resolves that the planner held back is a
        // potential missed capability; a delegate the query names is the
        // delegation the compact spawn path would resolve.
        let offeredGroups = Set(plan.plan.descriptors.map(\.providerName))
        for match in index.resolve(plan.context.query)
        where match.confidence >= ContextMapTrace.activateThreshold {
            if match.capability.isDelegate {
                shadowDivergences.append(
                    "index resolves '\(plan.context.query)' to delegate '\(match.capability.id)' "
                        + "(" + String(format: "%.2f", match.confidence) + ", \(match.reason))"
                )
            } else if !offeredGroups.contains(match.capability.id) {
                shadowDivergences.append(
                    "index activates '\(match.capability.id)' (\(match.reason)) but the planner omitted it"
                )
            }
        }
        if shadowDivergences.count > 200 {
            shadowDivergences.removeFirst(shadowDivergences.count - 200)
        }
    }

    /// Phase 8 experiment: a final answer that carried a `bud-ui` envelope
    /// renders its surface from the answer, with the envelope itself removed
    /// from the prose both on screen and in the model-facing history.
    private func extractOutputDialect(from turn: inout Turn) {
        let result = UISpecDecoder.decode(turn.plainText)
        guard let payload = result.rawJSON, result.payload.ui != nil else { return }

        var segments: [Segment] = []
        for segment in turn.segments {
            if case .text = segment { continue }
            segments.append(segment)
        }
        let markdown = result.payload.markdown
        if !markdown.isEmpty {
            segments.append(.text(id: UUID().uuidString, text: markdown))
        }
        segments.append(.ui(id: UUID().uuidString, payload: payload))
        turn.segments = segments
    }

    /// The compiler inputs one request needs: retrieval first, compilation
    /// second, so the compiler itself stays a pure transformation.
    ///
    /// Notes are read on every request rather than once at init, because a fact
    /// the model records with `remember` halfway through a conversation has to
    /// reach the next round. Ranked against the tail of the conversation,
    /// because which notes are worth their full text depends on what is being
    /// discussed, and what is being discussed is in the last thing said rather
    /// than the first.
    ///
    /// The skill catalogue is ranked against what was just asked, and
    /// re-rendered only when that changes which skills are promoted. The
    /// catalogue sits at the front of the prompt, which is the part a provider
    /// caches, so rewriting it on every message to say the same thing would
    /// cost more than the lines it saves.
    private func compileInputs(tools: [ToolDescriptor], omittedNote: String?) -> CompilationInputs {
        let config = env.config
        let notes = BudStore.lessonContext(ContextCompiler.conversationTail(of: history))
        let catalogue = SkillContext.catalogue(query: latestUserMessage())
        if catalogue.promoted != promotedSkills {
            promotedSkills = catalogue.promoted
            renderedSkills = catalogue.text
        }
        return CompilationInputs(
            systemPrompt: config.systemPrompt,
            model: config.model,
            reasoningEffort: config.reasoningEffort,
            historyBudgetChars: config.historyBudgetChars,
            history: history,
            tools: tools,
            notes: notes,
            skillCatalogue: renderedSkills,
            promotedSkills: promotedSkills,
            memorySection: env.config.contextCompilerV2
                ? MemoryResolver.section(
                    needsMemory: lastDecisionBatch?.answer(for: "needs_memory")?.booleanValue,
                    candidates: lastRetrieval
                )
                : "",
            omittedNote: omittedNote,
            now: Date()
        )
    }
}
