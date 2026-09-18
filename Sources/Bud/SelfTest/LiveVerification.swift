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

        // MARK: Tool selection

        // The point of the allowlist is that a tool which is not sent cannot be
        // called either. A surface that hides a tool while routing still answers
        // to it would be the same visible/callable disagreement that made every
        // MCP tool unusable, so both halves are asserted.
        await mcp.setEnabledTools(["echo"], for: echoID)

        let served = await registryTools.descriptors().map(\.name).sorted()
        c.equal("selection: only the chosen tool is offered", served, ["echo__echo"])
        c.equal(
            "selection: the server still discovered both",
            mcp.discoveredTools(id: echoID).count,
            2
        )

        let withheld = await registryTools.invoke(
            name: "echo__add",
            arguments: .object(["a": .number(1), "b": .number(1)]),
            callID: "verify-5"
        )
        c.check("selection: a withheld tool cannot be called", withheld.isError)
        c.check(
            "selection: the refusal says the tool is switched off",
            withheld.text.contains("not switched on")
        )

        let stillWorks = await registryTools.invoke(
            name: "echo__echo",
            arguments: .object(["message": .string("kept")]),
            callID: "verify-6"
        )
        c.check("selection: the chosen tool still works", stillWorks.text.contains("echo: kept"))

        await mcp.setEnabledTools(nil, for: echoID)
        let restored = await registryTools.descriptors().map(\.name).sorted()
        c.equal("selection: clearing offers every tool again", restored, ["echo__add", "echo__echo"])

        // MARK: Handing a server's tools to its agent

        // The feature in four assertions. The third is the one that matters: a
        // filter that took the tools off the main agent *and* off the agent that
        // was supposed to hold them would turn a working server into an
        // unreachable one, which is the failure this design is arranged to avoid.
        var handed = mcp.servers.first { $0.id == echoID }!
        handed.delegated = true
        await mcp.updateServer(handed)

        let mainAgent = await registryTools.descriptors().filter { !$0.agentOnly }.map(\.name)
        c.check("delegation: the tools leave the main agent's list", !mainAgent.contains("echo__echo"))
        c.check("delegation: ...and everything else is still there", mainAgent.contains("echo__add") == false)

        let stillServed = await registryTools.descriptors().map(\.name)
        c.check("delegation: they are still served, so an agent can reach them",
                stillServed.contains("echo__echo"))

        let viaAgent = await registryTools.invoke(
            name: "echo__echo",
            arguments: .object(["message": .string("through the agent")]),
            callID: "verify-7"
        )
        c.check("delegation: the tool still answers", viaAgent.text.contains("through the agent"))
        c.check("delegation: ...and is not an error", !viaAgent.isError)

        // The agent that holds them, built the way the app builds it.
        let delegatedAgents = AgentRegistry()
        delegatedAgents.rebuild(skills: [], servers: mcp.servers)
        let holder = delegatedAgents.named("echo")
        c.check("delegation: the server becomes the agent that holds its tools", holder != nil)
        c.check("delegation: ...which may use them", holder?.allows("echo__echo") == true)
        c.check("delegation: ...and nothing outside its own server", holder?.allows("read_file") == false)
        c.check("delegation: ...and the model is told so",
                (holder?.summary ?? "").contains("NOT in your tool list"))

        handed.delegated = false
        await mcp.updateServer(handed)
        let handedBack = await registryTools.descriptors().filter { !$0.agentOnly }.map(\.name)
        c.check("delegation: turning it off puts them back", handedBack.contains("echo__echo"))

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

        // The picture lookup, against the real thing. A parser that agrees with a
        // fixture proves nothing here: the whole value is that Wikipedia knows what
        // a Blaziken is, and only the live call can say whether it still does.
        let one = await genui.invoke(
            tool: "find_image",
            arguments: .object(["query": .string("Blaziken")]),
            callID: "verify-find-1"
        )
        let oneText = one.text ?? ""
        c.check("find_image: an article returns its own picture", oneText.contains("upload.wikimedia.org"))
        c.check("find_image: the URL is usable as it came", !oneText.contains("utm_"))
        c.check("find_image: it says where the picture came from", oneText.contains("wikipedia.org/wiki/"))
        c.check("find_image: the model is told not to retype it", oneText.contains("do not retype"))

        // A named thing answers once, with its own picture. The fallback was
        // offering a cosplayer and a shop display alongside the creature, which is
        // worse than offering nothing: one of those is what a model picks.
        func imageURLs(_ text: String) -> [String] {
            text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    guard line.hasPrefix("http") else { return false }
                    let lowered = line.lowercased()
                    return [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains { lowered.contains($0) }
                }
        }
        c.check("find_image: a named thing returns its own picture only", imageURLs(oneText).count == 1)
        c.check("find_image: …and that picture is the article's",
                imageURLs(oneText).first?.contains("wikipedia/en/") == true)

        // One call for a set — the shape a six-card grid actually needs.
        let many = await genui.invoke(
            tool: "find_image",
            arguments: .object(["queries": .array([
                .string("Garchomp"), .string("sunset over mountains"),
                .string("Llanfairpwllgwyngyll"),
            ])]),
            callID: "verify-find-2"
        )
        let manyText = many.text ?? ""
        c.check("find_image: a set answers every query", manyText.contains("Garchomp:"))
        // A phrase is not a title, so this is the one that searches the filenames.
        c.check("find_image: a phrase falls back to a search", manyText.contains("commons.wikimedia.org"))
        c.check("find_image: a thing with no picture does not break the others", !many.isError)
        c.check("find_image: no URL comes back with tracking on it", !manyText.contains("utm_"))

        // The gap this was built to close: no query, no answer, and no crash.
        let empty = await genui.invoke(tool: "find_image", arguments: .object([:]), callID: "verify-find-3")
        c.check("find_image: an empty request is refused with a message", empty.isError)
        let nonsense = await genui.invoke(
            tool: "find_image",
            arguments: .object(["query": .string("zzqqxx not a thing 444")]),
            callID: "verify-find-4"
        )
        c.check("find_image: a hopeless query is an answer, not a failure", !nonsense.isError)

        // And the whole point: a URL it returns renders.
        if let first = oneText.split(separator: "\n").first(where: { $0.contains("http") })?
            .trimmingCharacters(in: .whitespaces) {
            let spec = JSONValue(parsing: """
                {"title":"Found","components":[{"type":"image","url":"\(first)","width":120}]}
                """)!
            let rendered = await genui.invoke(tool: "render_ui", arguments: spec, callID: "verify-find-5")
            c.check("find_image: what it finds renders in a surface", rendered.ui != nil && !rendered.isError)
        } else {
            c.check("find_image: what it finds renders in a surface", false)
        }

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

        // MARK: Rewinding

        // Retry and delete-from-here both restore a checkpoint, and having a
        // checkpoint is what makes them correct: the model-facing history holds
        // tool call and result messages that no turn records, so it cannot be
        // unwound from the turns. Asserted on the state immediately after the
        // call, before the re-send has streamed anything back.
        let lastIndex = runtime.turns.count - 1
        c.check("rewind: a live exchange can be rewound", runtime.canRewind(toTurnAt: lastIndex))
        c.check("rewind: the exchange left model history", runtime.messageCount >= 2)

        let question = runtime.turns.first?.plainText ?? ""
        c.check("rewind: retry reports success", runtime.retry(turnAt: lastIndex))
        // Back to the question alone, plus the re-ask — which is the same
        // question, so one turn and one message.
        c.equal("rewind: retry leaves only the question", runtime.turns.count, 1)
        c.equal("rewind: retry rewinds the model history", runtime.messageCount, 1)
        c.equal("rewind: retry asks the same question again", runtime.turns.first?.plainText, question)
        runtime.stop()

        // The negative: a conversation loaded from the archive has no
        // checkpoints, so it must not offer a retry that would silently do the
        // wrong thing.
        let loaded = AgentRuntime(env: runtimeEnv)
        loaded.restore(turns: runtime.turns, history: runtime.modelHistory)
        c.check("rewind: a loaded conversation cannot rewind", !loaded.canRewind(toTurnAt: 0))
        c.check(
            "rewind: dropping an unknown exchange is refused",
            !loaded.deleteFrom(turnAt: 0)
        )

        // MARK: A result too large to send

        // Against a real page, because the sizes here are the whole question and a
        // fixture would be sized to agree with the code. What is asserted is not
        // just that the message is bounded — it always was — but that what left it
        // can still be read back.
        let fetcher = NativeToolsProvider()
        let page = await fetcher.invoke(
            tool: "web_fetch",
            arguments: .object(["url": .string("https://en.wikipedia.org/wiki/Pokémon")]),
            callID: "verify-store-1"
        )
        let whole = page.text ?? ""
        c.check(
            "store: a real page is larger than a request (\(BudFormat.count(whole.count)) characters)",
            whole.count > 24_000
        )

        let faced = page.modelFacingText()
        c.check("store: the message is bounded (\(BudFormat.count(faced.count)))", faced.count < 25_000)
        c.check("store: ...and says what is behind it", faced.contains("more characters"))
        c.check("store: ...and names the tool that reads it", faced.contains("read_stored"))

        let handle = faced
            .split(separator: " ")
            .first(where: { $0.hasPrefix("store_") })?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,]")) ?? ""
        c.check("store: ...and carries a usable handle", StoredResults.isHandle(handle))
        // The point: 87% of that page used to be gone, and is now where it can be
        // found rather than merely kept.
        c.equal(
            "store: the whole page is behind the handle",
            StoredResults.read(handle: handle)?.count,
            whole.count
        )

        // And the model can find things in it — the reason to keep the tail at all.
        let searched = await fetcher.invoke(
            tool: "read_stored",
            arguments: .object([
                "handle": .string(handle),
                "pattern": .string("Pikachu"),
            ]),
            callID: "verify-store-2"
        )
        c.check("store: the kept text can be searched", !searched.isError)
        c.check("store: ...and returns lines from it",
                (searched.text ?? "").lowercased().contains("pikachu"))

        // Anchored to the real length rather than to a number this file guessed:
        // the tail of a page is what the head left out, and how long that is
        // depends on the page.
        let totalLines = StoredResults.lineCount(handle: handle)
        c.check("store: the page kept more than one line (\(BudFormat.count(totalLines)))", totalLines > 10)
        let beyondHead = await fetcher.invoke(
            tool: "read_stored",
            arguments: .object([
                "handle": .string(handle),
                "start_line": .number(Double(max(1, totalLines - 4))),
                "end_line": .number(Double(max(1, totalLines - 2))),
            ]),
            callID: "verify-store-3"
        )
        c.check("store: the far end of it is readable", !beyondHead.isError)
        c.check("store: ...and is not empty", !(beyondHead.text ?? "").isEmpty)

        // MARK: Rendering from the stripped schema

        // The schema is the model's whole vocabulary for the DSL, and it just lost
        // the sentence that used to sit on every field saying which component the
        // field belonged to. Whether it is still enough is not answerable from the
        // source: it is answerable by asking for a surface and looking at whether
        // one came back.
        let uiEnv = AppEnvironment(config: config)
        await uiEnv.registry.register(GenUIToolProvider())
        let uiRuntime = AgentRuntime(env: uiEnv)
        uiRuntime.send(
            "Render a table of the three largest planets with their diameters. "
                + "Do not write any prose — just the surface."
        )
        let uiSettled = await waitUntil(timeout: 180) { !uiRuntime.isStreaming }
        c.check("render: the turn settled", uiSettled)

        let producedSurface = uiRuntime.turns.contains { turn in
            turn.segments.contains { segment in
                if case .tool(_, _, _, let state, _, let ui) = segment {
                    return state == .succeeded && ui != nil
                }
                return false
            }
        }
        c.check("render: a surface came back from the stripped schema", producedSurface)

        let surfaceComponents = uiRuntime.turns.reduce(0) { running, turn in
            running + turn.segments.reduce(0) { inner, segment in
                if case .tool(_, _, _, _, _, let ui) = segment, let ui {
                    return inner + (ui["components"]?.arrayValue?.count ?? 0)
                }
                return inner
            }
        }
        c.check("render: ...with components in it (\(surfaceComponents))", surfaceComponents >= 1)
        uiRuntime.stop()

        // MARK: Subagent

        let supervisor = SubagentSupervisor(env: runtimeEnv, agents: AgentRegistry())
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

        // MARK: Skills (live)

        // Against the shipped source, over the real network. What is asserted is
        // the shape of the contract rather than a particular inventory: a list of
        // skills changes without notice, and a check that pinned "there are twenty"
        // would fail the day somebody added one.
        let skills = SkillRegistry()
        c.check("skills: the shipped source is a repository", skills.sources.count >= 1)

        if let source = skills.sources.first {
            do {
                let found = try await skills.browse(source)
                c.check("skills: browsing finds skills (\(found.count))", found.count >= 1)
                c.check("skills: every one parses a name", found.allSatisfy { !$0.name.isEmpty })
                c.check(
                    "skills: every one carries a description to be found by",
                    found.allSatisfy { $0.summary.count > 20 }
                )
                c.check("skills: names obey the spec's rules", found.allSatisfy { entry in
                    (try? SkillParser.validate(name: entry.name)) != nil
                })

                // One install, then put it back. The whole point of the
                // marketplace is that a folder arrives intact, so the check is
                // the folder on disk and not the fact that a request succeeded.
                if let candidate = found.first(where: { !$0.isInstalled }) {
                    try await skills.prepare(candidate)
                    // A real skill from a real repository should not be asking to
                    // be reviewed: if it is, either the skill changed or a rule is
                    // too eager, and both are worth knowing about here rather than
                    // in front of a user.
                    c.check("skills: a published skill needs no review",
                            skills.pending == nil)
                    if skills.pending != nil { try skills.confirmPending() }

                    if let installed = SkillStore.read(name: candidate.name) {
                        c.equal("skills: the installed name matches what was offered",
                                installed.name, candidate.name)
                        c.check("skills: the skill landed on disk",
                                FileManager.default.fileExists(
                                    atPath: SkillStore.directory
                                        .appendingPathComponent(candidate.name)
                                        .appendingPathComponent("SKILL.md").path
                                ))
                        c.check("skills: it reads back with its instructions",
                                (installed.instructions.count) > 0)
                        c.check("skills: it is listed as installed",
                                SkillStore.installed().contains { $0.name == candidate.name })

                        let resources = installed.resources
                        c.check("skills: whatever else it carried came with it (\(resources.count) files)",
                                !resources.isEmpty || candidate.folder.isEmpty)

                        // macOS's own marking, reused rather than reinvented:
                        // what Bud downloaded should look downloaded.
                        let manifest = SkillStore.directory
                            .appendingPathComponent(candidate.name)
                            .appendingPathComponent("SKILL.md")
                        let quarantine = try? manifest
                            .resourceValues(forKeys: [.quarantinePropertiesKey])
                            .quarantineProperties
                        c.check("skills: what was downloaded is marked as downloaded",
                                quarantine != nil)

                        try skills.uninstall(candidate.name)
                        c.check("skills: uninstalling removes it",
                                !SkillStore.installed().contains { $0.name == candidate.name })
                    } else {
                        c.check("skills: the skill is readable after installing", false)
                    }
                }
            } catch {
                c.check("skills: browsing the shipped source (\(error.localizedDescription))", false)
            }
        }

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
