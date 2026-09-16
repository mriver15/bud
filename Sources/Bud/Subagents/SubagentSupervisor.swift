import Foundation
import Observation

/// Runs independent workstreams as isolated model conversations.
///
/// Every run owns its own message array and its own backend stream, so one
/// run's tool calls, reasoning and failures never reach a sibling: the agent
/// that dispatched the batch only ever sees the finished digests. The loops run
/// off the main actor — that is the whole point of the pool — and only the
/// published roster is main-actor state.
@MainActor
@Observable
public final class SubagentSupervisor: SubagentSupervising, ToolProvider {
    public let providerID = "subagents"
    public let providerName = "Subagents"

    /// Newest first: the roster is a live activity feed, and past sessions' runs
    /// are appended behind it by `loadRecentRuns` rather than interleaved.
    public private(set) var runs: [SubagentRun] = []

    /// Hard ceiling on model/tool round trips inside one run. A subagent that
    /// loops tools forever would hold a pool slot and never report findings.
    nonisolated static let maxRounds = 12

    nonisolated public static let spawnToolName = ToolNaming.sanitize("spawn_subagents")

    nonisolated private static let spawnSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "tasks": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "title": .object(["type": "string"]),
                        "prompt": .object(["type": "string"]),
                        "model": .object(["type": "string"]),
                        "allow_tools": .object(["type": "boolean"]),
                    ]),
                    "required": .array(["title", "prompt"]),
                ]),
            ]),
        ]),
        "required": .array(["tasks"]),
    ])

    private let env: AppEnvironment
    private let gate: RunGate
    /// Live handles, so one run can be cancelled without disturbing siblings.
    @ObservationIgnored private var handles: [String: Task<Void, Never>] = [:]

    public init(env: AppEnvironment) {
        self.env = env
        self.gate = RunGate(capacity: max(1, env.config.allowParallelSubagents))
    }

    // MARK: - Tools

    public func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: Self.spawnToolName,
                description: """
                Run independent workstreams concurrently, each in a fresh context that \
                cannot see this conversation. Use it when a request splits into genuinely \
                separate slices that can be researched, drafted or computed at the same \
                time; never to do one thing several times over. Every task must be \
                self-contained — state what you already know, what the task must establish, \
                and what it must return. The final message of each task is its deliverable \
                and comes back to you verbatim, so ask for findings, not pleasantries.
                """,
                schema: Self.spawnSchema,
                providerID: providerID,
                providerName: providerName
            )
        ]
    }

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard tool == Self.spawnToolName else {
            return .error("Unknown subagent tool '\(tool)'.")
        }
        guard let rawTasks = arguments["tasks"]?.arrayValue, !rawTasks.isEmpty else {
            return .error("spawn_subagents requires a non-empty 'tasks' array.")
        }

        var specs: [SubagentSpec] = []
        specs.reserveCapacity(rawTasks.count)
        for (offset, item) in rawTasks.enumerated() {
            let label = "Task \(offset + 1)"
            guard let object = item.objectValue else {
                return .error("\(label) is not an object.")
            }
            let title = (object["title"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (object["prompt"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !prompt.isEmpty else {
                return .error("\(label) needs a non-empty 'title' and 'prompt'.")
            }
            // Models mix the two spellings freely; the schema says snake_case but
            // camelCase costs nothing to honour.
            let rawModel = (object["model"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowTools = (object["allow_tools"] ?? object["allowTools"])?.boolValue ?? true
            specs.append(
                SubagentSpec(
                    title: title,
                    prompt: prompt,
                    model: rawModel.isEmpty ? nil : rawModel,
                    allowTools: allowTools
                )
            )
        }

        return .ok(Self.digest(await spawn(specs)))
    }

    // MARK: - Supervision

    /// Admits every spec, runs them concurrently, and resolves once all of them
    /// have settled. The pool capacity is re-read here so a mid-session change in
    /// settings takes effect on the next batch.
    public func spawn(_ specs: [SubagentSpec]) async -> [SubagentRun] {
        guard !specs.isEmpty else { return [] }
        await gate.setCapacity(max(1, env.config.allowParallelSubagents))

        var ids: [String] = []
        ids.reserveCapacity(specs.count)
        var pending: [Task<Void, Never>] = []
        pending.reserveCapacity(specs.count)

        for spec in specs {
            let run = SubagentRun(
                title: spec.title,
                prompt: spec.prompt,
                model: spec.model ?? env.config.model,
                state: .queued,
                startedAt: Date()
            )
            ids.append(run.id)
            runs.insert(run, at: 0)
            // Detached: the run must not execute on the main actor, and detaching
            // is what keeps one cancelled run from taking the batch with it.
            let task = Task.detached { [env, gate] in
                await Self.execute(spec, id: run.id, env: env, gate: gate, publish: self)
            }
            handles[run.id] = task
            pending.append(task)
        }

        for task in pending { await task.value }
        return ids.compactMap { id in runs.first { $0.id == id } }
    }

    public func cancel(id: String) {
        guard let index = runs.firstIndex(where: { $0.id == id }), !runs[index].state.isTerminal else {
            return
        }
        runs[index].state = .cancelled
        runs[index].finishedAt = Date()
        // A run whose task sees the cancellation returns without settling, so
        // this is the only place a cancelled run reaches the store.
        persist(id)
        guard let task = handles.removeValue(forKey: id) else { return }
        // A run parked waiting for a pool slot has no stream to interrupt, so wake
        // it explicitly; leaving it there would let it start after being cancelled.
        let gate = self.gate
        Task { await gate.revoke(id) }
        task.cancel()
    }

    /// Drops every finished row from the roster. This is a view, not an erasure:
    /// the runs themselves stay in the store, so a run cleared here is still
    /// there on the next launch — which is also what keeps history from being
    /// thrown away by a click meant for this session's leftovers.
    public func clearFinished() {
        runs.removeAll { $0.state.isTerminal }
    }

    // MARK: - History

    /// Brings back runs from earlier sessions so the roster opens on what Bud has
    /// already done rather than on an empty list.
    ///
    /// Past runs are appended to `runs` rather than kept in a collection of their
    /// own: the panel and the session statistics both read `runs`, and a second
    /// array would be invisible to them without reaching into files this feature
    /// does not own. They are older than anything this session can dispatch, so
    /// appending preserves the newest-first order that `spawn` maintains by
    /// inserting at the front; `spawn` also looks its own runs up by id, and the
    /// digest is built from the batch it was handed, so neither is disturbed.
    public func loadRecentRuns(limit: Int = 50) {
        let known = Set(runs.map(\.id))
        // Only terminal rows belong in a roster. Nothing is written before a run
        // settles, so a queued or running row can only be a leftover from a
        // process that died mid-run; showing it would report work that is not
        // happening and inflate the running count above.
        let past = BudStore.recentRuns(limit: limit)
            .filter { $0.state.isTerminal && !known.contains($0.id) }
        guard !past.isEmpty else { return }
        runs.append(contentsOf: past)
    }

    // MARK: - Run loop

    private nonisolated static func execute(
        _ spec: SubagentSpec,
        id: String,
        env: AppEnvironment,
        gate: RunGate,
        publish: SubagentSupervisor
    ) async {
        guard await gate.enter(id) else {
            await publish.settle(id, state: .cancelled, error: nil)
            return
        }
        await runLoop(spec, id: id, env: env, publish: publish)
        await gate.leave(id)
    }

    private nonisolated static func runLoop(
        _ spec: SubagentSpec,
        id: String,
        env: AppEnvironment,
        publish: SubagentSupervisor
    ) async {
        let model = spec.model ?? env.config.model
        await publish.markRunning(id, model: model)

        let backend = env.makeBackend()
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt(spec)),
            ChatMessage(role: .user, content: spec.prompt),
        ]
        // `spawn_subagents` is withheld on purpose: nested fan-out would multiply
        // the pool past its cap and every slot could end up waiting on children.
        let tools = spec.allowTools
            ? await env.registry.descriptors().filter { $0.name != spawnToolName }
            : []

        var answer = ""
        var round = 0
        while round < maxRounds {
            round += 1
            if Task.isCancelled { return }

            var content = ""
            var reasoning = ""
            var fragments: [Int: PartialToolCall] = [:]
            let config = env.config
            let request = ChatRequest(
                model: model,
                messages: messages,
                tools: tools,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                reasoningEffort: config.reasoningEffort
            )

            do {
                for try await event in backend.stream(request) {
                    if Task.isCancelled { return }
                    switch event {
                    case .contentDelta(let delta):
                        content += delta
                        await publish.publishStream(id, output: content, reasoning: nil)
                    case .reasoningDelta(let delta):
                        reasoning += delta
                        await publish.publishStream(id, output: nil, reasoning: reasoning)
                    case .toolCallDelta(let index, let callID, let name, let fragment):
                        var partial = fragments[index] ?? PartialToolCall()
                        // The id and name arrive only on the first fragment of an
                        // index; the arguments always stream in pieces.
                        if let callID, partial.id.isEmpty { partial.id = callID }
                        if let name, partial.name.isEmpty { partial.name = name }
                        partial.arguments += fragment
                        fragments[index] = partial
                    case .finish:
                        break
                    case .usage(let prompt, let completion, _):
                        env.recordUsage(prompt: prompt, completion: completion)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await publish.settle(id, state: .failed, error: error.localizedDescription)
                return
            }

            if !content.isEmpty { answer = content }

            // An unnamed call cannot be invoked and must not be advertised to the
            // model either: every tool_call needs a matching tool message.
            let calls = fragments.sorted { $0.key < $1.key }.compactMap { index, partial -> ToolCall? in
                guard !partial.name.isEmpty else { return nil }
                return ToolCall(
                    id: partial.id.isEmpty ? "call_\(round)_\(index)" : partial.id,
                    name: partial.name,
                    arguments: partial.arguments
                )
            }
            guard !calls.isEmpty else { break }

            await publish.publishToolCalls(id, added: calls.count)
            messages.append(ChatMessage(role: .assistant, content: content, toolCalls: calls))
            for call in calls {
                if Task.isCancelled { return }
                let result = await env.registry.invoke(
                    name: call.name,
                    arguments: call.parsedArguments,
                    callID: call.id
                )
                messages.append(
                    ChatMessage(
                        role: .tool,
                        content: result.modelFacingText(),
                        toolCallID: call.id,
                        name: call.name
                    )
                )
            }
        }

        if !answer.isEmpty { await publish.publishStream(id, output: answer, reasoning: nil) }
        await publish.settle(id, state: .done, error: nil)
    }

    private nonisolated static func systemPrompt(_ spec: SubagentSpec) -> String {
        """
        You are a subagent: one of several workstreams running at the same time. \
        The others cannot see you and you cannot see them, so nothing you leave out \
        of your final message exists as far as the rest of the system is concerned.

        Your assignment: \(spec.title)

        Your final message is not read by a human. It is returned verbatim to the \
        agent that dispatched you and folded into the report the user sees. Report \
        findings, not pleasantries: what you established, the concrete evidence \
        (paths, line numbers, values, URLs), anything you could not determine, and \
        what you would do next. No greeting, no restating the assignment, no asking \
        whether to continue.
        """
    }

    // MARK: - Live publication

    @MainActor
    private func markRunning(_ id: String, model: String) {
        mutate(id) { run in
            run.state = .running
            run.model = model
            run.startedAt = Date()
        }
    }

    /// Streams the current round's text so the roster animates while the model is
    /// still talking. Each round overwrites the previous round's narration, which
    /// leaves the finished run holding its final answer rather than its whole
    /// trace.
    @MainActor
    private func publishStream(_ id: String, output: String?, reasoning: String?) {
        mutate(id) { run in
            if let output { run.output = output }
            if let reasoning { run.reasoning = reasoning }
        }
    }

    @MainActor
    private func publishToolCalls(_ id: String, added: Int) {
        mutate(id) { $0.toolCallCount += added }
    }

    /// Cancelling wins over any late failure: a cancelled run is already terminal,
    /// so its partial output stays exactly as the user last saw it.
    @MainActor
    private func settle(_ id: String, state: SubagentState, error: String?) {
        handles[id] = nil
        mutate(id) { run in
            guard !run.state.isTerminal else { return }
            run.state = state
            run.finishedAt = Date()
            run.error = error
        }
        // After the mutation, so the stored row carries the output the run ended
        // with. A run cancelled moments ago is already terminal and already
        // stored; writing it a second time would only repeat the same row.
        persist(id)
    }

    /// Files a settled run away.
    ///
    /// Nothing is written while a run streams: the row is only worth having once
    /// the run is over, and a write per token would be a transaction per token.
    /// The conversation is read at the moment of settling so the run is filed
    /// against whatever the user is looking at when it lands.
    @MainActor
    private func persist(_ id: String) {
        guard let run = runs.first(where: { $0.id == id }), run.state.isTerminal else { return }
        BudStore.recordRun(run, conversationID: BudStore.currentConversationID())
    }

    @MainActor
    private func mutate(_ id: String, _ body: (inout SubagentRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[index])
    }

    // MARK: - Digest

    private nonisolated static func digest(_ runs: [SubagentRun]) -> String {
        runs.map { run in
            let elapsed = run.duration ?? Date().timeIntervalSince(run.startedAt)
            let calls = run.toolCallCount == 1 ? "1 tool call" : "\(run.toolCallCount) tool calls"
            var block = "• \(run.title) — \(run.state.label), \(String(format: "%.1fs", elapsed)), \(calls)"
            if let error = run.error, !error.isEmpty {
                block += "\nerror: \(error)"
            }
            let body = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
            block += "\n" + (body.isEmpty ? "(no output)" : clipped(body, limit: 4_000))
            return block
        }
        .joined(separator: "\n\n")
    }

    private nonisolated static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "\n…[truncated \(text.count - limit) characters]"
    }
}

// MARK: - Tool call fragments

/// One tool call while it is still arriving. DeepSeek streams the arguments as
/// pieces keyed by call index, so they are concatenated until the round ends.
private struct PartialToolCall {
    var id = ""
    var name = ""
    var arguments = ""
}

// MARK: - Pool admission

/// Admission control for the subagent pool.
///
/// The cap is enforced here rather than left to the scheduler: a spec beyond the
/// capacity parks in this queue and only starts when a running one releases its
/// slot. `revoked` carries cancellations that arrive before a run has settled
/// into the queue, and is consumed exactly once — by `enter` when the run never
/// took a slot, or by `leave` when it took one anyway.
private actor RunGate {
    private var capacity: Int
    private var active = 0
    private var waiting: [(id: String, continuation: CheckedContinuation<Bool, Never>)] = []
    private var revoked: Set<String> = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func setCapacity(_ newValue: Int) {
        capacity = max(1, newValue)
        drain()
    }

    /// Resolves `false` when the run was cancelled before it got a slot.
    func enter(_ id: String) async -> Bool {
        if revoked.remove(id) != nil { return false }
        if active < capacity {
            active += 1
            return true
        }
        let granted = await withCheckedContinuation { continuation in
            waiting.append((id, continuation))
        }
        if revoked.remove(id) != nil {
            if granted { leave(id) }
            return false
        }
        return granted
    }

    func leave(_ id: String) {
        revoked.remove(id)
        active -= 1
        drain()
    }

    /// Marks a run cancelled, waking it immediately if it was waiting for a slot.
    func revoke(_ id: String) {
        revoked.insert(id)
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(returning: false)
        }
    }

    private func drain() {
        while active < capacity, !waiting.isEmpty {
            let next = waiting.removeFirst()
            active += 1
            next.continuation.resume(returning: true)
        }
    }
}
