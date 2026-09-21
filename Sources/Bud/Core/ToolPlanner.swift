import Foundation

/// Everything the planner needs to decide which tools a turn offers.
///
/// Built fresh at request time: the query and recent tools come from the
/// runtime's own history, the surface and attachments from the panel, and the
/// connected servers from the registry. Keeping it a plain value type means the
/// planner stays pure and the wiring stays one place.
public struct ToolPlanningContext: Sendable {
    public var query: String = ""
    public var surface: String?
    public var attachmentPaths: [String] = []
    public var recentToolNames: [String] = []
    public var connectedServers: [String] = []

    public init(
        query: String = "",
        surface: String? = nil,
        attachmentPaths: [String] = [],
        recentToolNames: [String] = [],
        connectedServers: [String] = []
    ) {
        self.query = query
        self.surface = surface
        self.attachmentPaths = attachmentPaths
        self.recentToolNames = recentToolNames
        self.connectedServers = connectedServers
    }
}

/// One tool that did not make the plan, and why. `name` and `providerName`
/// together are how the model learns what exists elsewhere; `why` is how it knows
/// whether naming it would help.
public struct ToolSummary: Sendable, Equatable {
    public let name: String
    public let providerName: String
    public let why: String

    public init(name: String, providerName: String, why: String) {
        self.name = name
        self.providerName = providerName
        self.why = why
    }
}

/// The outcome of planning one turn: what is offered, what is held back, and a
/// sentence that says so.
public struct ToolPlan: Sendable {
    public let descriptors: [ToolDescriptor]
    public let omitted: [ToolSummary]
    public let reason: String

    public init(descriptors: [ToolDescriptor], omitted: [ToolSummary], reason: String) {
        self.descriptors = descriptors
        self.omitted = omitted
        self.reason = reason
    }
}

/// Chooses the tools one turn offers.
///
/// The point is the large inventory: a server that contributes two hundred tools
/// is mostly omitted, because a turn that carries all of them pays for a surface
/// it uses two tools of. The planner keeps an always-on core for recovery and
/// discovery, promotes whole provider groups when the turn names one, and records
/// everything else so the model still knows the rest exists.
public enum ToolPlanner {
    /// Recovery and discovery primitives. Always offered, whatever the turn: a
    /// model that loses these cannot find what it has already been told or spill
    /// what it has already read.
    ///
    /// `spawn_subagents` is the delegation entry point — the one tool whose
    /// schema carries the roster of what a turn can be handed to. A connected
    /// MCP server is reachable *only* through its agent, so leaving this tool
    /// out is how a capability stays invisible even while connected: the query
    /// matches no intent, the plan offers only the recovery tools, and the model
    /// never learns the server exists.
    ///
    /// `render_ui` and `find_image` are the presentation group. The decision to
    /// draw a surface is made while the answer is being composed, not while the
    /// question is being asked: a query asking for a comparison or a status
    /// report names no "render" word an intent signal could match, so promotion
    /// can never reliably offer them. They must simply always be there. Their
    /// schemas are the largest in the inventory — the honest price of an answer
    /// that can always choose to look like one.
    public static let alwaysOnCore = [
        "skill", MemoryToolsProvider.toolName, "read_stored", "spawn_subagents",
        GenUIToolProvider.renderToolName, GenUIToolProvider.findToolName,
    ]

    /// The file-reading tools a dropped attachment may justify. Shell and write
    /// are deliberately absent: dropping a file is a request to read it, not a
    /// licence to run commands or overwrite anything.
    public static let attachmentTools = ["read_file", "search_files", "list_files"]

    /// The browser tools' provider, promoted when the turn reads as "go look".
    static let browserProviderName = "Browser"

    /// The surface whose selection alone means browsing.
    static let browserSurfaceID = "browser"

