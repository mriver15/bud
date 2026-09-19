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
    /// it promotes. Kept so the front of the prompt only changes when the answer
    /// does.
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

    /// What was last asked. The catalogue is ranked against the current request,
    /// and the newest user message is the whole of what "current" means here.
    private func latestUserMessage() -> String {
        history.last { $0.role == .user }?.content ?? ""
    }

    /// The tail of the conversation, for ranking what is worth remembering.
    ///
    /// The subject of a conversation is mostly in its tail: what was said a dozen
    /// turns ago is a weaker guess at what a note would be used for than what was
    /// said in the last exchange. Tool results are skipped — they are the largest
    /// thing in the history and the least like something a note is about — and
    /// every message is capped, because this is a query to rank against rather
    /// than context to send.
    ///
    /// Apart from the runtime so it can be exercised without one, like `bounded`:
    /// what makes the cut is the whole of the behaviour.
    nonisolated static func conversationTail(
        of history: [ChatMessage],
        messages: Int = 6,
        perMessage: Int = 1_500
    ) -> String {
        var tail: [String] = []
        for message in history.reversed() where message.role == .user || message.role == .assistant {
            tail.append(String(message.content.prefix(perMessage)))
            if tail.count == messages { break }
        }
        return tail.reversed().joined(separator: "\n")
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
        let optOutServers: Set<String>
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

        let plan = ToolPlanner.plan(context: context, descriptors: offered)
        return RoundPlan(
            plan: plan,
            tools: applySchemaCompaction(plan.descriptors, optOutServers: servers.optOut),
            names: Set(plan.descriptors.map(\.name)),
            allDescriptors: offered,
            optOutServers: servers.optOut
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
        var messages = [systemMessage()] + boundedHistory()
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
        // The turn has settled; a request that crossed the watermark marked a
        // summarisation as owed, and this is where it is paid.
        await summariseIfOwed()
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
                   for: plan.plan, requestedTool: missing.name, allDescriptors: plan.allDescriptors
               ) {
                let expanded = RoundPlan(
                    plan: expandedPlan,
                    tools: applySchemaCompaction(expandedPlan.descriptors, optOutServers: plan.optOutServers),
                    names: Set(expandedPlan.descriptors.map(\.name)),
                    allDescriptors: plan.allDescriptors,
                    optOutServers: plan.optOutServers
                )
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
        let request = ChatRequest(
            model: config.model,
            messages: [systemMessage(omittedNote: note)] + boundedHistory(),
            tools: plan.tools,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            reasoningEffort: config.reasoningEffort
        )

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

                case .usage(let prompt, let completion, _):
                    env.recordUsage(prompt: prompt, completion: completion)
                    turn.promptTokens = prompt
                    turn.completionTokens = completion
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

    // MARK: - What the conversation costs

    /// The conversation as the model receives it, trimmed to the budget.
    ///
    /// History grew without limit. A result is capped at 24,000 characters when it
    /// arrives and nothing capped the total, so every round re-sent every result
    /// the conversation had ever produced — and the conversation that most needs a
    /// long one is the one that called the most tools.
    ///
    /// Only tool *results* are emptied, and only their contents. The call and its
    /// result have to stay paired or the provider rejects the whole request, so a
    /// dropped result becomes a line saying it was dropped rather than a missing
    /// message. Oldest first, and never the newest: the newest result is the one
    /// the model has not read yet.
    ///
    /// This bounds what the *model* carries, not what happened. `turns` keeps the
    /// full text, the transcript keeps showing it, and the model is told how to
    /// recover — call the tool again, or `read_stored` when the result had already
    /// spilled to the store — which is true, and is all the recovery it needs.
    private func boundedHistory() -> [ChatMessage] {
        let bounded = Self.bounded(history, budget: env.config.historyBudgetChars)
        droppedFromHistory = bounded.dropped
        return bounded.messages
    }

    /// The trimming itself, apart from the runtime so it can be exercised without
    /// one: what gets emptied and what does not is the whole of the behaviour.
    nonisolated static func bounded(
        _ messages: [ChatMessage],
        budget: Int
    ) -> (messages: [ChatMessage], dropped: Int) {
        guard budget > 0, !messages.isEmpty else { return (messages, 0) }

        var total = messages.reduce(0) { $0 + $1.content.count }
        guard total > budget else { return (messages, 0) }

        var bounded = messages
        var dropped = 0
        for index in bounded.indices {
            guard total > budget, index < bounded.count - 1 else { break }
            guard bounded[index].role == .tool else { continue }
            let content = bounded[index].content
            // Not worth emptying something the marker would be nearly as long as.
            guard content.count > dropThreshold else { continue }
            let marker = droppedMarker(for: content)
            guard marker.count < content.count else { continue }
            total -= content.count - marker.count
            dropped += content.count
            bounded[index].content = marker
        }
        return (bounded, dropped)
    }

    /// Below this a result is cheaper to send than to explain away. The marker is
    /// now under ~90 characters, so this sits a few times above it: a result has
    /// to be comfortably larger than its replacement before the rewrite is worth
    /// the churn.
    nonisolated private static let dropThreshold = 200

    nonisolated private static func droppedMarker(for content: String) -> String {
        if let handle = storedHandle(in: content) {
            // A spilled result keeps its handle: the data is still on disk, and
            // `read_stored` is how the model gets back to it.
            return "[dropped to fit the budget; still stored as \(handle) — read_stored to retrieve.]"
        }
        return "[dropped \(BudFormat.count(content.count)) characters; call the tool again to see it.]"
    }

    /// The `store_` handle a spilled result carries, when its data is still there.
    ///
    /// The spill marker sits at the end of the content, so the *last* handle in
    /// the text is the one for this result; any earlier one is part of the result's
    /// own text. A handle is only kept when the file still exists — a token that
    /// merely looks like a handle points nowhere.
    nonisolated private static func storedHandle(in content: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"store_[0-9a-fA-F]{8}"#) else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = expression.matches(in: content, range: range).last,
              let tokenRange = Range(match.range, in: content) else { return nil }
        let token = String(content[tokenRange]).lowercased()
        return FileManager.default.fileExists(atPath: StoredResults.url(for: token).path) ? token : nil
    }

    private func systemMessage(omittedNote: String? = nil) -> ChatMessage {
        let config = env.config
        var text = config.systemPrompt
        text += "\nDefault model for this session: \(config.model)."
        if let effort = config.reasoningEffort { text += " Reasoning effort: \(effort)." }

        // Read on every request rather than once at init, because a fact the
        // model records with `remember` halfway through a conversation has to
        // reach the next round; a copy taken when the runtime was built would
        // only surface after a restart. An empty result means there is nothing
        // to say, and an empty "things you remember" heading would cost a
        // paragraph of context to tell the model it knows nothing.
        //
        // Ranked against the tail of the conversation, because which notes are
        // worth their full text depends on what is being discussed, and what is
        // being discussed is in the last thing said rather than the first.
        //
        // Fenced, because this is the system prompt: a note is written from
        // whatever the model was told, including a sentence that arrived in a
        // fetched page or an MCP result, and here it sits in the most-trusted
        // part of the request with nothing to say it is data.
        let notes = BudStore.lessonContext(Self.conversationTail(of: history))
        if !notes.isEmpty { text += "\n\n" + ToolProvenance.rememberedNotes(notes) }

        // Read on every request for the same reason the notes are: a skill
        // installed halfway through a conversation has to be usable in it.
        //
        // Ranked against what was just asked, and re-rendered only when that
        // changes which skills are promoted. The catalogue sits at the front of the
        // prompt, which is the part a provider caches, so rewriting it on every
        // message to say the same thing would cost more than the lines it saves.
        let catalogue = SkillContext.catalogue(query: latestUserMessage())
        if catalogue.promoted != promotedSkills {
            promotedSkills = catalogue.promoted
            renderedSkills = catalogue.text
        }
        if !renderedSkills.isEmpty { text += "\n\n" + renderedSkills }

        // What the planner held back this turn, so the model knows the rest
        // exists and can summon it by name rather than assuming it was never there.
        if let omittedNote, !omittedNote.isEmpty {
            text += "\n\n" + omittedNote
        }

        // The one line that changes every minute rides last. Providers cache the
        // front of the prompt, so keeping the volatile clock at the end means a
        // new timestamp invalidates only the tail instead of the whole stable
        // prefix above it.
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        text += "\n\nCurrent time: \(stamp.string(from: Date()))."

        return ChatMessage(role: .system, content: text)
    }
}
