import Foundation

/// Dependency-free assertion harness.
///
/// `swift test` is unusable here: this machine has only the Command Line Tools,
/// which ship neither XCTest nor Swift Testing. Rather than commit tests that can
/// never run, the checks live in the shipped binary behind `--self-test`, so they
/// execute against exactly the code the app runs, on any machine.
public struct SelfTestReport: Sendable {
    public var passed = 0
    public var failures: [String] = []
    public var total: Int { passed + failures.count }
    public var ok: Bool { failures.isEmpty }
}

/// Collects results for one named suite.
public final class Checker {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private let suite: String

    public init(suite: String) {
        self.suite = suite
    }

    public func check(_ name: String, _ condition: Bool) {
        if condition {
            passed += 1
        } else {
            failures.append("\(suite) › \(name)")
        }
    }

    public func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(suite) › \(name)\n      expected: \(expected)\n      actual:   \(actual)")
        }
    }

    public func nilValue<T>(_ name: String, _ value: T?) {
        if value == nil {
            passed += 1
        } else {
            failures.append("\(suite) › \(name) — expected nil, got \(String(describing: value))")
        }
    }

    public func notNil<T>(_ name: String, _ value: T?) {
        if value != nil {
            passed += 1
        } else {
            failures.append("\(suite) › \(name) — expected a value, got nil")
        }
    }

    public func report() -> SelfTestReport {
        SelfTestReport(passed: passed, failures: failures)
    }
}

/// The offline suite registry. Every check here is deterministic and touches no
/// network, so it is safe to run anywhere and is the gate for a release build.
public enum BudSelfTest {
    public static func run() -> SelfTestReport {
        let suites: [() -> SelfTestReport] = [
            configParsing,
            globMatching,
            htmlExtraction,
            streamDecoding,
            chatWireFormat,
            jsonValue,
            toolNaming,
            providers,
            mcpConfigMapping,
            glamaMapping,
            toolTruncation,
        ]
        var total = SelfTestReport()
        for suite in suites {
            let report = suite()
            total.passed += report.passed
            total.failures.append(contentsOf: report.failures)
        }
        return total
    }

    // MARK: Config

    static func configParsing() -> SelfTestReport {
        let c = Checker(suite: "config")

        let full = BudConfigLoader.parseModelRole(
            fromYAML: "modelRoles:\n  default: deepseek/deepseek-v4-flash:max\nsymbolPreset: nerd\n"
        )
        c.equal("provider-qualified model", full?.model, "deepseek-v4-flash")
        c.equal("effort suffix", full?.effort, "max")

        let bare = BudConfigLoader.parseModelRole(fromYAML: "modelRoles:\n  default: deepseek-v4-pro\n")
        c.equal("bare model", bare?.model, "deepseek-v4-pro")
        c.nilValue("bare model has no effort", bare?.effort)

        let quoted = BudConfigLoader.parseModelRole(
            fromYAML: "modelRoles:\n  default: \"deepseek/deepseek-v4-pro:high\"\n"
        )
        c.equal("quoted model", quoted?.model, "deepseek-v4-pro")
        c.equal("quoted effort", quoted?.effort, "high")

        // A sibling key before `default` must not be picked up, and the block
        // must end at the next top-level key.
        let siblings = BudConfigLoader.parseModelRole(fromYAML: """
        modelRoles:
          smol: deepseek/deepseek-v4-flash
          default: deepseek/deepseek-v4-pro:low
        theme:
          light: alabaster
        """)
        c.equal("sibling keys ignored", siblings?.model, "deepseek-v4-pro")
        c.equal("sibling keys effort", siblings?.effort, "low")

        c.nilValue("absent key", BudConfigLoader.parseModelRole(fromYAML: "symbolPreset: nerd\n"))
        c.nilValue("only unrelated role", BudConfigLoader.parseModelRole(fromYAML: "modelRoles:\n  other: x\n"))

        let commented = BudConfigLoader.parseModelRole(fromYAML: """
        # modelRoles:
        modelRoles:
          # default: wrong
          default: deepseek/deepseek-v4-flash:max
        """)
        c.equal("comments ignored", commented?.model, "deepseek-v4-flash")

        // Shell profiles are the only place a Finder-launched app can find a key,
        // so a miss here is a key the marketplace never sees. The quotes are the
        // part that fails quietly: they have to come off, and a lookalike name
        // must not answer for the real one.
        let profile = """
        export DEEPSEEK_API_KEY="sk-quoted"
        export GLAMA_API_KEY='glm-single'
        export GLAMA_API_KEY_OLD=glm-stale
        """
        c.equal(
            "double-quoted shell value",
            BudConfigLoader.parseShellAssignment(in: profile, named: "DEEPSEEK_API_KEY"),
            "sk-quoted"
        )
        c.equal(
            "single-quoted shell value",
            BudConfigLoader.parseShellAssignment(in: profile, named: "GLAMA_API_KEY"),
            "glm-single"
        )
        c.equal(
            "bare shell assignment",
            BudConfigLoader.parseShellAssignment(in: "GLAMA_API_KEY=glm-bare\n", named: "GLAMA_API_KEY"),
            "glm-bare"
        )
        c.equal(
            "indented shell export",
            BudConfigLoader.parseShellAssignment(in: "  export GLAMA_API_KEY=glm-indent", named: "GLAMA_API_KEY"),
            "glm-indent"
        )
        c.nilValue(
            "a longer name must not answer for the requested one",
            BudConfigLoader.parseShellAssignment(in: "export GLAMA_API_KEY_OLD=glm-stale\n", named: "GLAMA_API_KEY")
        )
        c.nilValue(
            "unrelated shell name is ignored",
            BudConfigLoader.parseShellAssignment(in: "OTHER=1", named: "GLAMA_API_KEY")
        )
        c.equal(
            "blank shell value falls through",
            BudConfigLoader.parseShellAssignment(
                in: "GLAMA_API_KEY=\nGLAMA_API_KEY=glm-later\n", named: "GLAMA_API_KEY"
            ),
            "glm-later"
        )

        return c.report()
    }

