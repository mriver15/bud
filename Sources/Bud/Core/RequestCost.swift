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
        /// The two halves of a tool's cost, kept apart because the fix differs.
        ///
        /// A prose description can be moved somewhere it is loaded only when
        /// needed; a JSON schema cannot, because it is what the provider validates
        /// arguments against. A total that does not say which half is which reads
        /// as though both were removable.
        public var descriptionChars: Int = 0
        public var schemaChars: Int = 0
        /// Of `schemaChars`, how much is strings rather than keys and punctuation.
        public var schemaProseChars: Int = 0
        public var id: String { name }

        public init(
            name: String,
            chars: Int,
            count: Int = 1,
            descriptionChars: Int = 0,
            schemaChars: Int = 0,
            schemaProseChars: Int = 0
        ) {
            self.name = name
            self.chars = chars
            self.count = count
            self.descriptionChars = descriptionChars
            self.schemaChars = schemaChars
            self.schemaProseChars = schemaProseChars
        }
    }

    /// One row of the per-provider tool breakdown.
    ///
    /// The tool block is grouped by where each tool comes from, so a heavy
    /// server and a heavy built-in read as separate lines instead of one
    /// "tools" total that hides which of them is the problem. MCP tools become
    /// one row per server; built-ins are one row per provider.
    public struct ToolGroup: Sendable, Identifiable {
        public var name: String
        public var chars: Int
        /// Description text plus prose inside schemas — the part that could move
        /// to something loaded only when needed.
        public var proseChars: Int
        /// Number of tools the group contributes.
        public var count: Int
        public var id: String { name }

        /// The same four-characters-per-token estimate as
        /// `RequestCost.estimatedTokens`, so a group and the whole rank on one
        /// scale.
        public var estimatedTokens: Int { chars / 4 }

        public init(name: String, chars: Int, proseChars: Int, count: Int) {
            self.name = name
            self.chars = chars
            self.proseChars = proseChars
            self.count = count
        }
    }

    public var modelChars = 0
    public var systemChars = 0
    public var liveContextChars = 0
    public var notesChars = 0
    /// The skill catalogue, which rides in the system prompt.
    ///
    /// Counted separately because it was not counted at all: a request with twenty
    /// skills installed carries roughly ten thousand characters that this report
    /// said nothing about, and the figures it did give read as the whole cost.
    public var skillChars = 0
    public var toolChars = 0
    public var toolCount = 0
    public var heaviestTools: [Entry] = []
    /// How much of the tool block is string content rather than JSON structure.
    ///
    /// The distinction is the whole question for a tool like `render_ui`: prose
    /// inside a schema is documentation and can be moved somewhere it is loaded
    /// only when needed, while keys, types and enum lists cannot — they are what
    /// the provider validates arguments against, and a model that has not seen
    /// them writes arguments that fail.
    public var toolProseChars: Int = 0
    /// MCP tools summed by the server half of `<server>__<tool>`.
    public var servers: [Entry] = []
    /// Tools summed under the provider that publishes them: one row per
    /// built-in provider, one row per connected MCP server. The Settings pane
    /// reads these same numbers.
    public var toolGroups: [ToolGroup] = []

    public var totalChars: Int {
        modelChars + systemChars + liveContextChars + notesChars + skillChars + toolChars
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
        liveContext: String,
        skills: String = ""
    ) -> RequestCost {
        var cost = RequestCost()
        cost.modelChars = config.model.count
        cost.systemChars = config.systemPrompt.count
        cost.liveContextChars = liveContext.count
        cost.notesChars = notes.isEmpty ? 0 : notes.count
        cost.skillChars = skills.isEmpty ? 0 : skills.count
        cost.toolCount = tools.count

        var measured: [RequestCost.Entry] = []
        measured.reserveCapacity(tools.count)
        var groupSums: [String: (chars: Int, prose: Int, count: Int)] = [:]
        for tool in tools {
            let chars = tool.openAIToolDefinition.encodedString().count
            let prose = tool.description.count + tool.schema.stringContentLength
            measured.append(RequestCost.Entry(
                name: tool.name,
                chars: chars,
                descriptionChars: tool.description.count,
                schemaChars: tool.schema.encodedString().count,
                schemaProseChars: tool.schema.stringContentLength
            ))
            cost.toolChars += chars
            cost.toolProseChars += prose

            // The group is read off the descriptor, not remembered here: a
            // future provider shows up under its own ID with no change to this
            // loop.
            let group = Self.groupName(for: tool)
            let running = groupSums[group] ?? (0, 0, 0)
            groupSums[group] = (running.chars + chars, running.prose + prose, running.count + 1)
        }
        cost.heaviestTools = Array(measured.sorted { $0.chars > $1.chars }.prefix(10))
        cost.toolGroups = groupSums
            .map { RequestCost.ToolGroup(name: $0.key, chars: $0.value.chars, proseChars: $0.value.prose, count: $0.value.count) }
            .sorted { $0.chars > $1.chars }

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

    /// The group a descriptor belongs to, derived from the descriptor rather
    /// than from a list of tool names. MCP tools carry their server in
    /// `providerName`, so they become one row per server; every other provider
    /// is one row under its `providerID`, which a provider owns and therefore
    /// cannot collide with a tool name a future one happens to publish.
    private static func groupName(for tool: ToolDescriptor) -> String {
        switch tool.providerID {
        case "mcp": return tool.providerName
        case "genui": return "generated-ui"
        default: return tool.providerID
        }
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
        // A roster, not an empty one. The delegation description is *generated*
        // from what can be delegated to — the agents the installed skills and
        // connected servers contribute, and the guidance that names them — so
        // measuring with an empty registry reports a description nobody is ever
        // sent, and leaves out the part that grows with every install.
        let agents = AgentRegistry()
        agents.source = { (SkillStore.installed(), mcp.servers) }
        let subagents = SubagentSupervisor(env: env, agents: agents)

        let providers: [any ToolProvider] = [
            NativeToolsProvider(),
            MemoryToolsProvider(),
            mcp,
            subagents,
            GenUIToolProvider(),
            BrowserToolProvider(engine: BrowserEngine()),
            SkillToolProvider(),
        ]
        for provider in providers {
            await env.registry.register(provider)
        }
        await mcp.connectAllAutoStart()
        await mcp.refreshTools()
        // After the servers are up, because the roster is built from them.
        agents.refresh()

        // Filtered exactly as a request is, and for the same reason this file
        // exists: a measurement of the registry rather than of what the model is
        // sent would report 21 tools the main agent never sees, and quietly
        // understate what handing them to an agent is worth.
        let tools = await env.registry.descriptors().filter { !$0.agentOnly }
        let cost = RequestMeasurer.measure(
            config: config,
            tools: tools,
            notes: BudStore.lessonContext(),
            liveContext: liveContextSample(config: config),
            skills: SkillContext.catalogue(query: "").text
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

        if arguments.contains("--compact") {
            // The same tools, each through the compactor — the block a request
            // would carry with schema compaction switched on.
            let compactTools = tools.map { DescriptorCompactor.compact($0) }
            let compactCost = RequestMeasurer.measure(
                config: config,
                tools: compactTools,
                notes: BudStore.lessonContext(),
                liveContext: liveContextSample(config: config),
                skills: SkillContext.catalogue(query: "").text
            )
            print(report(cost, mcp: mcp))
            print(compactToolBlock(compactCost, full: cost))
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

    private static func report(_ cost: RequestCost, mcp: MCPManager) -> String {
        func line(_ label: String, _ chars: Int, _ note: String = "") -> String {
            let count = BudFormat.count(chars)
            let padded = count.padding(toLength: max(count.count, 9), withPad: " ", startingAt: 0)
            return "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(padded)   \(note)\n"
        }

        var out = "\nRequest cost — what every message carries before you type anything\n\n"
        out += line("system prompt", cost.systemChars)
        out += line("live context", cost.liveContextChars, "time, model, reasoning effort")
        if cost.skillChars > 0 {
            out += line("skill catalogue", cost.skillChars, "in the instructions, one line per skill")
        }
        out += line(
            "notes",
            cost.notesChars,
            cost.notesChars == 0 ? "nothing remembered yet" : "re-read on every request"
        )
        out += line("tools", cost.toolChars, "\(cost.toolCount) tools")

        out += "  " + String(repeating: "─", count: 46) + "\n"
        out += line("prefix", cost.totalChars, "≈ \(BudFormat.count(cost.estimatedTokens)) tokens per request")

        // The same tool block, split by where each tool comes from. A heavy
        // server and a heavy built-in are optimised differently, so they do not
        // belong in one number.
        if !cost.toolGroups.isEmpty {
            out += "\nTool groups\n"
            for group in cost.toolGroups {
                out += "  \(group.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
                out += "\(BudFormat.count(group.chars).padding(toLength: 9, withPad: " ", startingAt: 0))"
                out += "  prose \(BudFormat.count(group.proseChars))"
                out += " · ≈ \(BudFormat.count(group.estimatedTokens)) tokens"
                out += " · \(group.count) tool\(group.count == 1 ? "" : "s")\n"
            }
        }

        // Delegated servers are absent from the breakdown above — their tools are
        // deliberately not in the main list — so they are named here instead, with
        // the agent that holds them. A delegated server whose agent did not
        // register is one nothing can reach, and this is the only place that says
        // so: the app's symptom would be a model reporting that a tool it expects
        // has gone missing.
        let delegated = mcp.servers.filter(\.delegated)
        if !delegated.isEmpty {
            let roster = AgentRegistry()
            roster.rebuild(skills: [], servers: mcp.servers)
            out += "\nHanded to an agent\n"
            for server in delegated {
                let holder = roster.named(ToolNaming.sanitize(server.name.lowercased()))
                out += "  \(server.name.padding(toLength: 24, withPad: " ", startingAt: 0))"
                out += holder == nil
                    ? "NO AGENT HOLDS THIS — its tools are unreachable\n"
                    : "→ the \(holder!.name) agent, on \(holder!.tools?.first ?? "nothing")\n"
            }
        }

        if !cost.servers.isEmpty {
            out += "\nMCP servers\n"
            for server in cost.servers {
                out += "  \(server.name.padding(toLength: 24, withPad: " ", startingAt: 0))"
                out += "\(BudFormat.count(server.chars).padding(toLength: 9, withPad: " ", startingAt: 0))"
                out += "  \(server.count) tool\(server.count == 1 ? "" : "s")"
                // What the switch is worth, per server, rather than in general: the
                // decision is per server and the numbers are not alike.
                let config = mcp.servers.first { $0.name == server.name }
                if config?.delegated == true {
                    out += "  · handed to its agent"
                } else if config != nil {
                    out += "  · could hand to its agent and save \(BudFormat.count(server.chars))"
                }
                out += "\n"
            }
        }

        out += "\n  of \(BudFormat.count(cost.toolChars)) characters of tools, "
        out += "\(BudFormat.count(cost.toolProseChars)) are prose — the rest is structure\n"

        out += "\nHeaviest tools\n"
        for tool in cost.heaviestTools {
            out += "  \(tool.name.padding(toLength: 40, withPad: " ", startingAt: 0))"
            out += "\(BudFormat.count(tool.chars).padding(toLength: 9, withPad: " ", startingAt: 0))"
            out += "  prose \(BudFormat.count(tool.descriptionChars))"
            out += " · schema \(BudFormat.count(tool.schemaChars))"
            // What the schema would cost if its documentation moved out of it.
            let skeleton = tool.schemaChars - tool.schemaProseChars
            out += " (skeleton \(BudFormat.count(skeleton)))\n"
        }

        let ready = mcp.servers.filter { mcp.statuses[$0.id]?.state == .ready }.count
        out += "\n  \(ready)/\(mcp.servers.count) configured servers connected; "
        out += "\(cost.toolCount - cost.servers.reduce(0) { $0 + $1.count }) built-in tools.\n"
        return out
    }

    /// The compacted tool block, printed only with `--compact`. It repeats the
    /// tool sections of `report` — tools, groups, heaviest — computed from
    /// schemas that have been through the compactor, then one line naming what
    /// the switch is worth.
    private static func compactToolBlock(_ compact: RequestCost, full: RequestCost) -> String {
        func line(_ label: String, _ chars: Int, _ note: String = "") -> String {
            let count = BudFormat.count(chars)
            let padded = count.padding(toLength: max(count.count, 9), withPad: " ", startingAt: 0)
            return "  \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(padded)   \(note)\n"
        }

        var out = "\nCompact tool block — every non-agent schema through the compactor\n\n"
        out += line("tools", compact.toolChars, "\(compact.toolCount) tools")

        if !compact.toolGroups.isEmpty {
            out += "\nCompact tool groups\n"
            for group in compact.toolGroups {
                out += "  \(group.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
                out += "\(BudFormat.count(group.chars).padding(toLength: 9, withPad: " ", startingAt: 0))"
                out += "  prose \(BudFormat.count(group.proseChars))"
                out += " · ≈ \(BudFormat.count(group.estimatedTokens)) tokens"
                out += " · \(group.count) tool\(group.count == 1 ? "" : "s")\n"
            }
        }

        if !compact.heaviestTools.isEmpty {
            out += "\nHeaviest tools (compact)\n"
            for tool in compact.heaviestTools {
                out += "  \(tool.name.padding(toLength: 40, withPad: " ", startingAt: 0))"
                out += "\(BudFormat.count(tool.chars).padding(toLength: 9, withPad: " ", startingAt: 0))"
                out += "  prose \(BudFormat.count(tool.descriptionChars))"
                out += " · schema \(BudFormat.count(tool.schemaChars))\n"
            }
        }

        let saved = full.toolChars - compact.toolChars
        let percent = full.toolChars == 0 ? 0.0 : Double(saved) / Double(full.toolChars) * 100.0
        out += "\n  full \(BudFormat.count(full.toolChars))"
        out += " → compact \(BudFormat.count(compact.toolChars))"
        out += " — \(String(format: "%.1f", percent))% saved\n"

        return out
    }
}
