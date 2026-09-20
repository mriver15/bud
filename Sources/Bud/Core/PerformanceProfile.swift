import Foundation

/// `--profile`: what a request costs in time, and where.
///
/// The counterpart to `--measure`, which counts characters. Both exist for the
/// same reason: the expensive part of an assistant is the part that runs on
/// every single request, and none of it is visible from the outside. A slow
/// path that looks cheap is the one that ships.
@MainActor
public enum PerformanceProfileCLI {
    private static let iterations = 200

    public static func run(arguments: [String]) async -> Bool {
        BudConfigLoader.ensureDirectory()
        let config = BudConfigLoader.load()
        let env = AppEnvironment(config: config)
        let mcp = MCPManager()

        // A registry with the built-ins in it, so the measurement includes the
        // delegation description at the size it actually reaches the model.
        let warmupAgents = AgentRegistry()
        warmupAgents.rebuild(skills: [], servers: [])

        let providers: [any ToolProvider] = [
            NativeToolsProvider(),
            MemoryToolsProvider(),
            mcp,
            SubagentSupervisor(env: env, agents: warmupAgents),
            GenUIToolProvider(),
            BrowserToolProvider(engine: BrowserEngine()),
            SkillToolProvider(),
        ]
        for provider in providers {
            await env.registry.register(provider)
        }
        await mcp.connectAllAutoStart()
        await mcp.refreshTools()

        func measure(_ work: () -> Void) -> Double {
            _ = work()  // warm the caches a first call would fill
            let start = Date()
            for _ in 0..<iterations { work() }
            return Date().timeIntervalSince(start) / Double(iterations) * 1000
        }

        func measureAsync(_ work: () async -> Void) async -> Double {
            await work()
            let start = Date()
            for _ in 0..<iterations { await work() }
            return Date().timeIntervalSince(start) / Double(iterations) * 1000
        }

        let installed = SkillStore.installed()
        let tools = await env.registry.descriptors().filter { !$0.agentOnly }

        // The prefix-stability report needs the registry but not a credential:
        // it compares what two queries would send, offline.
        if arguments.contains("--prefix-stability") {
            print(prefixStabilityReport(config: config, tools: tools))
            await mcp.shutdown()
            return true
        }

        // Phase 9: planner regret from the evidence store, plus the measurable
        // gain the eval gates care about — what the adaptive resolver pays in
        // schema characters versus the current planner on representative
        // queries. Both offline.
        if arguments.contains("--regret") {
            print(await regretAndComparisonReport(tools: tools))
            await mcp.shutdown()
            return true
        }

        // Phase 1 — request build. Everything the first message carries before a
        // byte leaves the machine; the three lines under the phase table are this
        // same number broken out.
        let skillMs = measure { _ = SkillContext.catalogue(query: "").text }
        let noteMs = measure { _ = BudStore.lessonContext() }
        let registryMs = await measureAsync { _ = await env.registry.descriptors() }
        let buildMs = skillMs + noteMs + registryMs

        struct Phase {
            let name: String
            let ms: Double
        }
        var phases: [Phase] = [Phase(name: "request build", ms: buildMs)]
        var stopped: String? = nil

        let system = systemText(config)
        let question = ChatMessage(role: .user, content: "What time is it, in one word?")

        // Phase 2 — provider call, timed to the first token. The one phase that
        // needs a credential: without one the run stops here and says why, rather
        // than failing.
        if let problem = config.setupProblem {
            stopped = problem
        } else {
            let request = ChatRequest(
                model: config.model,
                messages: [system, question],
                tools: tools,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                reasoningEffort: config.reasoningEffort
            )
            do {
                switch try await firstToken(env: env, request: request) {
                case .reached(let ms):
                    phases.append(Phase(name: "provider call (first token)", ms: ms))
                case .endedEmpty:
                    stopped = "the provider returned no token to time."
                }
            } catch {
                stopped = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        // Phase 3 — a synthetic tool round. The model is not asked to produce a
        // tool call; one is fabricated and run through the real registry, so the
        // round costs what a round costs: invoke, frame the result, and rebuild
        // the request the next message will carry.
        if stopped == nil {
            let roundMs = await measureAsync {
                let call = ToolCall(id: "call_synthetic", name: "recall", arguments: "{}")
                let result = await env.registry.invoke(
                    name: call.name, arguments: call.parsedArguments, callID: call.id
                )
                _ = ChatMessage.toolResult(call, result).openAIWireRepresentation
                _ = await env.registry.descriptors()
                _ = SkillContext.catalogue(query: "").text
            }
            phases.append(Phase(name: "synthetic tool round", ms: roundMs))
        }

        // Phase 4 — synthesis: the second provider call, carrying the tool
        // result, timed to the first token of the answer.
        if stopped == nil {
            let call = ToolCall(id: "call_synthetic", name: "recall", arguments: "{}")
            let result = await env.registry.invoke(
                name: call.name, arguments: call.parsedArguments, callID: call.id
            )
            let assistant = ChatMessage(role: .assistant, toolCalls: [call])
            let toolMessage = ChatMessage.toolResult(call, result)
            let request = ChatRequest(
                model: config.model,
                messages: [system, question, assistant, toolMessage],
                tools: tools,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                reasoningEffort: config.reasoningEffort
            )
            do {
                switch try await firstToken(env: env, request: request) {
                case .reached(let ms):
                    phases.append(Phase(name: "synthesis", ms: ms))
                case .endedEmpty:
                    stopped = "synthesis returned no token to time."
                }
            } catch {
                stopped = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        let total = phases.reduce(0) { $0 + $1.ms }
        var out = "\nSynthetic turn — where the time goes\n\n"
        for phase in phases {
            let share = total > 0 ? phase.ms / total * 100 : 0
            out += "  \(phase.name.padding(toLength: 28, withPad: " ", startingAt: 0))"
            out += String(format: "%9.2f ms", phase.ms)
            out += String(format: "%6.1f%%", share) + "\n"
        }
        out += "  " + String(repeating: "─", count: 44) + "\n"
        out += "  \("turn".padding(toLength: 28, withPad: " ", startingAt: 0))"
        out += String(format: "%9.2f ms", total) + "\n"
        if let stopped {
            out += "\n  stopped at \(nextPhase(after: phases.count)): \(stopped)\n"
        }

        // The detail behind the request-build phase: the three things a request
        // assembles before any of it reaches the model.
        out += "\nPer request — what runs before every model call\n\n"
        let skillLabel = "skill list for the prompt (\(installed.count) skill\(installed.count == 1 ? "" : "s"))"
        out += "  \(skillLabel.padding(toLength: 34, withPad: " ", startingAt: 0))"
        out += String(format: "%7.2f ms", skillMs) + "\n"
        out += "  \("remembered notes".padding(toLength: 34, withPad: " ", startingAt: 0))"
        out += String(format: "%7.2f ms", noteMs) + "\n"
        out += "  \("tool descriptors (\(tools.count) tools)".padding(toLength: 34, withPad: " ", startingAt: 0))"
        out += String(format: "%7.2f ms", registryMs) + "\n"
        out += "\n  " + String(repeating: "─", count: 52) + "\n"
        out += "  \("per request".padding(toLength: 34, withPad: " ", startingAt: 0))"
        out += String(format: "%7.2f ms", buildMs) + "\n"
        out += "  system prompt is \(BudFormat.count(system.content.count)) characters\n"

        // A turn is several requests; the round limit is what makes this a
        // multiplier rather than a footnote.
        let rounds = max(1, config.maxToolRounds)
        out += "\n  at the \(rounds)-round ceiling a single turn spends"
            + " \(String(format: "%.0f", buildMs * Double(rounds))) ms rebuilding the same prompt\n"

        await mcp.shutdown()
        print(out)
        return true
    }

    /// Phase 9 (EVAL-004): the regret report over stored evidence, followed by
    /// the resolver-vs-planner schema comparison — the artifact a tuning change
    /// points at when it claims a measurable gain.
    private static func regretAndComparisonReport(tools: [ToolDescriptor]) async -> String {
        var out = PlannerRegretReport.render()
        out += "\n\nAdaptive planning vs current planner — schema characters per query\n\n"

        let queries = [
            ("generic", "What time is it?"),
            ("browse", "Browse https://example.com and summarise what you find"),
            ("presentation", "Compare these three options in a table"),
            ("files", "Read src/main.swift and fix the bug it describes"),
        ]
        let engine = DeterministicDecisionEngine()
        let domains = Set(tools.map(\.providerName)).sorted() + ["none"]

        func schemaChars(_ descriptors: [ToolDescriptor]) -> Int {
            descriptors.reduce(0) {
                $0 + $1.name.count + $1.description.count + $1.schema.stringContentLength
            }
        }

        out += "  " + "query".padding(toLength: 14, withPad: " ", startingAt: 0)
        out += "planner".padding(toLength: 10, withPad: " ", startingAt: 0)
        out += "resolver".padding(toLength: 10, withPad: " ", startingAt: 0)
        out += "delta\n"
        for (label, query) in queries {
            let state = DecisionState(query: query)
            let context = ToolPlanningContext(query: query)
            let planner = ToolPlanner.plan(context: context, descriptors: tools)
            let batch = (try? await engine.evaluate(
                state: state, questions: DecisionQuestions.initial(domains: domains)
            )) ?? DecisionBatch(engineID: engine.id, answers: [])
            let stage = CapabilityResolver.stageA(
                state: state, batch: batch, descriptors: tools, stickyTools: []
            )
            let plannerChars = schemaChars(planner.descriptors)
            let resolverChars = stage.schemaCharacters
            let delta = plannerChars - resolverChars
            out += "  " + label.padding(toLength: 14, withPad: " ", startingAt: 0)
            out += String(plannerChars).padding(toLength: 10, withPad: " ", startingAt: 0)
            out += String(resolverChars).padding(toLength: 10, withPad: " ", startingAt: 0)
            out += (delta >= 0 ? "-" : "+") + "\(abs(delta))\n"
        }
        return out
    }

    /// The system prompt a request carries, minus the clock reading (which a
    /// measurement cannot pin down, and which another file owns). Notes and the
    /// skill catalogue are the parts that take real time to build.
    private static func systemText(_ config: BudConfig) -> ChatMessage {
        var text = config.systemPrompt
        let notes = BudStore.lessonContext()
        if !notes.isEmpty { text += "\n\n" + notes }
        let catalogue = SkillContext.catalogue(query: "").text
        if !catalogue.isEmpty { text += "\n\n" + catalogue }
        return ChatMessage(role: .system, content: text)
    }

    private enum FirstToken {
        case reached(Double)
        case endedEmpty
    }

    /// Milliseconds from send to the first token. A provider that closes the
    /// stream without one is `endedEmpty`, not a hang.
    private static func firstToken(env: AppEnvironment, request: ChatRequest) async throws -> FirstToken {
        let start = Date()
        for try await event in env.makeBackend().stream(request) {
            switch event {
            case .reasoningDelta, .contentDelta, .toolCallDelta:
                return .reached(Date().timeIntervalSince(start) * 1000)
            case .finish:
                return .endedEmpty
            case .usage:
                continue
            }
        }
        return .endedEmpty
    }

    /// The phase that would have run next, for the "stopped at" line.
    private static func nextPhase(after count: Int) -> String {
        switch count {
        case 1: return "provider call (first token)"
        case 2: return "synthetic tool round"
        default: return "synthesis"
        }
    }

    // MARK: - Prefix stability

    /// `--profile --prefix-stability`: how much of the request prefix survives
    /// between two representative queries. One generic, one with clear browse
    /// intent, so the tool-plan difference is visible rather than papered over.
    private static func prefixStabilityReport(config: BudConfig, tools: [ToolDescriptor]) -> String {
        let generic = "What time is it?"
        let browse = "Browse https://example.com and summarise what you find."
        let report = PrefixStability.measure(
            queryA: generic,
            queryB: browse,
            config: config,
            tools: tools
        )

        var out = "\nPrefix stability — two queries through the same composition\n\n"
        out += "  generic  \"\(generic)\"\n"
        out += "  browse   \"\(browse)\"\n\n"

        out += "  " + "block".padding(toLength: 16, withPad: " ", startingAt: 0)
        out += "stable".padding(toLength: 9, withPad: " ", startingAt: 0)
        out += "changed".padding(toLength: 9, withPad: " ", startingAt: 0)
        out += "share\n"

        for block in report.blocks {
            let share = block.aChars == 0 && block.bChars == 0
                ? "  —"
                : String(format: "%6.1f%%", block.share * 100)
            out += "  " + block.name.padding(toLength: 16, withPad: " ", startingAt: 0)
            out += BudFormat.count(block.stableChars).padding(toLength: 9, withPad: " ", startingAt: 0)
            out += BudFormat.count(block.changedChars).padding(toLength: 9, withPad: " ", startingAt: 0)
            out += share + "\n"
        }

        out += "\n  whole prefix (generic)  sha256 \(report.hashA)\n"
        out += "  whole prefix (browse)   sha256 \(report.hashB)\n"

        out += "\n  total prefix: \(BudFormat.count(report.totalChars)) characters"
        out += " — \(String(format: "%.1f%%", report.stableShare * 100)) stable\n"

        return out
    }
}