    // MARK: Glob

    static func globMatching() -> SelfTestReport {
        let c = Checker(suite: "glob")
        // Reference as a closure so the default argument survives; a bare
        // function value would drop it and the labels.
        func g(_ pattern: String, _ path: String, crossesSeparators: Bool = false) -> Bool {
            NativeToolsProvider.globMatch(
                pattern: pattern, in: path, crossesSeparators: crossesSeparators
            )
        }

        c.check("basename star matches basename", g("*.swift", "foo.swift"))
        c.check("basename star does not cross /", !g("*.swift", "src/foo.swift"))
        c.check("deep star crosses /", g("*.swift", "src/deep/foo.swift", crossesSeparators: true))
        c.check("deep star matches nested md", g("*.md", "a/b/c/readme.md", crossesSeparators: true))
        c.check("deep star still respects extension", !g("*.md", "a/b/c/readme.txt", crossesSeparators: true))

        c.check("? matches one char", g("a?c", "abc"))
        c.check("? rejects zero chars", !g("a?c", "ac"))
        c.check("? does not match /", !g("a?c", "a/c"))

        c.check("bare * matches all", g("*", "anything/at/all"))
        c.check("empty pattern matches all", g("", "anything"))

        c.check("class range hit", g("file[0-9].txt", "file3.txt"))
        c.check("class range miss", !g("file[0-9].txt", "fileX.txt"))
        c.check("negated class hit", g("file[!0-9].txt", "fileX.txt"))
        c.check("negated class miss", !g("file[!0-9].txt", "file3.txt"))

        c.check("anchored prefix", !g("foo", "foobar"))
        c.check("unanchored with stars", g("*foo*", "aafoobar"))

        return c.report()
    }

    // MARK: HTML

