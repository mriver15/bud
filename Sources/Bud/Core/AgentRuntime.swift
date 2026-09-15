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
    private var runTask: Task<Void, Never>?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var messageCount: Int { history.count }

    // MARK: - Public control

    public func clear() {
        stop()
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

        turns.append(Turn(role: .user, segments: [.text(id: UUID().uuidString, text: trimmed)]))
        history.append(ChatMessage(role: .user, content: trimmed))
        lastError = nil
        isStreaming = true

        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    // MARK: - The loop

    private func runLoop() async {
        let config = env.config
        defer { isStreaming = false }

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

                return

            case .answered:
                assistant.isStreaming = false
                turns[turnIndex] = assistant
                statusText = ""
                lastError = nil

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

    private enum RoundOutcome {
        case answered
        case toolCalls([ToolCall])
        case failed(String)
        case cancelled
    }

    private func streamRound(into turn: inout Turn, turnIndex: Int) async -> RoundOutcome {
        let config = env.config
        let tools = await env.registry.descriptors()
        let request = ChatRequest(
            model: config.model,
            messages: [systemMessage()] + history,
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

    private func systemMessage() -> ChatMessage {
        let config = env.config
        var text = config.systemPrompt
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        text += "\n\nCurrent time: \(stamp.string(from: Date()))."
        text += "\nDefault model for this session: \(config.model)."
        if let effort = config.reasoningEffort { text += " Reasoning effort: \(effort)." }
        return ChatMessage(role: .system, content: text)
    }
}
