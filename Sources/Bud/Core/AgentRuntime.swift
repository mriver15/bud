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

    /// What was last asked. The catalogue is ranked against the current request,
    /// and the newest user message is the whole of what "current" means here.
    private func latestUserMessage() -> String {
        history.last { $0.role == .user }?.content ?? ""
    }

    /// What the model is currently being sent, before the budget trims it. Shown
    /// against the budget in Settings, because a limit nobody can see the distance
    /// to is a limit nobody can set.
    public var historyChars: Int { history.reduce(0) { $0 + $1.content.count } }
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
    }

    // MARK: - Public control

    public func clear() {
        stop()
        checkpoints.removeAll()
        turns.removeAll()
        history.removeAll()
        lastError = nil
        statusText = ""
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
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

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
    }

    // MARK: - The loop

    private func runLoop() async {
        let config = env.config
        defer {
            isStreaming = false
            onTurnFinished?()
        }

        var round = 0
        while round < max(1, config.maxToolRounds) {
            round += 1
            lastRoundCount = round
            statusText = round == 1 ? "Thinking…" : "Round \(round)…"

            var assistant = Turn(role: .assistant, isStreaming: true)
            turns.append(assistant)
            let turnIndex = turns.count - 1

            let outcome = await streamRound(into: &assistant, turnIndex: turnIndex)

            switch outcome {
            case .failed(let message):
                assistant.isStreaming = false
                assistant.error = message
                turns[turnIndex] = assistant
                lastError = message
                statusText = "Error"

                return

            case .cancelled:
                assistant.isStreaming = false
                turns[turnIndex] = assistant
                statusText = "Stopped"

                // What was streamed before the stop is on screen, so the model
                // should know it said it — otherwise asking it to continue has
                // nothing to continue from.
                recordAnswer(assistant)

                return

            case .answered:
                assistant.isStreaming = false
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
                    history.append(
                        ChatMessage(
                            role: .tool,
                            content: result.modelFacingText(),
                            toolCallID: call.id,
                            name: call.name
                        )
                    )
                }
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

    private func streamRound(into turn: inout Turn, turnIndex: Int) async -> RoundOutcome {
        let config = env.config
        // Everything except what an agent holds.
        //
        // Filtered after the await rather than before, and that ordering is the
        // whole safety argument for this feature: building the list is what asks
        // the subagent provider for its descriptors, which is where the agent
        // roster is rebuilt. A tool hidden here therefore always has an agent that
        // can still reach it — where filtering first would have a window in which
        // a delegated server's tools were unreachable by anything at all.
        let tools = await env.registry.descriptors().filter { !$0.agentOnly }
        let request = ChatRequest(
            model: config.model,
            messages: [systemMessage()] + boundedHistory(),
            tools: tools,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            reasoningEffort: config.reasoningEffort
        )

        // Tool call fragments arrive keyed by index; names/ids land on the first
        // fragment for that index and arguments dribble in afterwards.
        var pending: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        do {
            for try await event in env.makeBackend().stream(request) {
                if Task.isCancelled { return .cancelled }

                switch event {
                case .reasoningDelta(let d):
                    turn.appendReasoning(d)
                    turns[turnIndex] = turn

                case .contentDelta(let d):
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
                }
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        if Task.isCancelled { return .cancelled }

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
        var segmentIDs: [String: String] = [:]
        var providers: [String: String] = [:]

        for call in calls {
            let id = UUID().uuidString
            segmentIDs[call.id] = id
            let provider = await env.registry.providerName(forTool: call.name)
            providers[call.id] = provider
            turns[turnIndex].segments.append(
                .tool(
                    id: id,
                    call: call,
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

        turns[turnIndex].segments[idx] = .tool(
            id: id,
            call: call,
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
    /// full text, the transcript keeps showing it, and the model is told it can
    /// call the tool again — which is true, and is the only recovery it needs.
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
            let marker = droppedMarker(characters: content.count)
            guard marker.count < content.count else { continue }
            total -= content.count - marker.count
            dropped += content.count
            bounded[index].content = marker
        }
        return (bounded, dropped)
    }

    /// Below this a result is cheaper to send than to explain away.
    nonisolated private static let dropThreshold = 400

    nonisolated private static func droppedMarker(characters: Int) -> String {
        "[dropped from the conversation to stay inside the context budget: "
            + "\(BudFormat.count(characters)) characters. The user can still see this "
            + "result, and calling the tool again will produce it fresh.]"
    }

    private func systemMessage() -> ChatMessage {
        let config = env.config
        var text = config.systemPrompt
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        text += "\n\nCurrent time: \(stamp.string(from: Date()))."
        text += "\nDefault model for this session: \(config.model)."
        if let effort = config.reasoningEffort { text += " Reasoning effort: \(effort)." }

        // Read on every request rather than once at init, because a fact the
        // model records with `remember` halfway through a conversation has to
        // reach the next round; a copy taken when the runtime was built would
        // only surface after a restart. An empty result means there is nothing
        // to say, and an empty "things you remember" heading would cost a
        // paragraph of context to tell the model it knows nothing.
        let notes = BudStore.lessonContext()
        if !notes.isEmpty { text += "\n\n" + notes }

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

        return ChatMessage(role: .system, content: text)
    }
}
