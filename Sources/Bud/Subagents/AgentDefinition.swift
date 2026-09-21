import Foundation

/// A named way of working that a request can be handed to.
///
/// Bud could already delegate, but only into an *anonymous* workstream: the model
/// invented a title and a prompt each time, and the subagent ran with every tool
/// the session had and the same model. Nothing could be offered, chosen, described,
/// or improved, because there was nothing to name.
///
/// An agent is that name. It carries the three things that actually change how a
/// slice of work turns out — what it is told, what it may touch, and which model it
/// thinks with — and it comes from wherever the capability already lives: Bud
/// itself, an installed skill, or a connected MCP server.
public struct AgentDefinition: Sendable, Identifiable, Equatable {
    /// Where the agent came from. Shown, because "where did this come from and who
    /// can change it" is the first question anyone asks of a list they did not write.
    public enum Origin: Sendable, Hashable {
        case builtin
        /// One of Bud's own agents.
        case skill(String)
        /// An MCP server, as a delegate scoped to that server's own tools.
        case server(String)
        case user

        public var label: String {
            switch self {
            case .builtin: return "Built in"
            case .skill(let name): return "Skill · \(name)"
            case .server(let name): return "MCP · \(name)"
            case .user: return "Yours"
            }
        }

        /// The grouping the panel uses, so the three kinds stay tellable apart
        /// however many of each there are.
        public var group: String {
            switch self {
            case .builtin, .user: return "Built in"
            case .skill: return "From your skills"
            case .server: return "From your MCP servers"
            }
        }

        public var symbol: String {
            switch self {
            case .builtin, .user: return "shippingbox"
            case .skill: return "book.closed"
            case .server: return "server.rack"
            }
        }
    }

    public var id: String { name }

    /// How the model refers to it, and how it is labelled. Lowercase, no spaces.
    public var name: String
    /// What it does *and when to hand it something*. This is the whole of what the
    /// model sees before choosing, so an agent described only by what it is about
    /// will not be picked at the right moment.
    public var summary: String
    /// The system prompt it runs with.
    public var instructions: String
    public var origin: Origin
    /// The tools it may use. `nil` means all of them; an empty array means none,
    /// which is a real thing to want for an agent that only reasons.
    public var tools: [String]?
    /// Overrides the session model. `nil` runs on whatever the session is using.
    public var model: String?
    /// Other names this agent answers to, from whoever wrote it.
    ///
    /// A skill's `triggers` are exactly this: the words its author says people
    /// use for it. Local matching is word overlap against the name and the
    /// summary, and the author knows the domain words those two miss — a W-9 is
    /// a PDF, and "w-9" appears in neither "pdf" nor "reads and fills PDF
    /// forms". Empty for the agents Bud ships and for servers, whose names,
    /// summaries and tool lists already say what they are.
    public var aliases: [String]
    public var symbol: String

    public init(
        name: String,
        summary: String,
        instructions: String,
        origin: Origin = .builtin,
        tools: [String]? = nil,
        model: String? = nil,
        aliases: [String] = [],
        symbol: String = "person.crop.circle"
    ) {
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.origin = origin
        self.tools = tools
        self.model = model
        self.aliases = aliases
        self.symbol = symbol
    }

    /// Whether this agent may call `tool`.
    ///
    /// A trailing `*` matches a prefix, which is how a server's whole surface is
    /// named without listing a hundred tools: `mcp__github__*`. Exact names
    /// otherwise, because a name that does not match is a silently missing tool and
    /// guessing at partial matches is how that goes unnoticed.
    public func allows(_ tool: String) -> Bool {
        guard let tools else { return true }
        return tools.contains { pattern in
            if pattern.hasSuffix("*") {
                return tool.hasPrefix(String(pattern.dropLast()))
            }
            return pattern == tool
        }
    }

    /// The tool list in words, for a row that has to say something short.
    ///
    /// A wildcard covers however many tools a server turns out to have, which is
    /// not knowable here — so it is described rather than counted. Counting it as
    /// one said "1 tool" for a server exposing twenty-one.
    public var toolSummary: String {
        guard let tools else { return "Every tool" }
        if tools.isEmpty { return "No tools — reasons only" }
        let exact = tools.filter { !$0.hasSuffix("*") }
        let patterns = tools.count - exact.count
        if patterns > 0, exact.isEmpty { return "Its own tools" }
        if patterns > 0 { return "\(exact.count) + its own" }
        return exact.count == 1 ? "1 tool" : "\(exact.count) tools"
    }

