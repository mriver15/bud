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

    /// The registry reads this on every descriptors pass as its cache key, so it
    /// must answer "did the delegation description change" without this type
    /// owning the roster — the agent registry holds it, and the app rebuilds it
    /// directly, so a counter kept here could not see the app's own
    /// `agents.refresh()`. Fold the names and summaries the description is built
    /// from into one deterministic value: cheap for a handful of agents, and it
    /// changes exactly when `spawnDescription(roster:)` would.
    public var descriptorRevision: Int {
        var hash = 5381
        for agent in agents.agents {
            for byte in agent.name.utf8 { hash = (hash &* 33) &+ Int(byte) }
            for byte in agent.summary.utf8 { hash = (hash &* 33) &+ Int(byte) }
        }
        return hash
    }

    /// Newest first: the roster is a live activity feed, and past sessions' runs
    /// are appended behind it by `loadRecentRuns` rather than interleaved.
    public private(set) var runs: [SubagentRun] = []

    /// Hard ceiling on model/tool round trips inside one run. A subagent that
    /// loops tools forever would hold a pool slot and never report findings.
    nonisolated static let maxRounds = 12

    /// How deep delegation may go: a root run may delegate, and what it delegates
    /// to may not.
    ///
    /// One level, deliberately. The pool cap bounds workstreams *the user asked
    /// for*, so nesting has to be bounded somewhere else or it multiplies straight
    /// past it — six roots each fanning out to four children is twenty-four model
    /// conversations, and the second level would be another ninety-six.
    ///
    /// Nested runs do not take a pool slot, which is also why they cannot be the
    /// thing that gets capped: a root holding a slot while it waits for a child to
    /// be admitted is a deadlock the moment the pool is full of roots doing the
    /// same. Children belong to the parent's slot, and the depth limit is what
    /// stops that from being unbounded.
    nonisolated static let maxDepth = 1

    /// How many children one run may delegate in a single call. The depth limit
    /// bounds the tree; this bounds the widest part of it.
    nonisolated static let maxChildren = 4

    /// The ceiling on a subagent's final message as the parent reads it. A handoff
    /// longer than this is truncated on a line boundary before it reaches the
    /// parent, and the suffix points at the Agents panel, which keeps the whole
    /// run. Six thousand characters is one long, well-evidenced answer — four
    /// sections plus real paths and line numbers fit inside it, and a parent that
    /// folds several handoffs together is still handed digests, not novels.
    nonisolated static let subagentOutputBudget = 6_000

    nonisolated public static let spawnToolName = ToolNaming.sanitize("spawn_subagents")

    nonisolated private static func spawnSchema(compactCapability: Bool) -> JSONValue {
        var properties: [String: JSONValue] = [
            "title": .object(["type": "string"]),
            "prompt": .object(["type": "string"]),
            "model": .object(["type": "string"]),
            "allow_tools": .object(["type": "boolean"]),
            "agent": .object([
                "type": "string",
                "description": .string(
                    compactCapability
                        ? "The agent to run this task as, by name. Omit both this and 'capability' "
                            + "for an unnamed workstream with every tool available."
                        : "The agent to run this task as, by name. Omit for an unnamed "
                            + "workstream with every tool available."
                ),
            ]),
        ]
        if compactCapability {
            properties["capability"] = .object([
                "type": "string",
                "description": .string(
                    "What the task needs, in your own words — e.g. 'competitive pokemon "
                        + "analysis' or 'reading pdf forms'. Bud resolves this locally to the "
                        + "matching agent, so the roster does not have to be sent to you."
                ),
            ])
        }
        return .object([
            "type": "object",
            "properties": .object([
                "tasks": .object([
                    "type": "array",
                    "items": .object([
                        "type": "object",
                        "properties": .object(properties),
                        "required": .array(["title", "prompt"]),
                    ]),
                ]),
            ]),
            "required": .array(["tasks"]),
        ])
    }

    private let env: AppEnvironment
    /// What this can hand work to. Held rather than passed to `spawn`, because the
    /// tool description is generated from it and the description is read by every
    /// model call the session makes.
    private let agents: AgentRegistry
    private let gate: RunGate
    /// Live handles, so one run can be cancelled without disturbing siblings.
    @ObservationIgnored private var handles: [String: Task<Void, Never>] = [:]

    public init(env: AppEnvironment, agents: AgentRegistry) {
        self.env = env
        self.agents = agents
        self.gate = RunGate(capacity: max(1, env.config.allowParallelSubagents))
    }

    // MARK: - Tools

    public func toolDescriptors() async -> [ToolDescriptor] {
        // Read at request time rather than remembered. A description written when
        // the session started would keep naming an agent that has since been
        // uninstalled, and the model would keep choosing it.
        agents.refresh()
        // contextCompilerV2 keeps the roster out of the parent prompt: the
        // description carries the delegation contract and a discovery affordance,
        // and the model hands tasks over by capability, resolved locally.
        let compact = env.config.contextCompilerV2
        return [
            ToolDescriptor(
                name: Self.spawnToolName,
                description: compact
                    ? Self.spawnDescriptionCompact()
                    : Self.spawnDescription(roster: agents.roster()),
                schema: Self.spawnSchema(compactCapability: compact),
                providerID: providerID,
                providerName: providerName
            )
        ]
    }

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard tool == Self.spawnToolName else {
            return .error("Unknown subagent tool '\(tool)'.")
        }
        switch Self.parse(arguments, depth: 0, parentID: nil) {
        case .failure(let problem):
            return .error(problem.message)
        case .success(let specs):
            if let refusal = refusal(for: specs) { return .error(refusal) }
            return .ok(Self.digest(await spawn(specs)))
        }
    }

    /// An agent named that is not there, or a capability nothing matches
    /// confidently.
    ///
    /// Caught here rather than left to run unnamed, because the two failures are
    /// not the same size: a task that quietly loses its agent runs with the wrong
    /// instructions and the wrong tools and still comes back sounding confident.
    /// Answering with the names that do exist costs one round trip and fixes it.
    private func refusal(for specs: [SubagentSpec]) -> String? {
        let named = specs.compactMap(\.agent)
        if let unknown = named.first(where: { agents.named($0) == nil }) {
            let available = agents.agents.map(\.name)
            guard !available.isEmpty else {
                return "There is no agent named '\(unknown)'. None are available in this session."
            }
            return "There is no agent named '\(unknown)'. Available: \(available.joined(separator: ", "))."
        }
        // Capability wording is resolved locally; a wording nothing matches
        // confidently is refused with the closest names rather than run with a
        // guessed agent.
        for spec in specs where spec.agent == nil {
            guard let capability = spec.capability, !capability.isEmpty else { continue }
            let resolution = DelegateResolver.resolve(capability, agents: agents.agents)
            if resolution.agentID == nil {
                let available = agents.agents.map(\.name)
                let hint = resolution.candidates.isEmpty
                    ? "No agent matches '\(capability)'."
                    : "No agent clearly matches '\(capability)'. Closest: "
                        + resolution.candidates.joined(separator: ", ") + "."
                guard !available.isEmpty else {
                    return hint + " None are available in this session."
                }
                return hint + " Available: \(available.joined(separator: ", "))."
            }
        }
        return nil
    }

    /// Reads the task list. Shared with the nested path so a task means the same
    /// thing whether the conversation asked for it or a subagent did.
    nonisolated static func parse(
        _ arguments: JSONValue,
        depth: Int,
        parentID: String?
    ) -> Result<[SubagentSpec], SpecProblem> {
        guard let rawTasks = arguments["tasks"]?.arrayValue, !rawTasks.isEmpty else {
            return .failure(SpecProblem(message: "\(spawnToolName) requires a non-empty 'tasks' array."))
        }

        var specs: [SubagentSpec] = []
        specs.reserveCapacity(rawTasks.count)
        for (offset, item) in rawTasks.enumerated() {
            let label = "Task \(offset + 1)"
            guard let object = item.objectValue else {
                return .failure(SpecProblem(message: "\(label) is not an object."))
            }
            let title = (object["title"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (object["prompt"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !prompt.isEmpty else {
                return .failure(
                    SpecProblem(message: "\(label) needs a non-empty 'title' and 'prompt'.")
                )
            }
            // Models mix the two spellings freely; the schema says snake_case but
            // camelCase costs nothing to honour.
            let rawModel = (object["model"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowTools = (object["allow_tools"] ?? object["allowTools"])?.boolValue ?? true
            // Also camelCase, because it is the spelling the rest of the tool
            // surface uses and the model reaches for it on the first try.
            let rawAgent = (object["agent"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawCapability = (object["capability"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            specs.append(
                SubagentSpec(
                    title: title,
                    prompt: prompt,
                    model: rawModel.isEmpty ? nil : rawModel,
                    allowTools: allowTools,
                    agent: rawAgent.isEmpty ? nil : rawAgent,
                    capability: rawCapability.isEmpty ? nil : rawCapability,
                    depth: depth,
                    parentID: parentID
                )
            )
        }
        return .success(specs)
    }

    /// A run delegating part of its own work.
    ///
    /// Reached from inside a subagent, not through the registry: the registry routes
    /// by name and has no idea who is calling, so a tool reached that way could not
    /// know how deep it already was. The run that owns the loop knows, so it passes
    /// the depth in directly.
    public func spawnNested(_ arguments: JSONValue, parent: String, depth: Int) async -> ToolResult {
        guard depth < Self.maxDepth else {
            return .error(
                "This run is \(depth) level\(depth == 1 ? "" : "s") deep and delegation stops at "
                    + "\(Self.maxDepth). Do the work here, or report what needs delegating."
            )
        }
        switch Self.parse(arguments, depth: depth + 1, parentID: parent) {
        case .failure(let problem):
            return .error(problem.message)
        case .success(let specs):
            if let refusal = refusal(for: specs) { return .error(refusal) }
            // The parent's own work is already consuming model time; a delegation
            // that fans wider than the pool is a batch that finishes later than
            // doing it serially would have.
            let capped = Array(specs.prefix(Self.maxChildren))
            let note = specs.count > capped.count
                ? "\n\n(\(specs.count - capped.count) of \(specs.count) tasks were not started: "
                    + "at most \(Self.maxChildren) can be delegated at a time.)"
                : ""
            return .ok(Self.digest(await spawn(capped)) + note)
        }
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
            // Resolved here, on the main actor, so the detached loop is handed a
            // value rather than a registry it would have to reach back for. An
            // agent the model named and got wrong is refused before this point,
            // so a spec that names one always resolves. A capability wording
            // resolves the same way — refused before this point when nothing
            // matched confidently, so a wording that reached here names an agent.
            let effectiveAgent: String?
            var capabilityNote: String?
            if let agent = spec.agent {
                effectiveAgent = agent
            } else if let capability = spec.capability, !capability.isEmpty,
                      let resolved = DelegateResolver.resolve(capability, agents: agents.agents).agentID {
                effectiveAgent = resolved
                capabilityNote = "capability '\(capability)'"
            } else {
                effectiveAgent = nil
            }
            let agent = effectiveAgent.flatMap { agents.named($0) }
            // An agent may name a model; the task may override it; the session is
            // the floor. In that order, because each is more specific than the last.
            let model = spec.model ?? agent?.model ?? env.config.model
            var run = SubagentRun(
                title: spec.title,
                prompt: spec.prompt,
                model: model,
                state: .queued,
                startedAt: Date(),
                agent: agent?.name,
                parentID: spec.parentID,
                depth: spec.depth
            )
            // A named agent that no longer resolves is still worth showing as the
            // thing that was asked for, rather than as an unnamed run. The same
            // for a capability: the resolution is the audit trail of what the
            // model asked for and what it became.
            if run.agent == nil { run.agent = spec.agent ?? capabilityNote }
            let runID = run.id
            ids.append(runID)
            runs.insert(run, at: 0)
            // Detached: the run must not execute on the main actor, and detaching
            // is what keeps one cancelled run from taking the batch with it. The id
            // is copied out first so the closure captures a constant rather than the
            // whole mutable run.
            let task = Task.detached { [env, gate] in
                await Self.execute(spec, agent: agent, id: runID, env: env, gate: gate, publish: self)
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
        agent: AgentDefinition?,
        id: String,
        env: AppEnvironment,
        gate: RunGate,
        publish: SubagentSupervisor
    ) async {
        // Only work the conversation asked for takes a pool slot. A nested run is
        // part of its parent's slice, and a parent that holds a slot while waiting
        // for a child to be admitted deadlocks the moment the pool is full of
        // parents doing the same thing. The depth limit is what bounds the nesting
        // that this would otherwise leave unbounded.
        let nested = spec.depth > 0
        let admitted = nested ? true : await gate.enter(id)
        guard admitted else {
            await publish.settle(id, state: .cancelled, error: nil)
            return
        }
        await runLoop(spec, agent: agent, id: id, env: env, publish: publish)
        if !nested { await gate.leave(id) }
    }

    private nonisolated static func runLoop(
        _ spec: SubagentSpec,
        agent: AgentDefinition?,
        id: String,
        env: AppEnvironment,
        publish: SubagentSupervisor
    ) async {
        let model = spec.model ?? agent?.model ?? env.config.model
        await publish.markRunning(id, model: model)

        let backend = env.makeBackend()
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt(spec, agent: agent)),
            ChatMessage(role: .user, content: spec.prompt),
        ]
        // The agent's own tool list, intersected with what this session actually
        // has. A named tool that does not exist simply is not there, which is the
        // right reading of a list written against a different session's servers.
        var tools: [ToolDescriptor] = []
        if spec.allowTools {
            tools = await env.registry.descriptors()
            if let agent { tools = tools.filter { agent.allows($0.name) } }
        }
        // Delegation is offered while there is depth left for it. Withheld past
        // that, so the model is not handed a tool whose only answer is a refusal.
        if spec.depth >= maxDepth {
            tools.removeAll { $0.name == spawnToolName }
        }

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
                // Routed here rather than through the registry for the one tool
                // that has to know how deep it already is. The registry matches on
                // name and cannot tell which run is asking.
                let result: ToolResult
                if call.name == spawnToolName, spec.depth < maxDepth {
                    result = await publish.spawnNested(
                        call.parsedArguments, parent: id, depth: spec.depth
                    )
                } else {
                    result = await env.registry.invoke(
                        name: call.name,
                        arguments: call.parsedArguments,
                        callID: call.id
                    )
                }
                messages.append(.toolResult(call, result))
            }
        }

        if !answer.isEmpty { await publish.publishStream(id, output: answer, reasoning: nil) }
        await publish.settle(id, state: .done, error: nil)
    }

    /// What the model is told about delegating, including who it can delegate to.
    ///
    /// The delegation contract every spawn description leads with, whichever
    /// side of the capability-index flag the session is on.
    nonisolated private static let spawnIntro = """
        Run independent workstreams concurrently, each in a fresh context that \
        cannot see this conversation. Use it when a request splits into genuinely \
        separate slices that can be researched, drafted or computed at the same \
        time; never to do one thing several times over. Every task must be \
        self-contained — state what you already know, what the task must establish, \
        and what it must return. The final message of each task is its deliverable \
        and comes back to you verbatim, so ask for findings, not pleasantries.
        """

    /// How to split work across agents, the same under both descriptions: the
    /// roster is *who* exists, and this is *how to use them*.
    nonisolated private static let spawnGuidance = """


        Several tasks may name the same agent, and often should. An agent is a way \
        of working, not a thing that can only run once: two tasks both naming a \
        server agent, each asking it about a different half of the question, run at \
        the same time and come back separately. Split a wide question that way — \
        three creatures to one task and three to another, rather than one task \
        listing all six — and it is answered as quickly as a narrow one. What to \
        avoid is two tasks given the same job, not two tasks given the same agent.

        So: split the work first, then write each prompt. Say what that task gets, \
        what it must establish, and what it must return, and give no two of them \
        the same job.
        """

    /// The roster is generated rather than written down here: a list of agents
    /// hardcoded into a prompt is wrong the moment a skill is installed, and wrong
    /// in the direction that costs a round trip — the model would keep naming an
    /// agent that is no longer there.
    nonisolated static func spawnDescription(roster: String) -> String {
        guard !roster.isEmpty else { return spawnIntro }
        return spawnIntro + """


            Hand a task to one of these by naming it in 'agent':
            \(roster)

            Name one whenever it fits. An agent arrives with its own instructions and \
            its own tools — a scout cannot change anything, a server agent can only \
            reach its own server — so naming it is how a task gets the right shape \
            without the task description having to ask for it. Leave 'agent' out and \
            the task runs unnamed: every tool, the session model, and nothing but the \
            prompt you wrote.
            """ + spawnGuidance
    }

    /// The contextCompilerV2 description: the contract and the discovery
    /// affordance, with the roster held back. Prompt cost stops growing with the
    /// roster; the model names what a task needs and Bud resolves it locally.
    nonisolated static func spawnDescriptionCompact() -> String {
        spawnIntro + """


            Agents are available (scouts, skill agents, connected MCP servers), each \
            with its own instructions and its own tools — a scout cannot change \
            anything, a server agent can only reach its own server. Hand a task to \
            one by putting what it needs in 'capability' — e.g. 'competitive pokemon \
            analysis' — and Bud resolves the matching agent locally. Naming the \
            agent directly in 'agent' always works too. If a name is wrong or a \
            capability is unclear, the call answers with the names you can choose \
            from. Leave both out and the task runs unnamed: every tool, the session \
            model, and nothing but the prompt you wrote.
            """ + spawnGuidance
    }

    nonisolated static func systemPrompt(_ spec: SubagentSpec, agent: AgentDefinition?) -> String {
        var text = ""
        // The agent's own instructions come first: they are the identity, and the
        // contract below is what every workstream has in common on top of it.
        if let agent {
            text += agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n—\n\n"
        }
        text += """
            You are a subagent\(agent.map { " running as the \"\($0.name)\" agent" } ?? ""): one of \
            several workstreams running at the same time. The others cannot see you and you \
            cannot see them, so nothing you leave out of your final message exists as far as the \
            rest of the system is concerned.

            Your assignment: \(spec.title)

            Your final message is not read by a human. It is returned verbatim to the agent that \
            dispatched you and folded into the report the user sees. It is your whole deliverable, \
            so give it exactly four short sections and nothing else — no greeting, no restating \
            the assignment, no narrative, no asking whether to continue.

            Answer — the outcome.
            Evidence — what backs it, with provenance (paths, line numbers, values, URLs).
            Unresolved — what is still open and why.
            Handles — any store_ handles you were given for results too large to inline.
            """
        if spec.depth < maxDepth {
            text += """


                You may hand part of this to another agent with \(spawnToolName) if it genuinely \
                splits. You will not see its work, so each task you write has to stand on its \
                own, and its final message is all you get back.
                """
        }
        return text
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
            var block = "• \(run.title)"
            if let agent = run.agent { block += " (as \(agent))" }
            block += " — \(run.state.label), \(String(format: "%.1fs", elapsed)), \(calls)"
            if let error = run.error, !error.isEmpty {
                block += "\nerror: \(error)"
            }
            let body = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
            block += "\n" + (body.isEmpty ? "(no output)" : boundedHandoff(body, budget: subagentOutputBudget))
            return block
        }
        .joined(separator: "\n\n")
    }

    /// The parent's view of a run's final message: the whole of it up to the budget,
    /// cut on a line boundary past that so the last finding shown is never a half
    /// sentence, with a suffix pointing at the full record the Agents panel keeps.
    ///
    /// Pure and static so the boundary behaviour can be tested without a live run.
    nonisolated static func boundedHandoff(_ text: String, budget: Int) -> String {
        guard text.count > budget else { return text }
        let cut = text.index(text.startIndex, offsetBy: budget)
        var kept = String(text[..<cut])
        if let lastBreak = kept.lastIndex(of: "\n") { kept = String(kept[..<lastBreak]) }
        let dropped = text.count - kept.count
        return kept + "\n\n…[\(dropped) characters not shown — the full run is in the Agents panel]"
    }
}

/// A task list that could not be read, with the sentence to send back to the model.
struct SpecProblem: Error, Sendable {
    var message: String
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
