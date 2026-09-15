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
            mcpConfigMapping,
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
        func d(line: String) -> StreamEvent? { DeepSeekClient.decode(line: line) }

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
        let combined = DeepSeekClient.decodeEvents(
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
        let usageOnly = DeepSeekClient.decodeEvents(
            line: #"data: {"usage":{"prompt_tokens":7,"completion_tokens":2}}"#
        )
        c.equal("usage-only frame is emitted", usageOnly.count, 1)

        // Several calls can be pipelined into one frame; each is its own call.
        let multi = DeepSeekClient.decodeEvents(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"x","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"y","arguments":"{}"}}]}}]}"#
        )
        c.equal("pipelined tool calls all emitted", multi.count, 2)

        return c.report()
    }

    // MARK: Wire format

    static func chatWireFormat() -> SelfTestReport {
        let c = Checker(suite: "wire")

        let plain = ChatMessage(role: .user, content: "hi").wireRepresentation
        c.equal("role", plain["role"]?.stringValue, "user")
        c.equal("content", plain["content"]?.stringValue, "hi")
        c.nilValue("no tool_calls on plain message", plain["tool_calls"])

        let toolCall = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Paris"}"#)]
        ).wireRepresentation
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
            .wireRepresentation
        c.nilValue("reasoning not echoed", withReasoning["reasoning_content"])
        c.check("reasoning text absent", !withReasoning.encodedString().contains("secret"))

        let toolResult = ChatMessage(
            role: .tool, content: "18C", toolCallID: "call_1", name: "get_weather"
        ).wireRepresentation
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