    /// Whether it can change anything. Read off the tool list rather than declared,
    /// because a declared flag can disagree with what the agent can actually do.
    public var isReadOnly: Bool {
        guard let tools else { return false }
        let writing = ["write_file", "run_shell"]
        return !tools.contains { pattern in
            writing.contains { pattern.hasPrefix($0) }
        }
    }
}

// MARK: - Where agents come from

/// The agents Bud ships, and the rules for turning a skill or a server into one.
public enum AgentLibrary {
    /// Three shapes of work that are actually different from each other.
    ///
    /// `scout` and `reviewer` hold the same tools and differ only in what they are
    /// asked for, which is the honest version of that distinction — what makes a
    /// reviewer a reviewer is the judgement, not the tool list. `builder` is the one
    /// that changes things, and the one that is closest to the session itself.
    public static let builtins: [AgentDefinition] = [
        AgentDefinition(
            name: "scout",
            summary: """
                Read-only investigation. Hand it a question about a codebase, a page or a data \
                source when you need the answer, not the material it came from.
                """,
            instructions: """
                You are a scout. You find things out and report them, and you have read-only \
                tools — nothing you do can change what you are looking at.

                Work until you can answer, not until you have looked. Follow the evidence to \
                where it actually is: read the file rather than the summary of it, search \
                before concluding there is nothing there, fetch the page rather than \
                recalling it.

                Every finding carries where it came from — a path and line, a URL. Say \
                plainly what you could not establish and what you did not look at. A \
                confident wrong answer is the only failure that matters here.
                """,
            tools: ["read_file", "list_files", "search_files", "web_fetch"],
            symbol: "magnifyingglass"
        ),
        AgentDefinition(
            name: "reviewer",
            summary: """
                Read-only judgement. Hand it something finished — a diff, a document, a \
                plan — when you want it checked before anyone else sees it.
                """,
            instructions: """
                You are a reviewer. Something is already done and your job is to find what \
                is wrong with it. You have read-only tools.

                Report defects, not preferences. For each: what is wrong, where, why it \
                matters, and what you would do instead. Rank them, worst first, and say \
                what you checked and found sound — a review that lists only problems \
                cannot be told apart from one that stopped early.

                If it is fine, say so plainly. Inventing faults to look thorough wastes \
                the reader's time in exactly the way a missed fault does.
                """,
            tools: ["read_file", "list_files", "search_files", "web_fetch"],
            symbol: "checkmark.seal"
        ),
        AgentDefinition(
            name: "builder",
            summary: """
                Does a piece of work end to end with every tool available, and reports what \
                it changed. Use it for a slice that has to be carried out, not just studied.
                """,
            instructions: """
                You are a builder. You were handed a piece of work and you do it, with every \
                tool this session has.

                Finish it rather than describing it. If a decision is genuinely the \
                caller's to make, make the conservative choice, note it, and carry on — \
                stopping to ask costs a whole round trip for something that could have \
                been said afterwards.

                Your final message is read by the agent that dispatched you, not by a \
                person: what you changed, where, how you know it works, and anything you \
                left undone.
                """,
            tools: nil,
            symbol: "hammer"
        ),
    ]

    /// A skill becomes a delegate when it says so.
    ///
    /// Opt-in rather than automatic: a skill is a body of instructions that can be
    /// loaded into a conversation, and most of them are better used there than as a
    /// separate workstream. A skill that declares `agent:` in its frontmatter is
    /// saying it is worth handing a whole slice to.
    ///
    /// The two fields it already has then mean what they say. `allowed-tools` was
    /// parsed and ignored from the day it was added; here it is the agent's tool
    /// list. The body is the instructions.
    public static func from(skill: Skill) -> AgentDefinition? {
        guard let summary = skill.delegation, !summary.isEmpty else { return nil }
        return AgentDefinition(
            name: skill.name,
            summary: summary,
            instructions: skill.instructions,
            origin: .skill(skill.name),
            tools: Skill.toolList(skill.allowedTools),
            model: skill.metadata["model"],
            // The words the author says people use for this skill are the same
            // words a task will be phrased in when it is handed over, so they
            // travel with the agent and widen what the local resolver matches.
            aliases: skill.triggerAliases,
            symbol: "book.closed"
        )
    }