    static func htmlExtraction() -> SelfTestReport {
        let c = Checker(suite: "html")
        let h = NativeToolsProvider.htmlToText

        let dirty = "<html><head><style>body{color:red}</style></head>"
            + "<body><script>alert('x')</script><p>Hello</p></body></html>"
        let clean = h(dirty)
        c.check("keeps prose", clean.contains("Hello"))
        c.check("drops script body", !clean.contains("alert"))
        c.check("drops style body", !clean.contains("color:red"))

        c.equal("block elements break lines", h("<p>one</p><p>two</p><div>three</div>"), "one\ntwo\nthree")
        c.check("list items bulleted", h("<ul><li>alpha</li><li>beta</li></ul>").contains("• alpha"))
        c.equal("entities decoded", h("<p>a &amp; b &lt;tag&gt; &quot;q&quot;</p>"), #"a & b <tag> "q""#)
        c.equal("blank runs collapsed", h("<p>a</p><p></p><p></p><p></p><p>b</p>"), "a\n\nb")

        return c.report()
    }

    // MARK: SSE

    static func streamDecoding() -> SelfTestReport {
        let c = Checker(suite: "stream")
        func d(line: String) -> StreamEvent? { OpenAICompatibleBackend.decode(line: line) }

        if case .reasoningDelta(let t)? = d(line: #"data: {"choices":[{"delta":{"reasoning_content":"think"}}]}"#) {
            c.equal("reasoning delta", t, "think")
        } else {
            c.check("reasoning delta", false)
        }

        if case .contentDelta(let t)? = d(line: #"data: {"choices":[{"delta":{"content":"answer"}}]}"#) {
            c.equal("content delta", t, "answer")
        } else {
            c.check("content delta", false)
        }

        let opening = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":"{\"ci"}}]}}]}"#
        if case .toolCallDelta(let i, let id, let name, let frag)? = d(line: opening) {
            c.equal("tool call index", i, 0)
            c.equal("tool call id", id, "call_1")
            c.equal("tool call name", name, "get_weather")
            c.equal("tool call first fragment", frag, "{\"ci")
        } else {
            c.check("tool call opening fragment", false)
        }

        let continuation = #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"ty\":\"Paris\"}"}}]}}]}"#
        if case .toolCallDelta(let i, let id, let name, let frag)? = d(line: continuation) {
            c.equal("continuation index", i, 1)
            c.nilValue("continuation has no id", id)
            c.nilValue("continuation has no name", name)
            c.equal("continuation fragment", frag, "ty\":\"Paris\"}")
        } else {
            c.check("tool call continuation fragment", false)
        }

        if case .finish(let r)? = d(line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#) {
            c.equal("finish reason", r, "tool_calls")
        } else {
            c.check("finish reason", false)
        }

        let usageLine = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"prompt_cache_hit_tokens":3}}"#
        if case .usage(let p, let comp, let cached)? = d(line: usageLine) {
            c.equal("usage prompt", p, 10)
            c.equal("usage completion", comp, 4)
            c.equal("usage cached", cached, 3)
        } else {
            c.check("usage frame", false)
        }

        c.nilValue("blank line", d(line: ""))
        c.nilValue("sse comment", d(line: ": keep-alive"))
        c.nilValue("done sentinel", d(line: "data: [DONE]"))
        c.nilValue("event line", d(line: "event: message"))
        c.nilValue("empty delta", d(line: #"data: {"choices":[{"delta":{}}]}"#))
        c.nilValue("empty content", d(line: #"data: {"choices":[{"delta":{"content":""}}]}"#))
        c.nilValue("malformed json", d(line: "data: {not json"))
        c.nilValue("no choices", d(line: "data: {}"))

        // DeepSeek puts `finish_reason` and `usage` in the SAME terminal frame.
        // Emitting only one of them silently loses the finish reason, and the
        // agent loop keys off it to know a round is over.
        let combined = OpenAICompatibleBackend.decodeEvents(
            line: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":1}}"#
        )
        c.equal("terminal frame yields usage and finish", combined.count, 2)
        if case .usage? = combined.first {
            c.check("terminal frame: usage emitted first", true)
        } else {
            c.check("terminal frame: usage emitted first", false)
        }
        if case .finish(let r)? = combined.last {
            c.equal("terminal frame: finish reason retained", r, "tool_calls")
        } else {
            c.check("terminal frame: finish reason retained", false)
        }

        // A usage-only frame carries no choices at all and must still be read.
        let usageOnly = OpenAICompatibleBackend.decodeEvents(
            line: #"data: {"usage":{"prompt_tokens":7,"completion_tokens":2}}"#
        )
        c.equal("usage-only frame is emitted", usageOnly.count, 1)

        // Several calls can be pipelined into one frame; each is its own call.
        let multi = OpenAICompatibleBackend.decodeEvents(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"x","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"y","arguments":"{}"}}]}}]}"#
        )
        c.equal("pipelined tool calls all emitted", multi.count, 2)

        return c.report()
    }

    // MARK: Wire format

    static func chatWireFormat() -> SelfTestReport {
        let c = Checker(suite: "wire")

        let plain = ChatMessage(role: .user, content: "hi").openAIWireRepresentation
        c.equal("role", plain["role"]?.stringValue, "user")
        c.equal("content", plain["content"]?.stringValue, "hi")
        c.nilValue("no tool_calls on plain message", plain["tool_calls"])

        let toolCall = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Paris"}"#)]
        ).openAIWireRepresentation
        c.check("empty content becomes null", toolCall["content"]?.isNull ?? false)
        c.equal("tool call count", toolCall["tool_calls"]?.arrayValue?.count, 1)
        c.equal("tool call id", toolCall["tool_calls"]?[0]?["id"]?.stringValue, "call_1")
        c.equal("tool call type", toolCall["tool_calls"]?[0]?["type"]?.stringValue, "function")
        c.equal(
            "tool call arguments verbatim",
            toolCall["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue,
            #"{"city":"Paris"}"#
        )

        // The API returns reasoning but rejects it on input.
        let withReasoning = ChatMessage(role: .assistant, content: "done", reasoning: "secret plan")
            .openAIWireRepresentation
        c.nilValue("reasoning not echoed", withReasoning["reasoning_content"])
        c.check("reasoning text absent", !withReasoning.encodedString().contains("secret"))

        let toolResult = ChatMessage(
            role: .tool, content: "18C", toolCallID: "call_1", name: "get_weather"
        ).openAIWireRepresentation
        c.equal("tool role", toolResult["role"]?.stringValue, "tool")
        c.equal("tool_call_id links back", toolResult["tool_call_id"]?.stringValue, "call_1")

        return c.report()
    }

    // MARK: JSON

    static func jsonValue() -> SelfTestReport {
        let c = Checker(suite: "json")

        // Integral doubles must serialize as integers; both DeepSeek and MCP
        // schemas reject `1.0` where an integer is declared.
        c.equal("1.0 encodes as 1", JSONValue.number(1.0).encodedString(), "1")
        c.equal("42.0 encodes as 42", JSONValue.number(42.0).encodedString(), "42")
        c.equal("1.5 stays fractional", JSONValue.number(1.5).encodedString(), "1.5")

        let json = #"{"a":[1,2.5,"x",true,null],"b":{"c":false}}"#
        c.equal("round trip", JSONValue(parsing: json)?.encodedString(), json)

        c.nilValue("empty is nil", JSONValue(parsing: ""))
        c.nilValue("whitespace is nil", JSONValue(parsing: "   "))
        c.nilValue("garbage is nil", JSONValue(parsing: "{oops"))

        c.equal("objectOrEmpty on blank", JSONValue.objectOrEmpty(parsing: ""), .object([:]))
        c.equal("objectOrEmpty on garbage", JSONValue.objectOrEmpty(parsing: "x"), .object([:]))
        c.equal("objectOrEmpty passthrough", JSONValue.objectOrEmpty(parsing: #"{"a":1}"#), .object(["a": .number(1)]))

        c.equal("number to string", JSONValue.number(2.0).stringValue, "2")
        c.equal("bool to string", JSONValue.bool(true).stringValue, "true")
        c.nilValue("null has no string", JSONValue.null.stringValue)

        let nested = JSONValue(parsing: #"{"list":[{"name":"x"}]}"#)
        c.equal("nested subscript", nested?["list"]?[0]?["name"]?.stringValue, "x")
        c.nilValue("missing key", nested?["missing"])
        c.nilValue("out of range index", nested?["list"]?[9])

        // Bool must be tried before number, or `true` decodes as 1.
        c.equal("true is bool", JSONValue(parsing: "true"), .bool(true))
        c.equal("1 is number", JSONValue(parsing: "1"), .number(1))

        return c.report()
    }

    // MARK: Tool naming

    static func toolNaming() -> SelfTestReport {
        let c = Checker(suite: "naming")

        c.equal("unsupported chars replaced", ToolNaming.sanitize("a.b/c d:e"), "a_b_c_d_e")
        c.equal("legal chars preserved", ToolNaming.sanitize("Create_Issue-2"), "Create_Issue-2")
        c.equal("length capped", ToolNaming.sanitize(String(repeating: "a", count: 200)).count, 64)
        c.equal("empty falls back", ToolNaming.sanitize(""), "tool")

        let namespaced = ToolNaming.namespaced(server: "GitHub MCP", tool: "create.issue")
        c.equal("namespaced form", namespaced, "mcp__github_mcp__create_issue")
        c.check(
            "namespaced result is model-legal",
            namespaced.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
        )

        // One server must not be addressable under two prefixes: the provider
        // builds tool names with `namespaced` while the UI builds the namespace
        // from `MCPServerConfig.namespace`, and they have to agree.
        let config = MCPServerConfig(name: "GitHub MCP", command: "x")
        c.equal(
            "namespaced prefix matches server namespace",
            ToolNaming.namespaced(server: config.name, tool: "t").contains("mcp__\(config.namespace)__"),
            true
        )

        return c.report()
    }

    // MARK: MCP config

    static func mcpConfigMapping() -> SelfTestReport {
        let c = Checker(suite: "mcp-config")

        let stdio = MCPServerConfig(
            name: "filesystem", transport: .stdio,
            command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        )
        c.equal(
            "stdio summary is the command line",
            stdio.summary,
            "npx -y @modelcontextprotocol/server-filesystem /tmp"
        )

        let remote = MCPServerConfig(name: "inference", transport: .http, url: "https://sh.inference.ac")
        c.equal("remote summary is the url", remote.summary, "https://sh.inference.ac")

        c.equal("namespace sanitised", MCPServerConfig(name: "My Server!", command: "x").namespace, "my_server")
        c.equal(
            "option identity stable",
            RegistryInstallOption(id: "npm:x", label: "npx -y x", transport: .stdio, command: "npx", args: ["-y", "x"]),
            RegistryInstallOption(id: "npm:x", label: "npx -y x", transport: .stdio, command: "npx", args: ["-y", "x"])
        )

        return c.report()
    }

    // MARK: Glama

    /// Glama's catalogue, mapped offline.
    ///
    /// Every check here guards a failure that would otherwise be silent: a wrong
    /// identity means a freshly installed server never shows as installed, a
    /// credential written to the wrong field is simply never sent (an HTTP server
    /// still answers `initialize` unauthenticated, so nothing looks wrong until a
    /// tool call), and a fabricated install command yields a server that cannot
    /// start.
    static func glamaMapping() -> SelfTestReport {
        let c = Checker(suite: "glama")

        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
            try? JSONDecoder().decode(type, from: Data(json.utf8))
        }

        // MARK: Connectors

        // Shaped like a live record. The two URLs really are different hosts:
        // Glama's listing page versus the endpoint the publisher hosts.
        let anonymous = decode(GlamaConnector.self, """
        {
          "id": "rec_github",
          "name": "GitHub",
          "namespace": "acme",
          "slug": "github",
          "url": "https://glama.ai/mcp/connectors/acme/github",
          "description": "GitHub's hosted MCP server.",
          "attributes": ["tools", "search"],
          "qualityScore": 84.5,
          "isBoosted": false,
          "thumbnailUrl": "https://glama.ai/thumbs/github.png",
          "repository": {"url": "https://github.com/acme/github-mcp"},
          "healthy": true,
          "toolCount": 27,
          "connection": {"authType": "none", "transport": "streamable_http", "url": "https://mcp.acme.dev/github"}
        }
        """)

        if let connector = anonymous, let option = connector.installOption {
            let row = connector.registryServer
            c.equal("connector identity", connector.registryIdentity, "glama:acme/github")
            c.equal("row id is the identity", row.id, "glama:acme/github")
            c.equal("row name is the identity", row.name, "glama:acme/github")
            c.equal("row title is the record name", row.title, "GitHub")
            c.equal("row summary is the description", row.summary, "GitHub's hosted MCP server.")
            c.equal("row listing is the API's url", row.websiteURL, connector.listingURL)
            c.equal("row repository", row.repositoryURL, "https://github.com/acme/github-mcp")
            c.equal("row icon", row.iconURL, "https://glama.ai/thumbs/github.png")
            c.equal("row version is empty", row.version, "")
            c.equal("connector maps to exactly one option", row.options.count, 1)
            c.equal("option id is fixed", option.id, "glama-connector")
            c.equal("option transport is http", option.transport, MCPTransportKind.http)
            c.nilValue("no stdio command is invented", option.command)
            c.check("listing and endpoint differ", connector.listingURL != connector.connection?.url)
            c.equal("option url is the endpoint", option.url, "https://mcp.acme.dev/github")
            c.check("option url is not the listing", option.url != connector.listingURL)
            c.equal("anonymous connector needs no credential", option.requiredEnv, [String]())
        } else {
            c.check("connector with a connection maps to one option", false)
        }

        // One record with no credential, one with an API key, one with OAuth: the
        // live sample is roughly a third credentialed, so this is the common path,
        // not an edge.
        let keyed = decode(GlamaConnector.self, """
        {
          "id": "rec_linear",
          "name": "Linear",
          "namespace": "linear",
          "slug": "linear",
          "url": "https://glama.ai/mcp/connectors/linear/linear",
          "connection": {"authType": "api_key", "transport": "streamable_http", "url": "https://mcp.linear.app/mcp"}
        }
        """)
        let oauth = decode(GlamaConnector.self, """
        {
          "id": "rec_oauth",
          "name": "Notion",
          "namespace": "notion",
          "slug": "notion",
          "url": "https://glama.ai/mcp/connectors/notion/notion",
          "connection": {"authType": "oauth2", "transport": "streamable_http", "url": "https://mcp.notion.com/mcp"}
        }
        """)

        // A record missing description, attributes, toolCount, repository and
        // thumbnail still has to decode and keep its name: the thumbnail is
        // absent for most of the catalogue.
        if let connector = keyed {
            c.equal("sparse connector keeps its name", connector.name, "Linear")
            c.nilValue("absent description stays nil", connector.description)
            c.check("absent attributes default to empty", connector.attributes.isEmpty)
            c.nilValue("absent toolCount stays nil", connector.toolCount)
            c.nilValue("absent repository stays nil", connector.repository)
            c.nilValue("absent thumbnail stays nil", connector.thumbnailUrl)
        } else {
            c.check("sparse connector decodes", false)
        }

        if let connector = keyed, let option = connector.installOption {
            c.equal("api_key connector needs Authorization", option.requiredEnv, ["Authorization"])
            c.check("api_key option states the shape", option.label.contains("Bearer <key>"))
            c.check("option label still names the endpoint", option.label.contains("https://mcp.linear.app/mcp"))

            let row = connector.registryServer
            // The credential contract. `env` is read only by the stdio transport;
            // an HTTP key written there is never sent, and the server authenticates
            // as nobody without complaining.
            let blank = MarketplaceStore.makeConfig(from: row, option: option)
            c.equal("http credential is prefilled as a header", blank.headers["Authorization"], "")
            c.check("http credential is not prefilled as an env var", blank.env.isEmpty)
            c.equal("http config transport", blank.transport, MCPTransportKind.http)
            c.equal("http config url is the endpoint", blank.url, "https://mcp.linear.app/mcp")
            c.nilValue("http config has no command", blank.command)

            let installed = MarketplaceStore.makeConfig(
                from: row, option: option, credentials: ["Authorization": "Bearer glm_test"]
            )
            c.equal("typed credential lands in headers", installed.headers["Authorization"], "Bearer glm_test")
            c.check("typed credential is not in env", installed.env.isEmpty)
            // `isInstalled` answers by comparing the installed config's
            // registryName to the row's name, so these two must be the same string.
            c.equal("registryName uses the glama scheme", installed.registryName, "glama:linear/linear")
            c.equal("registryName matches the row name", installed.registryName, row.name)
        } else {
            c.check("api_key connector maps to one option", false)
        }

        if let option = oauth?.installOption {
            c.equal("oauth2 connector needs Authorization", option.requiredEnv, ["Authorization"])
            c.check("oauth2 option says where the endpoints are", option.label.contains("oauth-authorization-server"))
        } else {
            c.check("oauth2 connector maps to one option", false)
        }

        // MARK: Servers

        // A directory entry, with the real shape: a repository, no thumbnail, and
        // no package or run command anywhere in the payload.
        let directory = decode(GlamaServer.self, """
        {
          "id": "srv_filesystem",
          "name": "Filesystem",
          "namespace": "modelcontextprotocol",
          "slug": "filesystem",
          "url": "https://glama.ai/mcp/servers/modelcontextprotocol/filesystem",
          "description": "Exposes the filesystem over MCP.",
          "attributes": ["tools"],
          "repository": {"url": "https://github.com/modelcontextprotocol/servers"},
          "spdxLicense": "MIT"
        }
        """)

        if let server = directory {
            let row = server.registryServer
            c.equal("server identity", row.name, "glama:modelcontextprotocol/filesystem")
            c.equal("server row title", row.title, "Filesystem")
            c.equal("server row listing is the API's url", row.websiteURL, server.listingURL)
            c.equal("server row repository", row.repositoryURL, "https://github.com/modelcontextprotocol/servers")
            c.nilValue("server with no thumbnail has no icon", row.iconURL)
            // The honest mapping: nothing invented, so the card is browse-only
            // rather than offering an install that could not run.
            c.equal("server maps to no install options", row.options.count, 0)
        } else {
            c.check("directory server decodes", false)
        }

        // Explicit nulls for every field but the identity, which is exactly what
        // the API sends for `repository` on most connectors.
        let sparse = decode(GlamaServer.self, """
        {
          "id": "srv_odd",
          "name": "Odd",
          "namespace": "n",
          "slug": "odd",
          "url": "https://glama.ai/mcp/servers/n/odd",
          "repository": null,
          "description": null,
          "attributes": null,
          "thumbnailUrl": null
        }
        """)
        if let server = sparse {
            c.equal("nulled record keeps its name", server.name, "Odd")
            c.nilValue("null repository stays nil", server.repository)
            c.nilValue("null description stays nil", server.description)
            c.check("null attributes default to empty", server.attributes.isEmpty)
            c.equal("nulled record still maps", server.registryServer.name, "glama:n/odd")
        } else {
            c.check("record with explicit nulls decodes", false)
        }

        // MARK: Credential placement

        // The same rule the other way round: a stdio package needs its key in the
        // child's environment, and would ignore a header.
        let stdioRow = RegistryServer(
            id: "npm:@acme/files", name: "npm:@acme/files", title: "Files", summary: ""
        )
        let stdioOption = RegistryInstallOption(
            id: "npm:@acme/files", label: "npx -y @acme/files",
            transport: .stdio, command: "npx", args: ["-y", "@acme/files"],
            requiredEnv: ["ACME_API_KEY"]
        )
        let stdioBlank = MarketplaceStore.makeConfig(from: stdioRow, option: stdioOption)
        c.equal("stdio credential is prefilled in env", stdioBlank.env["ACME_API_KEY"], "")
        c.check("stdio credential is not a header", stdioBlank.headers.isEmpty)

        let stdioInstalled = MarketplaceStore.makeConfig(
            from: stdioRow, option: stdioOption, credentials: ["ACME_API_KEY": "secret"]
        )
        c.equal("typed stdio credential lands in env", stdioInstalled.env["ACME_API_KEY"], "secret")
        c.check("typed stdio credential is not a header", stdioInstalled.headers.isEmpty)
        c.equal("stdio config keeps its command", stdioInstalled.command, "npx")

        // MARK: Client boundary

        // No key: the call must stop before a request exists. `makeRequest` is the
        // only path to one, so this is where that is provable without a network.
        let keyless = GlamaClient(apiKey: "")
        do {
            _ = try keyless.makeRequest(path: "/v1/connectors", items: [])
            c.check("empty key throws missingKey", false)
        } catch let error as GlamaError {
            c.equal("empty key throws missingKey", error, GlamaError.missingKey)
            c.check(
                "missingKey says where to get one",
                error.localizedDescription.contains("glama.ai/settings/api-keys")
            )
        } catch {
            c.check("empty key throws missingKey", false)
        }

        let client = GlamaClient(apiKey: "glm_test")
        do {
            let request = try client.makeRequest(
                path: "/v1/connectors",
                items: GlamaClient.queryItems(query: "git hub/api", cursor: "cursor_2", limit: 5_000)
            )
            c.equal("auth header carries the key", request.value(forHTTPHeaderField: "Authorization"), "Bearer glm_test")
            c.equal("read is a GET", request.httpMethod, "GET")
            c.equal("limit is clamped to the API ceiling", GlamaClient.clamp(5_000), 100)
            c.equal("limit floor", GlamaClient.clamp(0), 1)

            let items = request.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems ?? []
            c.equal("query is percent-encoded once and back", items.first { $0.name == "query" }?.value, "git hub/api")
            c.equal("cursor is sent as after", items.first { $0.name == "after" }?.value, "cursor_2")
            c.equal("first carries the clamped limit", items.first { $0.name == "first" }?.value, "100")
            c.equal("base url", GlamaClient.defaultBaseURLString + "/v1/connectors", "https://glama.ai/api/mcp/v1/connectors")
        } catch {
            c.check("a configured key builds a request", false)
        }

        // An empty query is not sent at all: `query=` would be a search for the
        // empty string rather than a browse.
        c.equal("blank query is omitted", GlamaClient.queryItems(query: "  ", cursor: nil, limit: 10).count, 1)

        // MARK: Failure parsing

        // The real 401 body. Its message is the actionable half of the error, so
        // it has to survive into what the user reads.
        let unauthorized = Data("""
        {"error":{"code":"unauthorized","message":"This endpoint requires an API key. Create one at https://glama.ai/settings/api-keys."}}
        """.utf8)
        let unauthorizedError = GlamaClient.failure(status: 401, data: unauthorized, response: nil)
        if case .unauthorized(let message) = unauthorizedError {
            c.check("401 is unauthorized", true)
            c.check("401 keeps the API's own message", message?.contains("settings/api-keys") == true)
        } else {
            c.check("401 is unauthorized", false)
        }
        c.check(
            "401 description is readable",
            unauthorizedError.localizedDescription.contains("401")
                && !unauthorizedError.localizedDescription.contains("{\"error\"")
        )

        if let response = HTTPURLResponse(
            url: URL(fileURLWithPath: "/"), statusCode: 429, httpVersion: nil,
            headerFields: ["RateLimit-Reset": "37"]
        ) {
            let limited = GlamaClient.failure(status: 429, data: Data(), response: response)
            if case .rateLimited(let reset) = limited {
                c.equal("429 carries the reset window", reset, "37")
            } else {
                c.check("429 is rate limited", false)
            }
            c.check("429 description mentions the reset", limited.localizedDescription.contains("37"))
        } else {
            c.check("429 is rate limited", false)
        }

        // A proxy's HTML page is not the API's error document: the status is all
        // there is, and dumping the body at the user would hide that.
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        let gateway = GlamaClient.failure(status: 502, data: html, response: nil)
        if case .http(let status, let code, let message) = gateway {
            c.equal("unexpected status is kept", status, 502)
            c.nilValue("no error code is invented", code)
            c.nilValue("no message is invented", message)
        } else {
            c.check("unexpected status is an http error", false)
        }
        c.check("raw body is not shown to the user", !gateway.localizedDescription.contains("Bad Gateway"))

        return c.report()
    }

    /// The provider registry is data, and data of this shape fails quietly: a
    /// duplicate id silently shadows a provider, a missing base URL only shows up
    /// as a request to nowhere, and a botched migration loses a credential the
    /// user already supplied.
    static func providers() -> SelfTestReport {
        let c = Checker(suite: "providers")

        let all = ProviderRegistry.all
        c.check("registry is not empty", !all.isEmpty)
        c.equal(
            "provider ids are unique",
            Set(all.map(\.id)).count,
            all.count
        )
        c.check(
            "every provider has a name",
            all.allSatisfy { !$0.name.isEmpty }
        )
        // The custom entry is the only one allowed to have no endpoint: it is
        // defined by whatever the user types.
        c.check(
            "every built-in provider has a base URL",
            all.filter { !$0.isCustom }.allSatisfy { !$0.baseURL.isEmpty }
        )
        c.check(
            "the custom provider has no base URL of its own",
            all.first(where: \.isCustom)?.baseURL.isEmpty ?? false
        )
        c.check(
            "local runtimes need no key",
            all.filter { $0.baseURL.hasPrefix("http://localhost") }.allSatisfy { !$0.requiresKey }
        )
        c.check(
            "hosted providers declare at least one key variable",
            all.filter { $0.requiresKey && !$0.isCustom }.allSatisfy { !$0.envKeys.isEmpty }
        )

        // Every dialect the factory can build must be reachable from the
        // registry, or the backends are dead code.
        let usedFormats = Set(all.map(\.wireFormat))
        c.check(
            "all three dialects are represented (\(usedFormats.count))",
            usedFormats.count == WireFormat.allCases.count
        )

        c.equal(
            "an unknown provider id falls back",
            ProviderRegistry.provider(orFallback: "no-such-provider").id,
            ProviderRegistry.fallback.id
        )
        c.equal(
            "a known provider id resolves",
            ProviderRegistry.provider(orFallback: "anthropic").wireFormat,
            .anthropicMessages
        )
        c.equal(
            "google uses its own dialect",
            ProviderRegistry.provider(orFallback: "google").wireFormat,
            .googleGenerativeAI
        )
        c.nilValue("lookup of a missing id is nil", ProviderRegistry.provider(id: "nope"))

        // MARK: Per-provider storage

        var config = BudConfig()
        config.provider = "deepseek"
        config.model = "deepseek-v4-pro"
        config.provider = "anthropic"
        config.model = "claude-sonnet-4-6"
        c.equal(
            "each provider remembers its own model",
            config.providerModels,
            ["deepseek": "deepseek-v4-pro", "anthropic": "claude-sonnet-4-6"]
        )
        c.equal("the active model follows the provider", config.model, "claude-sonnet-4-6")
        config.provider = "deepseek"
        c.equal("switching back restores the model", config.model, "deepseek-v4-pro")

        config.apiKey = "sk-anthropic"
        config.baseURL = "https://proxy.example/v1"
        c.equal(
            "keys are stored per provider",
            config.providerKeys["deepseek"],
            "sk-anthropic"
        )
        c.equal(
            "base URLs are stored per provider",
            config.providerBaseURLs["deepseek"],
            "https://proxy.example/v1"
        )
        config.provider = "groq"
        c.equal("an unconfigured provider reports no key", config.apiKey, "")
        c.equal(
            "an unconfigured provider falls back to the registry URL",
            config.baseURL,
            ProviderRegistry.provider(orFallback: "groq").baseURL
        )
        c.equal(
            "an unconfigured provider suggests its default model",
            config.model,
            ProviderRegistry.provider(orFallback: "groq").defaultModel ?? ""
        )

        // MARK: Migration

        let legacy = BudConfigLoader.StoredConfig(
            model: "deepseek-v4-flash",
            apiKey: "sk-legacy",
            baseURL: "https://legacy.example/v1"
        )
        let migrated = BudConfigLoader.apply(legacy, to: BudConfig())
        c.equal("legacy key migrates to deepseek", migrated.providerKeys["deepseek"], "sk-legacy")
        c.equal(
            "legacy base URL migrates to deepseek",
            migrated.providerBaseURLs["deepseek"],
            "https://legacy.example/v1"
        )
        c.equal(
            "legacy model migrates to deepseek",
            migrated.providerModels["deepseek"],
            "deepseek-v4-flash"
        )

        // A config that already has per-provider values must not be overwritten
        // by the legacy fields, which are still present in the same file.
        var existing = BudConfig()
        existing.providerKeys["deepseek"] = "sk-new"
        let notClobbered = BudConfigLoader.apply(legacy, to: existing)
        c.equal(
            "migration does not overwrite a newer key",
            notClobbered.providerKeys["deepseek"],
            "sk-new"
        )

        // MARK: Credentials

        let descriptor = ProviderRegistry.provider(orFallback: "groq")
        let credentials = ProviderCredentials(apiKey: "k", baseURL: nil)
        c.equal(
            "credentials fall back to the provider URL",
            credentials.resolvedBaseURL(for: descriptor),
            descriptor.baseURL
        )
        let overridden = ProviderCredentials(apiKey: "k", baseURL: "https://proxy/v1")
        c.equal(
            "an override wins over the registry URL",
            overridden.resolvedBaseURL(for: descriptor),
            "https://proxy/v1"
        )
        // An empty override is what a cleared text field produces, and treating
        // it as a URL would send every request to nowhere.
        let blank = ProviderCredentials(apiKey: "k", baseURL: "   ")
        c.equal(
            "a blank override falls back rather than blanking the URL",
            blank.resolvedBaseURL(for: descriptor),
            descriptor.baseURL
        )

        // Regions are the one setting whose failure is silent and expensive: a
        // templated endpoint with an unsubstituted or substituted-wrong region
        // sends the request to a different continent, not to an error.
        guard let bedrock = ProviderRegistry.provider(id: "bedrock"),
              let bedrockClaude = ProviderRegistry.provider(id: "bedrock-claude") else {
            c.check("bedrock is in the registry", false)
            return c.report()
        }
        c.equal(
            "bedrock defaults to us-east-1",
            bedrock.baseURL(region: nil),
            "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1"
        )
        c.equal(
            "a chosen region is substituted into the host",
            bedrock.baseURL(region: "eu-west-2"),
            "https://bedrock-runtime.eu-west-2.amazonaws.com/openai/v1"
        )
        // Clouds add regions faster than Bud ships builds, so a region that is
        // not in the offered list must still be honoured. Substituting the
        // default instead would quietly bill the wrong region.
        c.equal(
            "an unlisted region is honoured rather than replaced",
            bedrock.baseURL(region: "ap-east-1"),
            "https://bedrock-runtime.ap-east-1.amazonaws.com/openai/v1"
        )
        c.equal(
            "whitespace is not a region",
            bedrock.baseURL(region: "   "),
            bedrock.baseURL(region: nil)
        )
        c.equal(
            "an untemplated provider ignores the region",
            ProviderRegistry.provider(orFallback: "deepseek").baseURL(region: "eu-west-2"),
            "https://api.deepseek.com/v1"
        )

        // The two Bedrock routes are only correct if the path Bud appends lands
        // on the path AWS documents. These pin the contract, since neither can be
        // exercised without AWS credentials.
        c.equal(
            "bedrock chat completions lands on the documented path",
            bedrock.baseURL(region: "us-east-1") + "/chat/completions",
            "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions"
        )
        c.equal(
            "bedrock Messages lands on the documented path",
            bedrockClaude.baseURL(region: "us-east-1") + "/v1/messages",
            "https://bedrock-runtime.us-east-1.amazonaws.com/anthropic/v1/messages"
        )
        c.equal(
            "bedrock Messages is an Anthropic provider",
            bedrockClaude.wireFormat,
            .anthropicMessages
        )
        c.equal(
            "both bedrock routes read the same key",
            bedrock.envKeys,
            bedrockClaude.envKeys
        )

        // The descriptor method is only correct if config actually routes through
        // it — that is the path the settings pane and the backends take.
        var regional = BudConfig()
        regional.provider = "bedrock"
        regional.providerRegions = ["bedrock": "eu-west-2"]
        c.equal(
            "config resolves the endpoint from the stored region",
            regional.baseURL,
            "https://bedrock-runtime.eu-west-2.amazonaws.com/openai/v1"
        )
        c.equal(
            "credentials carry the region through to the backend",
            regional.activeCredentials.resolvedBaseURL(for: bedrock),
            "https://bedrock-runtime.eu-west-2.amazonaws.com/openai/v1"
        )
        regional.providerBaseURLs = ["bedrock": "https://proxy.internal/v1"]
        c.equal(
            "an explicit URL override still beats the region",
            regional.baseURL,
            "https://proxy.internal/v1"
        )
        c.equal(
            "a provider with no region template keeps its fixed URL",
            BudConfig().baseURL,
            "https://api.deepseek.com/v1"
        )

        // A descriptor carries both a fixed URL and a template; if they disagree
        // the settings pane and the request would show different endpoints.
        for provider in ProviderRegistry.all where provider.regionTemplate != nil {
            guard let first = provider.regions.first else {
                c.check("\(provider.id) lists at least one region", false)
                continue
            }
            c.equal(
                "\(provider.id): the fixed URL matches the first region",
                provider.baseURL,
                provider.baseURL(region: first)
            )
        }

        // The whole point of the new shape is that it survives a save and a
        // reload. A projection that drops a field loses a credential silently and
        // only surfaces later as a 401, so this asserts the round trip directly.
        var saved = BudConfig()
        saved.provider = "anthropic"
        saved.providerKeys = ["anthropic": "sk-a", "deepseek": "sk-d"]
        saved.providerBaseURLs = ["custom": "https://proxy.example/v1"]
        saved.providerRegions = ["bedrock": "eu-west-2", "bedrock-claude": "ap-south-1"]
        saved.providerModels = ["anthropic": "claude-sonnet-4-6", "deepseek": "deepseek-v4-pro"]
        saved.glamaAPIKey = "glm-x"
        saved.reasoningEffort = "high"
        saved.temperature = 0.4
        saved.maxToolRounds = 12
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(BudConfigLoader.StoredConfig(from: saved)),
              let decoded = try? JSONDecoder().decode(BudConfigLoader.StoredConfig.self, from: data) else {
            c.check("a saved config decodes again", false)
            return c.report()
        }
        let restored = BudConfigLoader.apply(decoded, to: BudConfig())
        c.equal("round trip: provider", restored.provider, "anthropic")
        c.equal("round trip: keys", restored.providerKeys, saved.providerKeys)
        c.equal("round trip: base URLs", restored.providerBaseURLs, saved.providerBaseURLs)
        c.equal("round trip: regions", restored.providerRegions, saved.providerRegions)
        c.equal("round trip: models", restored.providerModels, saved.providerModels)
        c.equal("round trip: glama key", restored.glamaAPIKey, "glm-x")
        c.equal("round trip: active model", restored.model, "claude-sonnet-4-6")
        c.equal("round trip: reasoning effort", restored.reasoningEffort, "high")
        c.equal("round trip: temperature", restored.temperature, 0.4)
        c.equal("round trip: tool rounds", restored.maxToolRounds, 12)
        // The legacy fields must not be written back, or a migrated install would
        // carry two copies of the same credential for ever.
        c.nilValue("a saved config omits the legacy key", decoded.apiKey)
        c.nilValue("a saved config omits the legacy URL", decoded.baseURL)
        c.nilValue("a saved config omits the legacy model", decoded.model)

        return c.report()
    }

    // MARK: Truncation

    static func toolTruncation() -> SelfTestReport {
        let c = Checker(suite: "truncation")

        let huge = String(repeating: "x", count: 30_000)
        let bounded = ToolResult.ok(huge).modelFacingText(limit: 100)
        c.check("long output is bounded", bounded.count < 200)
        c.check("truncation is announced", bounded.contains("truncated"))

        let small = ToolResult.ok("short").modelFacingText(limit: 100)
        c.equal("short output untouched", small, "short")

        return c.report()
    }
}
