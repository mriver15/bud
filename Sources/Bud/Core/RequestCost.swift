import Foundation

// MARK: - Cost model

/// What one request to the model carries before a word of conversation.
///
/// The prefix is the part worth measuring. It is paid on every request, in every
/// conversation, for as long as the app runs — and unlike history, which grows
/// because someone is talking, it grows because a server was installed once and
/// then never looked at again.
///
/// Measured, not estimated: the tool figures come from serialising the same
/// `openAIToolDefinition` the request uses, so this cannot drift from what is
/// actually sent.
public struct RequestCost: Sendable {
    public struct Entry: Sendable, Identifiable {
        public var name: String
        public var chars: Int
        public var count: Int = 1
        public var id: String { name }

        public init(name: String, chars: Int, count: Int = 1) {
            self.name = name
            self.chars = chars
            self.count = count
        }
    }

    public var modelChars = 0
    public var systemChars = 0
    public var liveContextChars = 0
    public var notesChars = 0
    public var toolChars = 0
    public var toolCount = 0
    public var heaviestTools: [Entry] = []
    /// MCP tools summed by the server half of `<server>__<tool>`.
    public var servers: [Entry] = []

    public var totalChars: Int {
        modelChars + systemChars + liveContextChars + notesChars + toolChars
    }

    /// Deliberately crude, and named so it is not mistaken for billing. No
    /// tokenizer ships with the app; a precise-looking number derived from four
    /// characters per token would be trusted further than it deserves. This is
    /// here to rank what is heavy against what is not.
    public var estimatedTokens: Int { totalChars / 4 }
}

// MARK: - Measurement

public enum RequestMeasurer {
    /// - Parameters:
    ///   - notes: passed in rather than read here, because the caller is the one
    ///     that knows whether it is on the main actor.
    ///   - liveContext: the trailing lines the runtime appends each request.
    public static func measure(
        config: BudConfig,
        tools: [ToolDescriptor],
        notes: String,
        liveContext: String
    ) -> RequestCost {
        var cost = RequestCost()
        cost.modelChars = config.model.count
        cost.systemChars = config.systemPrompt.count
        cost.liveContextChars = liveContext.count
        cost.notesChars = notes.isEmpty ? 0 : notes.count
        cost.toolCount = tools.count

        var measured: [RequestCost.Entry] = []
        measured.reserveCapacity(tools.count)
        for tool in tools {
            let chars = tool.openAIToolDefinition.encodedString().count
            measured.append(RequestCost.Entry(name: tool.name, chars: chars))
            cost.toolChars += chars
        }
        cost.heaviestTools = Array(measured.sorted { $0.chars > $1.chars }.prefix(10))

        // Everything before the `__` boundary that `ToolNaming.namespaced` put
        // there. Native tools have no boundary and are not MCP traffic.
        var perServer: [String: (chars: Int, count: Int)] = [:]
        for entry in measured {
            guard let boundary = entry.name.range(of: "__") else { continue }
            let server = String(entry.name[..<boundary.lowerBound])
            let running = perServer[server] ?? (0, 0)
            perServer[server] = (running.chars + entry.chars, running.count + 1)
        }
        cost.servers = perServer
            .map { RequestCost.Entry(name: $0.key, chars: $0.value.chars, count: $0.value.count) }
            .sorted { $0.chars > $1.chars }

        return cost
    }
}

// MARK: - CLI

/// `--measure`: boots the real tool surface, connects the real MCP servers, and
/// reports what a request costs. The first step of any optimisation is refusing
/// to guess which part is heavy.
@MainActor
public enum RequestMeasureCLI {
    public static func run(arguments: [String] = []) async -> Bool {
        BudConfigLoader.ensureDirectory()
        let config = BudConfigLoader.load()
        let env = AppEnvironment(config: config)
        let mcp = MCPManager()
        let subagents = SubagentSupervisor(env: env)

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
        await mcp.connectAllAutoStart()
        await mcp.refreshTools()

        let tools = await env.registry.descriptors()
        let cost = RequestMeasurer.measure(
            config: config,
            tools: tools,
            notes: BudStore.lessonContext(),
            liveContext: liveContextSample(config: config)
        )

        if let index = arguments.firstIndex(of: "--dump-tool"),
           arguments.count > index + 1 {
            let wanted = arguments[index + 1]
            guard let tool = tools.first(where: { $0.name == wanted }) else {
                print("no tool named '\(wanted)'")
                await mcp.shutdown()
                return false
            }
            // The exact text the request carries, so it can be diffed against
            // whatever the server published.
            print(tool.openAIToolDefinition.encodedString())
            await mcp.shutdown()
            return true
        }

        print(report(cost, mcp: mcp))
        await mcp.shutdown()
        return true
    }

    /// The shape of what `AgentRuntime.systemMessage` appends, without a clock
    /// reading — a measurement that changes every time it runs is not one you
    /// can compare against the next.
    private static func liveContextSample(config: BudConfig) -> String {
        var sample = "\n\nCurrent time: Wednesday, 1 January 2025, 00:00."
        sample += "\nDefault model for this session: \(config.model)."
        if let effort = config.reasoningEffort { sample += " Reasoning effort: \(effort)." }
        return sample
    }

    /// Thousands-separated. These numbers only mean anything next to each
    /// other, and a run of unbroken digits is not a number you can compare.
    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }

    private static func report(_ cost: RequestCost, mcp: MCPManager) -> String {
        func line(_ label: String, _ chars: Int, _ note: String = "") -> String {
            let count = grouped(chars)
            let padded = count.padding(toLength: max(count.count, 9), withPad: " ", startingAt: 0)
            return "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(padded)   \(note)\n"
        }

        var out = "\nRequest cost — what every message carries before you type anything\n\n"
        out += line("system prompt", cost.systemChars)
        out += line("live context", cost.liveContextChars, "time, model, reasoning effort")
        out += line(
            "notes",
            cost.notesChars,
            cost.notesChars == 0 ? "nothing remembered yet" : "re-read on every request"
        )
        out += line("tools", cost.toolChars, "\(cost.toolCount) tools")

        out += "  " + String(repeating: "─", count: 46) + "\n"
        out += line("prefix", cost.totalChars, "≈ \(grouped(cost.estimatedTokens)) tokens per request")

        if !cost.servers.isEmpty {
            out += "\nMCP servers\n"
            for server in cost.servers {
                out += "  \(server.name.padding(toLength: 24, withPad: " ", startingAt: 0))"
                out += "\(grouped(server.chars).padding(toLength: 9, withPad: " ", startingAt: 0))"
                out += "  \(server.count) tool\(server.count == 1 ? "" : "s")\n"
            }
        }

        out += "\nHeaviest tools\n"
        for tool in cost.heaviestTools {
            out += "  \(tool.name.padding(toLength: 40, withPad: " ", startingAt: 0))"
            out += "\(grouped(tool.chars))\n"
        }

        let ready = mcp.servers.filter { mcp.statuses[$0.id]?.state == .ready }.count
        out += "\n  \(ready)/\(mcp.servers.count) configured servers connected; "
        out += "\(cost.toolCount - cost.servers.reduce(0) { $0 + $1.count }) built-in tools.\n"
        return out
    }
}