    /// A connected server becomes a delegate scoped to its own tools.
    ///
    /// This is the case delegation exists for. A server that answers with three
    /// hundred rows of JSON is worth handing to something that reads all of it and
    /// comes back with the six lines that mattered — and the tools it may use are
    /// the server's, so it cannot wander off and do something else.
    ///
    /// The summary is a capability, built from the tools the server actually
    /// offers: a model answering "what does this agent do" reads the name, the
    /// tool names, and a concrete sentence from the first tool that described
    /// itself. Nothing is invented, so a server that has not connected yet — and
    /// therefore has no descriptions — keeps the routing-note wording.
    public static func from(server: MCPServerConfig, tools: [ToolDescriptor] = []) -> AgentDefinition {
        AgentDefinition(
            name: ToolNaming.sanitize(server.name.lowercased()),
            summary: Self.summary(for: server, tools: tools),
            instructions: """
                You are working with the \(server.name) MCP server, and its tools are the \
                only ones you have.

                Ask it what the task needs and no more. A server's answers are often \
                larger than the question — read all of what comes back, and report only \
                what the task asked for, in the shape it asked for it.

                If the server cannot answer, say what you asked and what it said. Do not \
                fill the gap with something you already knew.
                """,
            origin: .server(server.name),
            tools: ["\(server.namespace)__*"],
            model: nil,
            symbol: "server.rack"
        )
    }

    /// The capability line a server agent is described by.
    ///
    /// Shaped as the sanitised name, the first few tool names, and the first
    /// sentence of a tool description that says what it does — a capability, not
    /// a routing note. When the server is delegated the routing truth is appended,
    /// but the capability leads, because it is what "what does this agent do" is
    /// answered from. Kept under a hard budget: the description is paid for on
    /// every request, and a long one does not earn the tokens it costs.
    private static func summary(for server: MCPServerConfig, tools: [ToolDescriptor]) -> String {
        let name = ToolNaming.sanitize(server.name.lowercased())
        // A server that has not connected yet has no tools to describe. Inventing
        // a capability from nothing would be fabrication, so the routing-note
        // wording stays — the truth that is known before the server speaks.
        guard !tools.isEmpty else {
            return server.delegated
                ? "Answers from the \(server.name) server. Its tools are NOT in your tool list — delegating to this agent is the only way to reach them."
                : "Answers from the \(server.name) server, using only its own tools. Use it when the server returns more than you want to read."
        }

        let names = tools.prefix(3).map { bareToolName($0.name, namespace: server.namespace) }
        var line = "\(name): \(names.joined(separator: ", "))"
        if let sentence = concreteSentence(tools.map(\.description)) {
            line += " — \(sentence)"
        }
        // Said outright when the tools are not in the main agent's list: the
        // model otherwise spends a round discovering that a tool it expected is
        // not there, and may conclude the server is not connected. Kept whole
        // rather than clipped, so the capability part takes the remaining budget.
        let routing = server.delegated
            ? " Its tools are NOT in your tool list — delegating to this agent is the only way to reach them."
            : ""
        return cap(line, to: summaryBudget - routing.count) + routing
    }

    /// The hard ceiling on a server summary. "~220" in the brief: short enough
    /// that a handful of servers never rival a tool schema, long enough for a name,
    /// three tool names and a sentence.
    private static let summaryBudget = 220

    /// The bare tool name from a namespaced descriptor name: the server's own
    /// prefix is dropped because it is already the summary's lead.
    private static func bareToolName(_ namespaced: String, namespace: String) -> String {
        let prefix = namespace + "__"
        guard namespaced.hasPrefix(prefix) else { return namespaced }
        return String(namespaced.dropFirst(prefix.count))
    }

    /// The first sentence of the first description that says what a tool does,
    /// rather than a name repeated or the placeholder the MCP manager substitutes
    /// for a tool that described itself with nothing.
    private static func concreteSentence(_ descriptions: [String]) -> String? {
        for description in descriptions {
            guard let sentence = firstSentence(of: description) else { continue }
            let words = sentence.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 3 else { continue }
            if sentence.lowercased().contains("provided by the") { continue }
            return sentence
        }
        return nil
    }

    /// The first sentence of `text`, or `nil` when there is nothing to say. A
    /// period within the first few characters is an abbreviation, not the end of
    /// a sentence.
    private static func firstSentence(of text: String) -> String? {
        let flat = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard let stop = flat.firstIndex(of: ".") else { return flat }
        guard flat.distance(from: flat.startIndex, to: stop) > 8 else { return flat }
        return String(flat[...stop])
    }

    /// Clips `text` to `limit` characters on a word boundary, marking the cut.
    private static func cap(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(limit)) + "…" }
        let end = text.index(text.startIndex, offsetBy: limit)
        if let space = text[..<end].lastIndex(of: " ") {
            return String(text[..<space]) + "…"
        }
        return String(text[..<end]) + "…"
    }
}
