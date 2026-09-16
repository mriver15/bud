import Foundation

/// End-to-end checks that need the real world: the live DeepSeek API, the live
/// MCP registry, and a real MCP server process.
///
/// Run with `--verify-live`. This is the proof that the stack works rather than
/// merely compiles — it drives the same `AppModel`, `MCPManager`, `ToolRegistry`
/// and `AgentRuntime` the app uses, so a break anywhere in the wiring shows up
/// here.
///
/// The MCP checks run against this binary's own `--mcp-echo-server` mode: a real
/// process, real JSON-RPC, real handshake, with no dependency on npx or the
/// network. One network check (the registry) and one model check (DeepSeek) are
/// unavoidable, since those are the two things that cannot be faked locally.
@MainActor
public enum BudLiveVerification {
    public static func run() async -> SelfTestReport {
        let c = Checker(suite: "live")
        var cleanup: (() async -> Void)?

        defer { _ = cleanup }

        // MARK: Configuration

        // `--provider <id>` retargets the whole live suite at another provider,
        // so a newly configured one can be exercised without editing config.
        var config = BudConfigLoader.load()
        if let index = CommandLine.arguments.firstIndex(of: "--provider"),
           CommandLine.arguments.count > index + 1 {
            let requested = CommandLine.arguments[index + 1]
            if let descriptor = ProviderRegistry.provider(id: requested) {
                config.provider = descriptor.id
            } else {
                c.check("config: unknown provider '\(requested)'", false)
                return c.report()
            }
        }

        let provider = config.activeProvider
        c.check("config: provider is \(provider.name)", !config.provider.isEmpty)
        c.check("config: model resolved (\(config.model))", !config.model.isEmpty)
        c.check("config: base URL set", !config.baseURL.isEmpty)

        let key = config.resolvedKey(for: provider)
        c.check("config: key resolved for \(provider.name)", !key.isEmpty || !provider.requiresKey)

        guard !key.isEmpty || !provider.requiresKey else {
            c.check("config: cannot continue without a key for \(provider.name)", false)
            return c.report()
        }
        guard !config.customProviderNeedsBaseURL else {
            c.check("config: the custom provider needs a base URL", false)
            return c.report()
        }

        let env = AppEnvironment(config: config)
        let backend = env.makeBackend()

        // MARK: Streaming

        var streamedText = ""
        var streamedReasoning = ""
        var sawFinish = false
        do {
            let request = ChatRequest(
                model: config.model,
                messages: [ChatMessage(role: .user, content: "Reply with exactly the word: pong")],
                maxTokens: 2048
            )
            for try await event in backend.stream(request) {
                switch event {
                case .contentDelta(let d): streamedText += d
                case .reasoningDelta(let d): streamedReasoning += d
                case .finish: sawFinish = true
                case .usage, .toolCallDelta: break
                }
            }
        } catch {
            c.check("\(provider.id): stream completed (\(error.localizedDescription))", false)
        }
        c.check("\(provider.id): produced text", streamedText.lowercased().contains("pong"))
        // Reasoning is a model capability, not a provider one — a
        // non-reasoning model legitimately emits none. Asserted only for the
        // families whose defaults always think, so the parser stays covered
        // without failing a model that was never going to emit thinking.
        if ["deepseek", "anthropic", "google"].contains(provider.id) {
            c.check("\(provider.id): produced reasoning", !streamedReasoning.isEmpty)
        }
        c.check("\(provider.id): reported finish", sawFinish)

        // MARK: DeepSeek tool call

        // Carried as a descriptor, not as a pre-formatted OpenAI object: each
        // dialect formats its own tool schema, and this fixture has to work
        // against whichever provider the suite is pointed at.
        let weatherTool = ToolDescriptor(
            name: "get_weather",
            description: "Get the weather for a city.",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("city")]),
            ]),
            providerID: "verify",
            providerName: "Verification"
        )

        var calls: [ToolCall] = []
        var finishReason: String?
        do {
            let request = ChatRequest(
                model: config.model,
                messages: [ChatMessage(role: .user, content: "What is the weather in Paris? Use the tool.")],
                tools: [weatherTool],
                maxTokens: 2048
            )
            var pending: [Int: (id: String, name: String, args: String)] = [:]
            for try await event in backend.stream(request) {
                switch event {
                case .toolCallDelta(let i, let id, let name, let frag):
                    var e = pending[i] ?? ("", "", "")
                    if let id, !id.isEmpty { e.id = id }
                    if let name, !name.isEmpty { e.name = name }
                    e.args += frag
                    pending[i] = e
                case .finish(let r): finishReason = r
                default: break
                }
            }
            calls = pending.keys.sorted().compactMap { key in
                guard let e = pending[key], !e.name.isEmpty else { return nil }
                return ToolCall(id: e.id, name: e.name, arguments: e.args)
            }
        } catch {
            c.check("\(provider.id): tool request completed (\(error.localizedDescription))", false)
        }
        c.check("\(provider.id): requested a tool", !calls.isEmpty)
        c.check("\(provider.id): finish reason is tool_calls", finishReason == "tool_calls")
        if let first = calls.first {
            c.equal("\(provider.id): correct tool chosen", first.name, "get_weather")
            c.check("\(provider.id): arguments are valid JSON", first.parsedArguments.objectValue != nil)
            c.check("\(provider.id): argument carries the city", first.parsedArguments["city"] != nil)
        }

        // MARK: Tool result round trip

        if let first = calls.first {
            var finalText = ""
            do {
                let request = ChatRequest(
                    model: config.model,
                    messages: [
                        ChatMessage(role: .user, content: "What is the weather in Paris? Use the tool."),
                        ChatMessage(role: .assistant, content: "", toolCalls: [first]),
                        ChatMessage(role: .tool, content: "18C and sunny", toolCallID: first.id, name: first.name),
                    ],
                    tools: [weatherTool],
                    maxTokens: 2048
                )
                for try await event in backend.stream(request) {
                    if case .contentDelta(let d) = event { finalText += d }
                }
            } catch {
                c.check("\(provider.id): tool round trip (\(error.localizedDescription))", false)
            }
            c.check("\(provider.id): answered using the tool result", finalText.contains("18"))
        }

        // MARK: MCP registry (live network)

        let registry = RegistryClient()
        do {
            let page = try await registry.page(cursor: nil, limit: 25)
            c.check("registry: returned servers", !page.servers.isEmpty)
            c.check("registry: issued a next cursor", page.nextCursor != nil)
            let withOptions = page.servers.filter { !$0.options.isEmpty }
            c.check("registry: servers mapped to install options", !withOptions.isEmpty)
            c.check(
                "registry: every option has a label",
                page.servers.allSatisfy { s in s.options.allSatisfy { !$0.label.isEmpty } }
            )
            let searches = try await registry.search("github", limit: 5)
            c.check("registry: search returned results", !searches.isEmpty)
        } catch {
            c.check("registry: fetch succeeded (\(error.localizedDescription))", false)
        }

        // MARK: MCP over stdio (real process)

        let mcp = MCPManager()
        let echoID = "bud-echo-verify"
        let mcpURL = BudConfigLoader.mcpURL
        let backup = try? Data(contentsOf: mcpURL)
        cleanup = {
            await mcp.removeServer(id: echoID)
            if let backup {
                try? backup.write(to: mcpURL, options: [.atomic])
            } else {
                try? FileManager.default.removeItem(at: mcpURL)
            }
        }

        guard let executable = SelfExecutable.path else {
            c.check("mcp: located own executable", false)
            return c.report()
        }

        // Registered *before* the server exists, which is the order the app uses
        // and the reason this went unnoticed: registered after a server connects,
        // the routing table is built with the tools already in it and everything
        // works. In the app the provider is registered at launch with no servers
        // at all, so a server added later had tools that were listed and could
        // not be called.
        let registryTools = ToolRegistry()
        await registryTools.register(mcp)

        await mcp.addServer(MCPServerConfig(
            id: echoID,
            name: "echo",
            transport: .stdio,
            command: executable,
            args: ["--mcp-echo-server"],
            enabled: true,
            autoStart: false
        ))
        await mcp.connect(id: echoID)

        let status = mcp.statuses[echoID]
        c.check(
            "mcp: server reached ready (\(status?.error ?? "no error reported"))",
            status?.state == .ready
        )
        c.equal("mcp: discovered both tools", status?.toolCount, 2)

        let tools = mcp.serverTools(id: echoID).map(\.name).sorted()
        c.equal(
            "mcp: tools are namespaced",
            tools,
            ["echo__add", "echo__echo"]
        )

        // MARK: Tool registry routing

        let names = await registryTools.descriptors().map(\.name)
        c.check("registry: exposes MCP tools", names.contains("echo__echo"))

        let echoResult = await registryTools.invoke(
            name: "echo__echo",
            arguments: .object(["message": .string("hello")]),
            callID: "verify-1"
        )
        c.check("registry: echo returned its payload", echoResult.text.contains("echo: hello"))
        c.check("registry: echo was not an error", !echoResult.isError)

        let addResult = await registryTools.invoke(
            name: "echo__add",
            arguments: .object(["a": .number(19), "b": .number(23)]),
            callID: "verify-2"
        )
        c.check("registry: arithmetic over the wire", addResult.text.contains("42"))

        let failResult = await registryTools.invoke(
            name: "echo__fail",
            arguments: .object([:]),
            callID: "verify-3"
        )
        c.check("registry: unknown tool is reported, not crashed", failResult.isError)

        let missing = await registryTools.invoke(
            name: "echo__nope",
            arguments: .object([:]),
            callID: "verify-4"
        )
        c.check("registry: missing tool yields an error", missing.isError)

        // MARK: Generative UI tool

        let genui = GenUIToolProvider()
        let spec: JSONValue = .object([
            "title": .string("Verification"),
            "components": .array([
                .object([
                    "type": .string("metrics"),
                    "items": .array([
                        .object(["label": .string("Tools"), "value": .string("2")]),
                    ]),
                ]),
                .object([
                    "type": .string("table"),
                    "columns": .array([.string("a"), .string("b")]),
                    "rows": .array([.array([.string("1"), .string("2")])]),
                ]),
                .object([
                    "type": .string("button"),
                    "label": .string("Refresh"),
                    "action": .object(["id": .string("refresh"), "prompt": .string("refresh it")]),
                ]),
            ]),
        ])
        let uiResult = await genui.invoke(tool: "render_ui", arguments: spec, callID: "verify-ui")
        c.check("genui: render_ui produced a surface", uiResult.ui != nil)
        c.check("genui: render_ui was not an error", !uiResult.isError)

        let badUI = await genui.invoke(tool: "render_ui", arguments: .object([:]), callID: "verify-ui-2")
        c.check("genui: malformed spec is rejected with a message", badUI.isError)

        // MARK: Agent runtime, end to end

        let runtimeEnv = AppEnvironment(config: config)
        await runtimeEnv.registry.register(mcp)
        await runtimeEnv.registry.register(GenUIToolProvider())
        let runtime = AgentRuntime(env: runtimeEnv)
        runtime.send("Use the echo tool to echo the phrase 'integration works', then tell me what it returned.")
        let answered = await waitUntil(timeout: 120) { !runtime.isStreaming }
        c.check("runtime: turn settled", answered)

        let usedTool = runtime.turns.contains { turn in
            turn.segments.contains { if case .tool = $0 { return true } else { return false } }
        }
        c.check("runtime: executed a tool", usedTool)
        let succeeded = runtime.turns.contains { turn in
            turn.segments.contains { segment in
                if case .tool(_, _, _, let state, let text, _) = segment {
                    return state == .succeeded && (text?.contains("integration works") ?? false)
                }
                return false
            }
        }
        c.check("runtime: tool result reached the transcript", succeeded)
        c.check("runtime: produced a final answer", !runtime.turns.compactMap { $0.plainText.isEmpty ? nil : $0 }.isEmpty)

        // MARK: Subagent

        let supervisor = SubagentSupervisor(env: runtimeEnv)
        let runs = await supervisor.spawn([
            SubagentSpec(
                title: "verify",
                prompt: "Reply with the single word: verified",
                allowTools: false
            ),
        ])
        c.check("subagent: returned a run", runs.count == 1)
        c.equal("subagent: run completed", runs.first?.state, .done)
        c.check(
            "subagent: produced output",
            (runs.first?.output.lowercased().contains("verified") ?? false)
        )

        // MARK: Glama (live, when a key is configured)

        let glamaKey = config.glamaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if glamaKey.isEmpty {
            c.check("glama: no key configured — live checks skipped", true)
        } else {
            c.check("glama: key resolved from config, environment or shell profile", true)
            let glama = GlamaClient(apiKey: glamaKey)

            do {
                let page = try await glama.connectors(query: nil, cursor: nil, limit: 25)
                c.check("glama: returned connectors", !page.items.isEmpty)
                c.check("glama: issued a page cursor", page.nextCursor != nil)

                // Attribution is a licence term: every row Bud presents has to be
                // able to link back to its own Glama listing.
                c.check(
                    "glama: every connector carries a listing URL",
                    page.items.allSatisfy { !($0.listingURL ?? "").isEmpty }
                )
                c.check(
                    "glama: listing URLs point at glama.ai",
                    page.items.allSatisfy { ($0.listingURL ?? "").contains("glama.ai") }
                )

                let installable = page.items.compactMap(\.installOption)
                c.check("glama: some connectors are installable", !installable.isEmpty)
                c.check(
                    "glama: install targets an http endpoint",
                    installable.allSatisfy { $0.url?.hasPrefix("http") ?? false }
                )
                // Installing the listing page instead of the endpoint would add a
                // catalogue URL as if it were an MCP server.
                let listingURLs = Set(page.items.compactMap(\.listingURL))
                c.check(
                    "glama: install target is never the listing page",
                    installable.allSatisfy { !listingURLs.contains($0.url ?? "") }
                )
                c.check(
                    "glama: at least one connector takes anonymous callers",
                    page.items.contains { ($0.connection?.authType ?? "").lowercased() == "none" }
                )
                c.check(
                    "glama: rows carry install options where an endpoint exists",
                    page.items.map(\.registryServer).contains { !$0.options.isEmpty }
                )

                // The credential must land in `headers`, not `env`: `env` is only
                // read by the stdio transport, so a key placed there is never
                // sent and the server silently authenticates as nobody.
                let store = MarketplaceStore()
                if let secured = page.items.first(where: {
                    $0.connection?.url?.isEmpty == false
                        && ($0.connection?.authType ?? "").lowercased() != "none"
                }), let option = secured.installOption {
                    let mapped = store.makeConfig(from: secured.registryServer, option: option)
                    c.equal("glama: connector maps to http transport", mapped.transport, .http)
                    c.check("glama: credential lands in headers", mapped.headers["Authorization"] != nil)
                    c.check("glama: credential does not land in env", mapped.env.isEmpty)
                } else {
                    c.check("glama: found an auth-requiring connector to check", false)
                }

                let searched = try await glama.connectors(query: "github", cursor: nil, limit: 10)
                c.check("glama: search returned results", !searched.items.isEmpty)

                let servers = try await glama.servers(query: nil, cursor: nil, limit: 25)
                c.check("glama: returned servers", !servers.items.isEmpty)
                // Glama publishes no run command for a directory entry, so the
                // only package Bud may offer for one is a package npm confirmed
                // under the entry's own slug — never a name invented from it.
                // Probed against live npm for a few records rather than all of
                // them: the answer is the same rule for every record, and npm
                // does not need twenty-five of them to say so.
                let resolver = NpmResolver()
                for record in servers.items.prefix(3) {
                    let candidate = record.npmCandidate
                    let identifier = await resolver.identifier(
                        namespace: record.namespace, slug: record.slug
                    )
                    let asked = [record.slug, "@\(record.namespace)/\(record.slug)"]
                    c.check(
                        "glama: \(record.slug) is installable only as a package npm has",
                        identifier.map(asked.contains) ?? true
                    )
                    c.check(
                        "glama: \(record.slug) offers exactly what npm confirmed",
                        record.registryServer(option: candidate.resolvedOption(resolver))
                            .options.count == (identifier == nil ? 0 : 1)
                    )
                }
            } catch {
                c.check("glama: live fetch failed (\(error.localizedDescription))", false)
            }

            // A rejected key must surface as an actionable error, not a body dump.
            do {
                _ = try await GlamaClient(apiKey: "glm_not_a_real_key")
                    .connectors(query: nil, cursor: nil, limit: 1)
                c.check("glama: a bogus key is rejected", false)
            } catch let error as GlamaError {
                if case .unauthorized = error {
                    c.check("glama: bogus key yields unauthorized", true)
                } else {
                    c.check("glama: bogus key yields unauthorized (got \(error))", false)
                }
                c.check(
                    "glama: the error text says where to get a key",
                    (error.errorDescription ?? "").contains("glama.ai")
                )
            } catch {
                c.check("glama: bogus key produced a typed GlamaError", false)
            }
        }

        // MARK: Cleanup

        await cleanup?()
        cleanup = nil

        return c.report()
    }

    // MARK: Helpers

    /// Polls a condition until it holds or the deadline passes. Used instead of
    /// observing published state directly, because the verification runs outside
    /// a SwiftUI update cycle.
    private static func waitUntil(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private enum SelfExecutable {
        static var path: String? {
            guard let raw = CommandLine.arguments.first else { return nil }
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
        }
    }
}
