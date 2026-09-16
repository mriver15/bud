import CryptoKit
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
        conversations,
            selfUpdate,
            mcpConfigMapping,
            glamaMapping,
            npmResolution,
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
        c.equal("namespaced form", namespaced, "github_mcp__create_issue")
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
            ToolNaming.namespaced(server: config.name, tool: "t").contains("\(config.namespace)__"),
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

        // MARK: Tool selection

        let everything = MCPServerConfig(name: "s", command: "x")
        c.equal("no selection sends every tool", everything.sends(tool: "anything"), true)

        var narrowed = everything
        narrowed.enabledTools = ["a"]
        c.equal("a listed tool is sent", narrowed.sends(tool: "a"), true)
        c.equal("an unlisted tool is withheld", narrowed.sends(tool: "b"), false)

        // An empty selection is not the same as no selection. "Send none" and
        // "send everything" are both things a person means, and one value cannot
        // say both without turning one of them into the other.
        var none = everything
        none.enabledTools = []
        c.equal("an empty selection withholds everything", none.sends(tool: "a"), false)

        let encoded = try? JSONEncoder().encode(narrowed)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(MCPServerConfig.self, from: $0) }
        c.equal("a selection survives persistence", decoded?.enabledTools, ["a"])

        // Every server already on disk predates this key. Missing must mean
        // "everything", or upgrading would silently disable every MCP tool
        // someone had.
        let legacy = """
        {"id":"1","name":"old","transport":"stdio","args":[],"env":{},"headers":{},\
        "enabled":true,"autoStart":true}
        """
        let parsed = try? JSONDecoder().decode(MCPServerConfig.self, from: Data(legacy.utf8))
        c.equal("a config written before this existed sends everything", parsed?.sends(tool: "a"), true)

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
            let row = server.registryServer(option: nil)
            c.equal("server identity", row.name, "glama:modelcontextprotocol/filesystem")
            c.equal("server row title", row.title, "Filesystem")
            c.equal("server row listing is the API's url", row.websiteURL, server.listingURL)
            c.equal("server row repository", row.repositoryURL, "https://github.com/modelcontextprotocol/servers")
            c.nilValue("server with no thumbnail has no icon", row.iconURL)
            // Nothing confirmed yet, so nothing is offered: the row is browse-only
            // until npm has answered for its slug — see the `npm` suite for the
            // other half, where a confirmed package becomes the option.
            c.equal("server maps to no install options", row.options.count, 0)
            c.equal("the entry's npm question is its own identity", server.npmCandidate.identity, row.name)
        } else {
            c.check("directory server decodes", false)
        }

        // An entry whose server needs a key, in the shape Glama publishes it: a
        // JSON Schema whose `required` list is the names the server will not start
        // without.
        let keyedServer = decode(GlamaServer.self, """
        {
          "id": "srv_linear",
          "name": "Linear",
          "namespace": "linear",
          "slug": "linear",
          "url": "https://glama.ai/mcp/servers/linear/linear",
          "environmentVariablesJsonSchema": {
            "type": "object",
            "properties": {"LINEAR_API_KEY": {"type": "string"}},
            "required": ["LINEAR_API_KEY"]
          }
        }
        """)
        if let server = keyedServer {
            c.equal("a required key is read from the record's schema", server.requiredEnvironmentVariables, ["LINEAR_API_KEY"])
            c.equal("the key rides on the npm question", server.npmCandidate.requiredEnv, ["LINEAR_API_KEY"])
        } else {
            c.check("a record with an environment schema decodes", false)
        }

        // The schema an entry that takes no configuration publishes. `required`
        // says so outright, so the installed server must be offered no fields.
        let unconfigured = decode(GlamaServer.self, """
        {
          "id": "srv_plain",
          "name": "Plain",
          "namespace": "acme",
          "slug": "plain",
          "url": "https://glama.ai/mcp/servers/acme/plain",
          "environmentVariablesJsonSchema": {"properties": {}, "type": "object", "required": []}
        }
        """)
        if let server = unconfigured {
            c.check("a schema requiring nothing needs no fields", server.requiredEnvironmentVariables.isEmpty)
        } else {
            c.check("a record with an empty environment schema decodes", false)
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
            c.equal("nulled record still maps", server.registryServer(option: nil).name, "glama:n/odd")
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

    /// The npm lookup behind a Glama directory row.
    ///
    /// Every check here guards something that would otherwise be silent. A name
    /// that reaches a URL unescaped is a request for a different path; a document
    /// read as installable when it names nothing to run is an install that fails
    /// at launch; and a failure to reach npm remembered as "this server has no
    /// package" hides the package for the rest of the session.
    static func npmResolution() -> SelfTestReport {
        let c = Checker(suite: "npm")

        // MARK: The names a record is asked about

        c.equal(
            "a namespaced record is asked about twice",
            NpmResolver.Candidate(namespace: "mriver15", slug: "getcompetitive").identifiers,
            ["getcompetitive", "@mriver15/getcompetitive"]
        )
        c.equal(
            "a record with no namespace is asked about once",
            NpmResolver.Candidate(namespace: "", slug: "filesystem").identifiers,
            ["filesystem"]
        )

        // MARK: The URLs those names become

        let base = NpmResolver.defaultBaseURLString
        c.equal("the registry host", base, "https://registry.npmjs.org")
        c.equal(
            "a bare name is the whole path",
            NpmResolver.packageURL("getcompetitive", base: base)?.absoluteString,
            "https://registry.npmjs.org/getcompetitive"
        )
        // Asserted as host and path rather than as one string: the scope's `@` is
        // legal in a path, and whether it is spelled `@` or `%40` on the wire is
        // npm's business — both are the same document — but the segment it names
        // is not negotiable.
        let scopedURL = NpmResolver.packageURL("@mriver15/getcompetitive", base: base)
        c.equal("a scoped name is asked at the same host", scopedURL?.host, "registry.npmjs.org")
        c.equal("and scoped to one segment", scopedURL?.path, "/@mriver15/getcompetitive")
        // A slug is catalogue text, so the rule is what stands between it and the
        // path Bud requests: a query, a fragment, an escape or a second segment
        // would all name something other than the package.
        let refused = ["", ".", "..", "../-/user", "@../x", "@scope", "a/b/c", "pkg?write=true", "pkg#frag", "pkg/../other", "get competitive", "pkg%2fx"]
        for name in refused {
            c.nilValue("npm cannot have published this name: \(name)", NpmResolver.packageURL(name, base: base))
        }

        // MARK: Reading npm's answer

        // The document npm serves for the package this whole path exists for,
        // cut down to the two fields that decide: the latest release, and what it
        // runs. Anything larger is decoded past — see `PackageDocument`.
        let published = """
        {"_id":"getcompetitive","name":"getcompetitive","dist-tags":{"latest":"1.1.1"},
         "versions":{"1.1.1":{"name":"getcompetitive","version":"1.1.1","bin":{"getcompetitive":"dist/index.js"}}}}
        """
        c.equal(
            "a published package is a hit",
            NpmResolver.outcome(status: 200, body: Data(published.utf8), asking: "getcompetitive"),
            .package("getcompetitive")
        )
        c.equal(
            "the same document answers for its scoped name",
            NpmResolver.outcome(
                status: 200,
                body: Data(published.replacingOccurrences(of: "\"getcompetitive\"", with: "\"@mriver15/getcompetitive\"").utf8),
                asking: "@mriver15/getcompetitive"
            ),
            .package("@mriver15/getcompetitive")
        )
        c.equal(
            "a package with one executable is a hit",
            NpmResolver.outcome(
                status: 200,
                body: Data(#"{"name":"cli","dist-tags":{"latest":"2.0.0"},"versions":{"2.0.0":{"bin":"cli.js"}}}"#.utf8),
                asking: "cli"
            ),
            .package("cli")
        )

        // A real package with nothing to run — the shape of the library that
        // happens to share a name with a directory entry. `npx -y mongodb`
        // installs the package and then has no command to start, so the row is
        // browse-only rather than offering an install that cannot run.
        c.equal(
            "a package that runs nothing is a miss",
            NpmResolver.outcome(
                status: 200,
                body: Data(#"{"name":"mongodb","dist-tags":{"latest":"7.6.0"},"versions":{"7.6.0":{"bin":null}}}"#.utf8),
                asking: "mongodb"
            ),
            .absent
        )
        c.equal(
            "a package with no latest release is a miss",
            NpmResolver.outcome(
                status: 200,
                body: Data(#"{"name":"held","dist-tags":{},"versions":{"1.0.0":{"bin":"held.js"}}}"#.utf8),
                asking: "held"
            ),
            .absent
        )
        c.equal(
            "a 404 is a miss",
            NpmResolver.outcome(status: 404, body: Data(#"{"error":"Not found"}"#.utf8), asking: "nope"),
            .absent
        )
        c.equal(
            "npm's miss document is a miss even under a 200",
            NpmResolver.outcome(status: 200, body: Data(#"{"error":"Not found"}"#.utf8), asking: "nope"),
            .absent
        )
        // The other half: an answer Bud could not read is not a statement about
        // the package, and is not remembered as one.
        c.equal(
            "a 5xx is not an answer",
            NpmResolver.outcome(status: 503, body: Data(), asking: "nope"),
            .unavailable
        )
        c.equal(
            "a proxy's page is not a package",
            NpmResolver.outcome(status: 200, body: Data("<html>502 Bad Gateway</html>".utf8), asking: "nope"),
            .unavailable
        )
        c.equal(
            "a document naming another package is not an answer",
            NpmResolver.outcome(status: 200, body: Data(published.utf8), asking: "somethingelse"),
            .unavailable
        )

        // MARK: What is remembered

        // The memo is the reason a browse list of hundreds of rows is one round
        // trip per row for the life of the process rather than one per refresh.
        let hit = NpmResolver.Candidate(namespace: "mriver15", slug: "getcompetitive")
        let miss = NpmResolver.Candidate(namespace: "", slug: "nothing-by-that-name")
        let unreachable = NpmResolver.Candidate(namespace: "", slug: "npm-was-down")
        var memo = NpmResolver.Answers()
        c.nilValue("an unanswered candidate is open", memo.answer(for: hit))
        memo.record(.package("getcompetitive"), for: hit)
        c.equal("a hit is kept", memo.answer(for: hit), .package("getcompetitive"))
        memo.record(.absent, for: miss)
        c.equal("a miss is kept, or every refresh asks again", memo.answer(for: miss), .absent)
        memo.record(.unavailable, for: unreachable)
        c.nilValue("a failure to reach npm is not an answer", memo.answer(for: unreachable))
        c.nilValue("and it leaves the other candidate's answer alone", memo.answer(for: NpmResolver.Candidate(namespace: "", slug: "other")))

        // MARK: The row a hit becomes

        // The two catalogues build one option, so a package reachable from either
        // pane installs the same command. This is the other pane's mapping, driven
        // with the same identifier, rather than a copy of its expectations.
        let mine = RegistryInstallOption.npm("getcompetitive")
        c.equal("a hit installs over stdio", mine.transport, MCPTransportKind.stdio)
        c.equal("a hit installs with npx", mine.command, "npx")
        c.equal("a hit resolves the package at launch", mine.args, ["-y", "getcompetitive"])
        c.equal("a hit is identified by its package", mine.id, "npm:getcompetitive")
        c.equal("a hit's label is the command it runs", mine.label, "npx -y getcompetitive")

        let payload = RegistryServerPayload.Package(
            registryType: "npm", identifier: "getcompetitive", environmentVariables: nil
        )
        if let theirs = payload.installOption {
            c.equal("the registry builds the same option", mine, theirs)
        } else {
            c.check("the registry maps an npm package", false)
        }

        // And end to end: the record this exists for, through the same mapping a
        // Glama row takes, to the option an install is built from.
        let record = try? JSONDecoder().decode(GlamaServer.self, from: Data("""
        {
          "id": "t3cy2aisuk",
          "name": "getcompetitive",
          "namespace": "mriver15",
          "slug": "getcompetitive",
          "url": "https://glama.ai/mcp/servers/t3cy2aisuk",
          "attributes": ["hosting:local-only"],
          "repository": {"url": "https://github.com/mriver15/getcompetitive"},
          "environmentVariablesJsonSchema": {"properties": {}, "type": "object", "required": []}
        }
        """.utf8))
        if let record {
            let candidate = record.npmCandidate
            c.equal("the row's identity is the record's", candidate.identity, "glama:mriver15/getcompetitive")
            c.equal("the record's schema requires nothing", candidate.requiredEnv, [])
            let option = candidate.option(for: "getcompetitive")
            c.equal("the confirmed package becomes the row's option", option, mine)
            c.equal(
                "and the row installs as a local process",
                record.registryServer(option: option).options,
                [mine]
            )
        } else {
            c.check("the getcompetitive record decodes", false)
        }

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

    // MARK: Update

    /// The updater is the one subsystem whose mistakes install arbitrary code, so
    /// these pin decisions rather than plumbing: what counts as newer, what the
    /// signature actually covers, and which manifests are refused before a single
    /// byte is downloaded.
    static func selfUpdate() -> SelfTestReport {
        let c = Checker(suite: "update")

        let key = Curve25519.Signing.PrivateKey()
        let signingKey = key.publicKey.rawRepresentation.base64EncodedString()

        func manifest(
            schema: Int = UpdateManifest.supportedSchema,
            channel: String = "stable",
            version: String = "1.3.0",
            build: Int = 13,
            minOS: String = "26.0",
            notes: String = "Fixes the thing.",
            url: String = "https://github.com/mriver15/bud/releases/download/v1.3.0/Bud.zip",
            size: Int = 9_500_000,
            sha256: String = String(repeating: "a", count: 64),
            signature: String = ""
        ) -> UpdateManifest {
            UpdateManifest(
                schema: schema,
                channel: channel,
                version: version,
                build: build,
                minOS: minOS,
                published: "2026-08-01T10:00:00Z",
                notes: notes,
                url: url,
                size: size,
                sha256: sha256,
                signature: signature
            )
        }

        /// Signs a manifest that already carries every field, so the signed bytes
        /// are the ones a real release would cover.
        func signed(_ base: UpdateManifest) -> UpdateManifest {
            let signature = (try? key.signature(for: Data(base.signingPayload.utf8))) ?? Data()
            return manifest(
                schema: base.schema,
                channel: base.channel,
                version: base.version,
                build: base.build,
                minOS: base.minOS,
                notes: base.notes,
                url: base.url,
                size: base.size,
                sha256: base.sha256,
                signature: signature.base64EncodedString()
            )
        }

        func feed(channel: String = "stable", key: String) -> UpdateFeed {
            UpdateFeed(channel: channel, publicKey: key)
        }

        // MARK: Version ordering

        // Ordering is by build first, so the version string only ever breaks a
        // tie; a build number alone has to be able to decide an upgrade.
        c.check(
            "a higher build wins over a lower version string",
            BudVersion(version: "0.9", build: 12).isNewer(than: BudVersion(version: "2.0", build: 11))
        )
        c.check(
            "a lower build is never newer",
            !BudVersion(version: "9.9", build: 11).isNewer(than: BudVersion(version: "0.1", build: 12))
        )
        // The tie-break has to be numeric: "1.10" sorts before "1.9" as text, and
        // a lexical compare would refuse a legitimate upgrade for ever.
        c.check(
            "equal builds order versions numerically",
            BudVersion(version: "1.10.0", build: 7).isNewer(than: BudVersion(version: "1.9.0", build: 7))
        )
        c.check(
            "equal builds do not invert the comparison",
            !BudVersion(version: "1.9.0", build: 7).isNewer(than: BudVersion(version: "1.10.0", build: 7))
        )
        c.check(
            "the running release is not newer than itself",
            !BudVersion(version: "1.10.0", build: 7).isNewer(than: BudVersion(version: "1.10.0", build: 7))
        )

        // MARK: What the signature covers

        let base = manifest()
        let payload = base.signingPayload
        // The format tag is what stops an update signature being replayed as a
        // signature over some other Bud protocol.
        c.check("the payload names its own format", payload.hasPrefix("bud-update-v1\n"))

        // Every one of these fields decides whether code gets installed, so a
        // field that can change without changing the payload is a field an
        // attacker can rewrite in flight.
        let signedFields: [(String, UpdateManifest)] = [
            ("url", manifest(url: "https://github.com/mriver15/bud/releases/download/v1.3.0/Other.zip")),
            ("size", manifest(size: 1)),
            ("sha256", manifest(sha256: String(repeating: "b", count: 64))),
            ("build", manifest(build: 14)),
            ("version", manifest(version: "1.4.0")),
            ("channel", manifest(channel: "prerelease")),
            ("minOS", manifest(minOS: "26.1")),
        ]
        for (field, changed) in signedFields {
            c.check("changing \(field) changes the signed payload", changed.signingPayload != payload)
        }

        // `notes` is outside the signed bytes — markdown is not something the
        // signer should have to normalise — but its hash is inside, so the wording
        // the user reads cannot be rewritten after signing.
        let reworded = manifest(notes: "A completely different note.")
        let payloadLines = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rewordedLines = reworded.signingPayload
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let differing = zip(payloadLines, rewordedLines).filter { $0 != $1 }
        c.equal("a reworded note touches exactly one payload line", differing.count, 1)
        c.check(
            "the touched line is the notes hash",
            payloadLines.last?.hasPrefix("notes_sha256=") == true
                && rewordedLines.last != payloadLines.last
        )
        c.check(
            "the notes hash is the hash of the manifest's notes",
            payload.contains("notes_sha256=\(UpdateSignature.hexDigest(of: base.notes))")
        )

        // MARK: Real signatures

        func verificationFailure(_ candidate: UpdateManifest, using key: String) -> UpdateError? {
            do {
                try UpdateSignature.verify(candidate, publicKey: key)
                return nil
            } catch let error as UpdateError {
                return error
            } catch {
                return nil
            }
        }

        let genuine = signed(base)
        c.nilValue("a correctly signed manifest verifies", verificationFailure(genuine, using: signingKey))

        if let raw = Data(base64Encoded: genuine.signature) {
            var bytes = Array(raw)
            bytes[bytes.count / 2] ^= 0x01
            c.equal(
                "one flipped signature byte is refused",
                verificationFailure(
                    manifest(signature: Data(bytes).base64EncodedString()),
                    using: signingKey
                ),
                .signatureInvalid
            )
        } else {
            c.check("the signer produced a base64 signature", false)
        }

        c.equal(
            "a signature does not cover a tampered field",
            verificationFailure(
                manifest(sha256: String(repeating: "b", count: 64), signature: genuine.signature),
                using: signingKey
            ),
            .signatureInvalid
        )
        c.equal(
            "notes cannot be reworded after signing",
            verificationFailure(
                manifest(notes: "Rewritten in the middle.", signature: genuine.signature),
                using: signingKey
            ),
            .signatureInvalid
        )
        c.equal(
            "a signature that is not base64 is invalid",
            verificationFailure(manifest(signature: "!!!"), using: signingKey),
            .signatureInvalid
        )

        // An absent key is a refusal, not a skip: a build that cannot tell a real
        // manifest from a forged one must not install either.
        c.equal(
            "an absent key refuses rather than skipping the check",
            verificationFailure(genuine, using: ""),
            .signingKeyMissing
        )
        c.equal(
            "whitespace is not a key",
            verificationFailure(genuine, using: " \n "),
            .signingKeyMissing
        )
        c.equal(
            "a wrong-length key is malformed",
            verificationFailure(genuine, using: Data(repeating: 0x41, count: 31).base64EncodedString()),
            .signingKeyMalformed
        )
        c.equal(
            "a key that is not base64 is malformed",
            verificationFailure(genuine, using: "not a key"),
            .signingKeyMalformed
        )

        // MARK: The gates between a manifest and an install

        func refusal(
            _ candidate: UpdateManifest,
            feed: UpdateFeed,
            current: BudVersion = BudVersion(version: "1.2.0", build: 12),
            runningOS: String = "26.0"
        ) -> UpdateError? {
            do {
                try UpdateChecker.validate(candidate, feed: feed, current: current, runningOS: runningOS)
                return nil
            } catch let error as UpdateError {
                return error
            } catch {
                return nil
            }
        }

        let running = BudVersion(version: "1.2.0", build: 12)
        let stable = feed(key: signingKey)

        c.nilValue("a newer, signed, well-formed manifest is accepted", refusal(signed(manifest()), feed: stable))

        // Replaying the running release, or one before it, is how a stale feed
        // would otherwise reinstall over whatever the user is running.
        c.equal(
            "replaying the running release is refused",
            refusal(signed(manifest(version: running.version, build: running.build)), feed: stable),
            .notNewer(current: running.display, offered: running.display)
        )
        c.equal(
            "an older version on the same build is refused",
            refusal(signed(manifest(version: "1.1.9", build: running.build)), feed: stable),
            .notNewer(current: running.display, offered: "1.1.9 · build 12")
        )
        c.equal(
            "a lower build is refused even with a higher version string",
            refusal(signed(manifest(version: "9.9.9", build: 11)), feed: stable),
            .notNewer(current: running.display, offered: "9.9.9 · build 11")
        )
        c.equal(
            "a prerelease is refused on the stable feed",
            refusal(signed(manifest(channel: "prerelease")), feed: stable),
            .channelMismatch(expected: "stable", offered: "prerelease")
        )
        // Taking a stable build while on the prerelease channel is an upgrade out
        // of the channel, not a mismatch.
        c.nilValue(
            "a prerelease feed accepts a stable manifest",
            refusal(signed(manifest()), feed: feed(channel: "prerelease", key: signingKey))
        )
        c.equal(
            "a schema this build cannot read is refused",
            refusal(signed(manifest(schema: UpdateManifest.supportedSchema + 1)), feed: stable),
            .unsupportedSchema(UpdateManifest.supportedSchema + 1)
        )
        c.equal(
            "an OS below the manifest's minimum is refused",
            refusal(signed(manifest(minOS: "26.1")), feed: stable, runningOS: "26.0"),
            .unsupportedOS(required: "26.1", running: "26.0")
        )
        c.equal(
            "plain HTTP off the machine is refused",
            refusal(signed(manifest(url: "http://github.com/mriver15/bud/Bud.zip")), feed: stable),
            .insecureURL("http://github.com/mriver15/bud/Bud.zip")
        )
        c.equal(
            "a host Bud does not download from is refused",
            refusal(signed(manifest(url: "https://evil.example/x.zip")), feed: stable),
            .hostNotAllowed("evil.example")
        )
        c.equal(
            "a URL that does not parse is refused",
            refusal(signed(manifest(url: "not a url")), feed: stable),
            .insecureURL("not a url")
        )
        // Userinfo and suffixed hosts are how a URL check that looks for the
        // allowed name in the string instead of in the host gets walked past.
        c.equal(
            "an allowed name in the userinfo does not admit another host",
            refusal(signed(manifest(url: "https://github.com@evil.example/x.zip")), feed: stable),
            .hostNotAllowed("evil.example")
        )
        c.equal(
            "a host that merely ends in an allowed name is refused",
            refusal(signed(manifest(url: "https://github.com.evil.example/x.zip")), feed: stable),
            .hostNotAllowed("github.com.evil.example")
        )
        // Plain HTTP is allowed back to this machine only, which is how the update
        // path is exercised end to end against a local feed.
        c.nilValue(
            "plain HTTP to loopback is accepted",
            refusal(signed(manifest(url: "http://127.0.0.1:8099/Bud.zip")), feed: stable)
        )
        // The signature is verified first because until it passes, every other
        // field is attacker-written text — so a manifest that would also fail a
        // later gate has to fail as unsigned.
        c.equal(
            "an unsigned manifest fails on the signature, not a later gate",
            refusal(manifest(channel: "prerelease"), feed: stable),
            .signatureInvalid
        )

        // MARK: OS comparison

        c.check("26.10 satisfies a 26.9 requirement", UpdateChecker.osAtLeast("26.9", running: "26.10"))
        c.check("26.0 does not satisfy a 26.1 requirement", !UpdateChecker.osAtLeast("26.1", running: "26.0"))
        c.check("26.10 does not satisfy a 26.11 requirement", !UpdateChecker.osAtLeast("26.11", running: "26.10"))
        c.check("an equal version satisfies the requirement", UpdateChecker.osAtLeast("26.10", running: "26.10"))
        c.check("a bare major is satisfied by any minor of it", UpdateChecker.osAtLeast("26", running: "26.0"))
        c.check("a higher major is refused", !UpdateChecker.osAtLeast("27.0", running: "26.10"))
        c.check("a lower major is accepted", UpdateChecker.osAtLeast("25.6", running: "26.0"))

        // MARK: Bundle identity

        // Anything the installer is about to move into place has to prove it is
        // Bud, and a directory that cannot answer that question must be refused
        // rather than read as an empty identifier.
        func refusesUnreadableBundle(_ bundle: URL) -> Bool {
            do {
                _ = try UpdateInstaller.bundleIdentifier(of: bundle)
                return false
            } catch let error as UpdateError {
                if case .archiveShape = error { return true }
                return false
            } catch {
                return false
            }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bud-selftest-bundles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        func makeBundle(named name: String, identifier: String?) -> URL {
            let bundle = scratch.appendingPathComponent(name)
            let contents = bundle.appendingPathComponent("Contents")
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let entry = identifier.map { "<key>CFBundleIdentifier</key><string>\($0)</string>" } ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\(entry)</dict></plist>
            """
            try? Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
            return bundle
        }

        let plainDirectory = scratch.appendingPathComponent("plain-directory")
        try? FileManager.default.createDirectory(at: plainDirectory, withIntermediateDirectories: true)

        c.check(
            "a directory that is not a bundle is refused",
            refusesUnreadableBundle(plainDirectory)
        )
        c.check(
            "a bundle with no CFBundleIdentifier is refused",
            refusesUnreadableBundle(makeBundle(named: "Unnamed.app", identifier: nil))
        )
        // The refusal above is only meaningful if a real bundle still reports its
        // identity — otherwise the installer would reject every update.
        c.equal(
            "a real bundle reports its identifier",
            try? UpdateInstaller.bundleIdentifier(of: makeBundle(named: "Bud.app", identifier: "com.mriver15.bud")),
            "com.mriver15.bud"
        )

        return c.report()
    }


    /// The transcript is the only thing Bud writes down that a user would
    /// notice losing, and every failure here is silent: a coding mistake
    /// produces a database that opens, queries, and is subtly not what was
    /// there.
    ///
    /// Runs against a database of its own. Pointing the store at the real one
    /// would make the suite write into the user's history and then assert
    /// against whatever it had left there on the previous run.
    static func conversations() -> SelfTestReport {
        let c = Checker(suite: "conversations")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bud-selftest-\(UUID().uuidString)", isDirectory: true)
        let previous = BudDatabase.shared
        BudDatabase.shared = BudDatabase(url: directory.appendingPathComponent("test.sqlite"))
        defer {
            BudDatabase.shared = previous
            try? FileManager.default.removeItem(at: directory)
        }

        c.check("the database opens", BudDatabase.shared.isOpen)

        let call = ToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":\"/tmp/x\"}")
        let turn = Turn(
            id: "turn_1",
            role: .assistant,
            segments: [
                .reasoning(id: "s1", text: "thinking"),
                .text(id: "s2", text: "here is the answer"),
                .tool(id: "s3", call: call, providerName: "Files", state: .succeeded,
                      resultText: "contents", ui: nil),
                .notice(id: "s4", text: "heads up", kind: .warning),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // MARK: Titles

        func titled(_ text: String) -> String {
            Conversation.title(from: [Turn(role: .user, segments: [.text(id: "s", text: text)])])
        }

        c.equal("a title comes from the first thing the user said",
                titled("how do I do X"), "how do I do X")
        c.equal("a long title breaks on a word",
                titled(String(repeating: "word ", count: 40)),
                String(repeating: "word ", count: 9).trimmingCharacters(in: .whitespaces) + "…")
        c.equal("a title flattens newlines", titled("first\nsecond"), "first second")
        c.equal("an empty conversation still has a name", Conversation.title(from: []), "New chat")

        // MARK: Round trip

        BudStore.save(Conversation(
            id: "conv_1", title: "kept", turns: [turn],
            messages: [ChatMessage(role: .assistant, content: "hello")]
        ))
        // A question and its answer, as a completed run leaves them. The first
        // version of this feature saved only one of the pair, because the save
        // was driven from the wrong place.
        BudStore.save(Conversation(
            id: "conv_pair", title: "pair",
            turns: [
                Turn(role: .user, segments: [.text(id: "q", text: "question")]),
                Turn(role: .assistant, segments: [.text(id: "a", text: "answer")]),
            ]
        ))
        let loaded = BudStore.load(id: "conv_1")

        c.check("the conversation comes back", loaded != nil)
        c.equal("both sides of a turn pair are stored",
                BudStore.load(id: "conv_pair")?.turns.count, 2)
        c.equal("with its turn", loaded?.turns.count, 1)
        c.equal("and every segment of it", loaded?.turns.first?.segments.count, 4)
        c.equal("and the model-facing history", loaded?.messages.count, 1)

        if case .tool(let id, let restoredCall, let provider, let state, let result, _)? = loaded?.turns.first?.segments[2] {
            c.equal("a tool segment keeps its id", id, "s3")
            c.equal("its call, verbatim", restoredCall, call)
            c.equal("its provider", provider, "Files")
            c.equal("its state", state, .succeeded)
            c.equal("its result", result, "contents")
        } else {
            c.check("the tool segment is a tool segment", false)
        }
        if case .notice(_, let text, let kind)? = loaded?.turns.first?.segments[3] {
            c.equal("a notice keeps its kind", kind, .warning)
            c.equal("and its text", text, "heads up")
        } else {
            c.check("the notice segment is a notice", false)
        }

        // MARK: The list

        BudStore.save(Conversation(
            id: "conv_0", title: "older",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
            turns: [Turn(role: .user, segments: [.text(id: "a", text: "a much older question about otters")])]
        ))
        let listed = BudStore.list()
        c.equal("the list has all three", listed.count, 3)
        // The ordering contract, not a particular row: asserting which id lands
        // first makes the check fail whenever an unrelated fixture is added,
        // which is how it failed.
        c.check("newest first",
                zip(listed, listed.dropFirst()).allSatisfy { $0.updatedAt >= $1.updatedAt })
        let kept = listed.first { $0.id == "conv_1" }
        c.equal("with a turn count", kept?.turnCount, 1)
        c.check("and a preview of the last thing said", !(kept?.preview.isEmpty ?? true))

        c.equal("search finds a conversation by title",
                BudStore.search("kept").map(\.id), ["conv_1"])
        c.equal("and by what was said in it",
                BudStore.search("otters").map(\.id), ["conv_0"])
        c.equal("a query too short to mean anything matches nothing",
                BudStore.search("ot").count, 0)

        // MARK: Sanitising

        BudStore.save(Conversation(id: "conv_2", turns: [
            Turn(role: .assistant, segments: [
                .text(id: "t", text: "half an answer"),
                .tool(id: "u", call: call, providerName: "Files", state: .running,
                      resultText: nil, ui: nil),
            ], isStreaming: true)
        ]))
        let interrupted = BudStore.load(id: "conv_2")?.turns.first

        c.equal("a turn saved mid-stream does not come back streaming", interrupted?.isStreaming, false)
        if case .tool(_, _, _, let state, _, _)? = interrupted?.segments[1] {
            c.equal("a tool that was still running comes back failed", state, .failed)
        } else {
            c.check("the interrupted tool segment survived", false)
        }

        let huge = String(repeating: "x", count: BudStore.resultTextLimit + 500)
        BudStore.save(Conversation(id: "conv_3", turns: [
            Turn(role: .assistant, segments: [
                .tool(id: "v", call: call, providerName: "Shell", state: .succeeded,
                      resultText: huge, ui: nil)
            ])
        ]))
        if case .tool(_, _, _, _, let result, _)? = BudStore.load(id: "conv_3")?.turns.first?.segments[0] {
            c.check("an enormous tool result is truncated on the way to disk",
                    (result?.count ?? 0) < huge.count)
            c.check("and says so rather than ending mid-sentence",
                    result?.contains("characters not saved") ?? false)
        } else {
            c.check("the bulky tool segment survived", false)
        }

        // MARK: Deletion and cascades

        BudStore.delete(id: "conv_3")
        c.nilValue("a deleted conversation is gone", BudStore.load(id: "conv_3"))
        c.check("and is not listed", !BudStore.list().contains { $0.id == "conv_3" })

        // MARK: Open conversation

        BudStore.setCurrentConversation("conv_1")
        c.equal("the open conversation is remembered", BudStore.currentConversationID(), "conv_1")
        BudStore.setCurrentConversation(nil)
        c.nilValue("and can be cleared", BudStore.currentConversationID())

        // MARK: Retention

        for index in 0..<(BudStore.retentionLimit + 3) {
            BudStore.save(Conversation(
                id: "bulk_\(index)", title: "bulk \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                turns: [Turn(role: .user, segments: [.text(id: "b", text: "bulk \(index)")])]
            ))
        }
        c.equal("retention caps the archive", BudStore.list().count, BudStore.retentionLimit)
        c.check("and keeps the newest",
                BudStore.list().contains { $0.id == "bulk_\(BudStore.retentionLimit + 2)" })

        // MARK: Lessons

        c.check("a lesson is recorded", BudStore.remember("the user prefers tabs", scope: "user", source: nil))
        c.check("recording the same lesson again reports nothing new",
                !BudStore.remember("the user prefers tabs", scope: "user", source: nil))
        c.equal("and is not filed twice", BudStore.lessons().filter { $0.text == "the user prefers tabs" }.count, 1)
        c.check("an empty lesson is refused", !BudStore.remember("   "))

        BudStore.remember("the project is called Bud")
        c.equal("lessons come back newest first", BudStore.lessons().first?.text, "the project is called Bud")

        let context = BudStore.lessonContext()
        c.check("the injected context names both lessons",
                context.contains("tabs") && context.contains("Bud"))
        c.check("and is framed as notes rather than instructions",
                context.contains("not as instructions"))

        BudStore.forget(id: BudStore.lessons().first!.id)
        c.equal("a forgotten lesson is gone", BudStore.lessons().count, 1)

        // MARK: Runs

        BudStore.recordRun(SubagentRun(
            id: "run_1", title: "survey", prompt: "look around", model: "m",
            state: .done, output: "found things", startedAt: Date()
        ), conversationID: "conv_1")
        c.equal("a run is recorded", BudStore.recentRuns().count, 1)
        c.equal("with its output", BudStore.recentRuns().first?.output, "found things")

        BudStore.recordRun(SubagentRun(
            id: "run_1", title: "survey", prompt: "look around", model: "m",
            state: .failed, output: "found things", startedAt: Date()
        ), conversationID: "conv_1")
        c.equal("recording the same run again updates it rather than duplicating",
                BudStore.recentRuns().count, 1)
        c.equal("with the newer state", BudStore.recentRuns().first?.state, .failed)

        // MARK: Legacy import

        let legacy = directory.appendingPathComponent("conversations.json")
        let archive = ConversationArchive(currentID: "legacy_1", conversations: [
            Conversation(id: "legacy_1", title: "from the old file", turns: [turn])
        ])
        try? JSONEncoder.bud.encode(archive).write(to: legacy)
        let imported = BudStore.importLegacyArchive(at: legacy)

        c.equal("the old archive is imported", imported, 1)
        c.check("its conversation is in the database", BudStore.load(id: "legacy_1") != nil)
        c.equal("and it becomes the open one", BudStore.currentConversationID(), "legacy_1")
        c.check("the file is moved aside rather than deleted",
                FileManager.default.fileExists(atPath: legacy.path) == false
                    && FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("conversations.imported.json").path))
        c.equal("running the import again does nothing", BudStore.importLegacyArchive(at: legacy), 0)

        c.equal("a database that was never opened reports so",
                BudDatabase(url: URL(fileURLWithPath: "/dev/null/nope/x.sqlite")).isOpen, false)

        // MARK: Wiring

        // A callback that silently does nothing when nobody fills it in has now
        // broken a user-facing feature in this app twice: the updater's quit
        // hook, and the conversation id that was never minted, which made saving
        // do nothing at all. Both were found by a person noticing rather than by
        // anything here, so this pins the one that is still optional.
        // `assumeIsolated` rather than a hop: the suite runs from `main.swift`'s
        // top-level code, which is the main actor, and a check that had to await
        // its way back would be a different check.
        let turnHookSet = MainActor.assumeIsolated { AppModel().runtime.onTurnFinished != nil }
        c.check("a finished turn reaches the thing that saves it", turnHookSet)

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