    public static func plan(
        context: ToolPlanningContext,
        descriptors: [ToolDescriptor],
        cap: Int = 12
    ) -> ToolPlan {
        let cap = max(1, cap)
        let query = context.query.lowercased()

        var byName: [String: ToolDescriptor] = [:]
        var byGroup: [String: [ToolDescriptor]] = [:]
        for descriptor in descriptors {
            byName[descriptor.name] = descriptor
            byGroup[descriptor.providerName, default: []].append(descriptor)
        }

        let browserIntent = hasBrowserIntent(query: query, surface: context.surface)

        // Promoted groups, in the order they were first matched. A group is
        // atomic: naming one tool of a server brings the server's whole surface,
        // because the model cannot guess which tool it is about to need.
        var promotedGroups: [String] = []
        var promotedGroupsSet: Set<String> = []

        func promoteGroup(_ group: String) {
            guard !group.isEmpty, promotedGroupsSet.insert(group).inserted else { return }
            promotedGroups.append(group)
        }

        if browserIntent { promoteGroup(Self.browserProviderName) }

        for descriptor in descriptors {
            let namedTool = matchesQuery(name: descriptor.name, query: query)
            let namedServer = matchesQuery(name: descriptor.providerName, query: query)
            if namedTool || namedServer { promoteGroup(descriptor.providerName) }
        }
        for server in context.connectedServers where matchesQuery(name: server, query: query) {
            promoteGroup(server)
        }

        // Tools used in the previous two rounds stay available: what was just
        // used is the best guess at what is about to be.
        for name in context.recentToolNames {
            if let descriptor = byName[name] { promoteGroup(descriptor.providerName) }
        }

        let attachmentPromoted = context.attachmentPaths.isEmpty ? [] : Self.attachmentTools

        // Assemble, always-on core first, then promoted groups, then attachments.
        var included: [ToolDescriptor] = []
        var includedNames: Set<String> = []

        func add(_ descriptor: ToolDescriptor) {
            guard includedNames.insert(descriptor.name).inserted else { return }
            included.append(descriptor)
        }

        for name in Self.alwaysOnCore {
            if let descriptor = byName[name] { add(descriptor) }
        }
        for group in promotedGroups {
            for descriptor in byGroup[group] ?? [] { add(descriptor) }
        }
        for name in attachmentPromoted {
            if let descriptor = byName[name] { add(descriptor) }
        }

        let kept = Array(included.prefix(cap))
        let keptNames = Set(kept.map(\.name))

        var omitted: [ToolSummary] = []
        for descriptor in descriptors where !keptNames.contains(descriptor.name) {
            omitted.append(
                ToolSummary(
                    name: descriptor.name,
                    providerName: descriptor.providerName,
                    why: omitReason(for: descriptor, browserIntent: browserIntent)
                )
            )
        }

        return ToolPlan(
            descriptors: kept,
            omitted: omitted,
            reason: reason(kept: kept.count, total: descriptors.count, omitted: omitted)
        )
    }

    /// The fail-open step: given a plan and the tool name the model actually
    /// tried, a plan with that tool's provider group added. `nil` when the name
    /// is unknown to the full inventory — after `toolAliases` — in which case
    /// the call is a hallucination rather than something the planner held back.
    ///
    /// Names the model reaches for by habit from its training in other agents,
    /// mapped to the tool Bud actually has. The fail-open path consults this
    /// before deciding a name is unknown: a guessed name that points at a real
    /// capability should resolve, not hard-fail.
    ///
    /// With `capabilities` (the contextCompilerV2 path), capability language
    /// resolves too: a call naming a concept — "chart", "pokemon" — finds the
    /// group that holds it and offers that group, the same way a guessed tool
    /// name does.
    public static let toolAliases: [String: String] = [
        "web_search": "web_fetch",
        "search_web": "web_fetch",
        "web_browse": "web_fetch",
        // The browser was thirteen tools before it was three. A model that
        // reaches for one of the old names has the right intent and the wrong
        // vocabulary, so the alias resolves it to the tool that does the job and
        // the group is offered rather than the call hard-failing.
        "browser_snapshot": "browser_read",
        "browser_click": "browser_act",
        "browser_type": "browser_act",
        "browser_hover": "browser_act",
        "browser_select": "browser_act",
        "browser_press": "browser_act",
        "browser_scroll": "browser_act",
        "browser_wait": "browser_act",
        "browser_back": "browser_act",
        "browser_console": "browser_read",
        "browser_screenshot": "browser_read",
    ]

