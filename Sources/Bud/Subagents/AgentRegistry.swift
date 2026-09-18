import Foundation
import Observation

/// Everything that can be delegated to, in one place.
///
/// Bud has three places a capability can come from — its own code, an installed
/// skill, and a connected MCP server — and they are owned by different subsystems
/// that do not know about each other. This is where they meet, so that "what can I
/// hand this to" has one answer rather than three that have to be kept in step.
///
/// It is deliberately passive: it takes what it is given and does not reach into
/// the skill store or the MCP manager. Those are the app's, and a registry that
/// fetched from them could not be built in a test without building the app.
@MainActor
@Observable
public final class AgentRegistry {
    /// Built in first, then yours. Stable within each group, because a list that
    /// reorders itself between launches is one nobody can learn.
    public private(set) var agents: [AgentDefinition] = []

    /// Where a rebuild gets its material: the installed skills and the configured
    /// servers. Set by the app at startup.
    ///
    /// A closure rather than a reference, because reading skills from disk and
    /// servers from the MCP manager are the app's business — a registry that held
    /// those types could not be built in a test without building the app with them.
    public var source: (@MainActor () -> (skills: [Skill], servers: [MCPServerConfig]))?

    public init() {}

    /// Rebuilds from whatever the app currently has.
    public func refresh() {
        guard let source else { return }
        let material = source()
        rebuild(skills: material.skills, servers: material.servers)
    }

    /// Rebuilds the roster from what currently exists.
    ///
    /// Called whenever a skill is installed or removed, or a server is added,
    /// enabled or disconnected — the roster is a view of those, not a copy that has
    /// to be remembered to be updated.
    ///
    /// **The first definition of a name wins.** Built-ins are collected first, so
    /// `scout` is always the scout; a skill cannot reach in and redefine one by
    /// taking its name. That is the quieter failure of the two — a skill that
    /// silently replaced a built-in would be discovered only by the agent behaving
    /// unlike itself.
    public func rebuild(skills: [Skill], servers: [MCPServerConfig]) {
        var collected: [AgentDefinition] = AgentLibrary.builtins
        collected.append(contentsOf: skills.compactMap(AgentLibrary.from(skill:)))
        collected.append(contentsOf: servers.filter(\.enabled).map(AgentLibrary.from(server:)))

        var seen: Set<String> = []
        let unique = collected.filter { seen.insert($0.name).inserted }
        // Assigned only when it differs. This is read by the tool description on
        // every request and by the panel on every render, and `@Observable`
        // invalidates on assignment rather than on change — so a roster that
        // rebuilt to the same three agents would redraw every view watching it,
        // on every request, forever.
        if agents != unique { agents = unique }
    }

    public func named(_ name: String) -> AgentDefinition? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agents.first { $0.name.lowercased() == wanted }
    }

    /// The groups the panel lists under, in the order the panel should show them.
    public var grouped: [(group: String, agents: [AgentDefinition])] {
        var order: [String] = []
        var byGroup: [String: [AgentDefinition]] = [:]
        for agent in agents {
            let group = agent.origin.group
            if byGroup[group] == nil {
                order.append(group)
                byGroup[group] = []
            }
            byGroup[group]?.append(agent)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    /// The roster as the model reads it, for the delegation tool's description.
    ///
    /// Generated rather than written down, because a hand-written list of what can
    /// be delegated to is wrong the moment a skill is installed — and wrong in the
    /// direction that matters, since the model would keep choosing an agent that is
    /// no longer there.
    ///
    /// Summaries are trimmed to their first sentence. The description is paid for on
    /// every request, and the second sentence of an agent's summary is worth less
    /// than the tokens it costs to send it forever.
    public func roster() -> String {
        guard !agents.isEmpty else { return "" }
        return agents
            .map { "- \($0.name) — \(firstSentence($0.summary))" }
            .joined(separator: "\n")
    }

    private func firstSentence(_ text: String) -> String {
        let flat = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        guard let stop = flat.firstIndex(of: ".") else { return flat }
        // A period inside the first few characters is an abbreviation or a decimal,
        // not the end of a sentence.
        guard flat.distance(from: flat.startIndex, to: stop) > 8 else { return flat }
        return String(flat[...stop])
    }
}