    public static func expanded(
        for plan: ToolPlan,
        requestedTool: String,
        allDescriptors: [ToolDescriptor],
        capabilities: CapabilityIndex? = nil
    ) -> ToolPlan? {
        let resolved = toolAliases[requestedTool] ?? requestedTool

        // A guessed tool name or a capability phrase the model reached for:
        // either way the answer is the group that holds it.
        let named: ToolDescriptor?
        var capabilityNote: String?
        if let requested = allDescriptors.first(where: { $0.name == resolved }) {
            named = requested
        } else if let index = capabilities,
                  let match = index.resolve(resolved, limit: 1).first,
                  case .toolGroup = match.capability.activation,
                  match.confidence >= 0.55,
                  let inGroup = allDescriptors.first(where: { $0.providerName == match.capability.id }) {
            named = inGroup
            capabilityNote = "the '\(match.capability.id)' capability (\(match.reason))"
        } else {
            named = nil
        }
        guard let requested = named else { return nil }
        let group = requested.providerName
        let existingNames = Set(plan.descriptors.map(\.name))
        let additions = allDescriptors.filter { $0.providerName == group && !existingNames.contains($0.name) }
        guard !additions.isEmpty else { return nil }

        let addedNames = Set(additions.map(\.name))
        let stillOmitted = plan.omitted.filter { !addedNames.contains($0.name) }

        let called = resolved == requestedTool ? "'\(requestedTool)'" : "'\(requestedTool)' (as \(resolved))"
        let via = capabilityNote.map { ", which names \($0)" } ?? ""
        return ToolPlan(
            descriptors: plan.descriptors + additions,
            omitted: stillOmitted,
            reason: "The model called \(called)\(via), which was held back; the "
                + "'\(group)' group is now offered and the round is retried."
        )
    }

    /// Whether the turn reads as "go and look at a page".
    static func hasBrowserIntent(query: String, surface: String?) -> Bool {
        if surface == Self.browserSurfaceID { return true }
        if containsURL(query) { return true }
        // "search the web" and friends are deliberate: the model's training makes
        // it reach for web tools by the name other agents use, and a query phrased
        // this way is the one that must offer them. A false positive only promotes
        // a group the cap still bounds; a false negative leaves the model blind.
        for signal in ["browse", "open site", "look up", "lookup", "search the web", "web search", "on the web", "the web"] where query.contains(signal) {
            return true
        }
        return false
    }

    /// A URL in the query, recognised by scheme, `www.`, or a bare hostname with
    /// a common top-level domain. Deliberately not "anything with a dot": a
    /// filename like `report.pdf` is a local file, not a page to open.
    static func containsURL(_ text: String) -> Bool {
        if text.contains("http://") || text.contains("https://") || text.contains("www.") {
            return true
        }
        let tlds = "com|org|net|io|dev|ai|co|app|me|info|xyz|tech|cloud|sh|gg|uk|de|fr|jp|us"
        let pattern = "\\b[a-z0-9-]+\\.[a-z0-9-]+\\.(?:\(tlds))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether a tool or server name appears in the query. Matches the whole name
    /// and each of its words, so a query naming "echo" reaches `echo__echo` and a
    /// query naming "read" reaches `read_file`.
    static func matchesQuery(name: String, query: String) -> Bool {
        guard !name.isEmpty, !query.isEmpty else { return false }
        let lowered = name.lowercased()
        if query.contains(lowered) { return true }
        for word in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        where word.count >= 3 && query.contains(word) {
            return true
        }
        return false
    }

    static func omitReason(for descriptor: ToolDescriptor, browserIntent: Bool) -> String {
        if descriptor.providerName == Self.browserProviderName && !browserIntent {
            return "no browsing intent"
        }
        if descriptor.providerID == "mcp" {
            return "no mention of \(descriptor.providerName)"
        }
        return "no intent matched this turn"
    }

    static func reason(kept: Int, total: Int, omitted: [ToolSummary]) -> String {
        guard !omitted.isEmpty else { return "Offered all \(total) tools." }
        return "\(omitted.count) tools held back this turn — \(grouped(omitted)). Calling one summons its group."
    }

    /// One line listing the providers that still hold tools, with their counts,
    /// so the model learns what exists elsewhere without the note growing with
    /// the inventory.
    static func omittedNote(_ omitted: [ToolSummary]) -> String? {
        guard !omitted.isEmpty else { return nil }
        return "\(omitted.count) tools held back this turn — \(grouped(omitted)). Calling one summons its group."
    }

    private static func grouped(_ omitted: [ToolSummary]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for summary in omitted {
            if counts[summary.providerName] == nil { order.append(summary.providerName) }
            counts[summary.providerName, default: 0] += 1
        }
        let listed = order.prefix(4).map { "\($0) (\(counts[$0]!))" }.joined(separator: ", ")
        return listed + (order.count > 4 ? ", …" : "")
    }
}
