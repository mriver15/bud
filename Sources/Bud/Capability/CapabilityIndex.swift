import Foundation

/// The compact discoverability layer over the tool inventory and the agent
/// roster: one capability per provider group (offered tools) plus one delegate
/// capability per agent-only group.
///
/// Built from descriptors alone, so it can be assembled at plan time and in
/// tests without reaching into the registry. Matching is deterministic: exact
/// id or alias, then word overlap against the summary — the same
/// word-matching discipline `ToolPlanner` uses for tool names, applied to
/// capability language instead.
public struct CapabilityIndex: Sendable, Equatable {
    public var capabilities: [Capability]

    public init(capabilities: [Capability]) {
        self.capabilities = capabilities
    }

    // MARK: - Building

    public static func build(
        descriptors: [ToolDescriptor],
        alwaysOn: [String]
    ) -> CapabilityIndex {
        var offered: [String: [ToolDescriptor]] = [:]
        var agentOnly: [String: [ToolDescriptor]] = [:]
        for descriptor in descriptors {
            if descriptor.agentOnly {
                agentOnly[descriptor.providerName, default: []].append(descriptor)
            } else {
                offered[descriptor.providerName, default: []].append(descriptor)
            }
        }

        var capabilities: [Capability] = []
        for (group, tools) in offered.sorted(by: { $0.key < $1.key }) {
            capabilities.append(
                capability(for: group, tools: tools, activation: .toolGroup(group))
            )
        }
        for (group, tools) in agentOnly.sorted(by: { $0.key < $1.key }) {
            capabilities.append(
                capability(for: group, tools: tools, activation: .delegate(group))
            )
        }
        return CapabilityIndex(capabilities: capabilities)
    }

    private static func capability(
        for group: String,
        tools: [ToolDescriptor],
        activation: Capability.Activation
    ) -> Capability {
        // The first tool's description leads with what the group is for; for an
        // MCP server it is the server's own "tool, provided by server" line.
        let summary = firstSentence(of: tools.first?.description) ?? "\(tools.count) tools"
        return Capability(
            id: group,
            summary: summary,
            aliases: Self.aliases(for: group),
            activation: activation,
            toolCount: tools.count
        )
    }

    /// Alias tables for the built-in groups, plus the legacy tool spellings the
    /// model reaches for by habit (`web_search` → the group holding `web_fetch`).
    /// A group's own name is always matched too; these are the *other* names.
    static func aliases(for group: String) -> [String] {
        switch group {
        case "Interface":
            return ["ui", "dashboard", "chart", "table", "visualize", "graph",
                    "plot", "metrics", "compare", "comparison"]
        case "Browser":
            return ["browse", "web", "open site", "look up", "web search", "the web"]
        case "Bud":
            return ToolPlanner.toolAliases.map(\.key)
        default:
            return [group.lowercased()]
        }
    }

    // MARK: - Lookup

    /// Capabilities the query names, strongest first. Exact id beats exact alias
    /// beats word overlap against the summary; below the advertise band a match
    /// is dropped rather than guessed.
    public func resolve(_ query: String, limit: Int = 3) -> [CapabilityMatch] {
        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return [] }

        var matches: [CapabilityMatch] = []
        for capability in capabilities {
            if let match = matchScore(capability, query: lowered) {
                matches.append(match)
            }
        }
        return Array(
            matches
                .sorted { $0.confidence > $1.confidence }
                .prefix(limit)
        )
    }

    private func matchScore(_ capability: Capability, query: String) -> CapabilityMatch? {
        if capability.id.lowercased() == query {
            return CapabilityMatch(capability: capability, confidence: 0.99, reason: "exact name")
        }
        if let alias = capability.aliases.first(where: { query.contains($0) && $0.count >= 2 }) {
            return CapabilityMatch(
                capability: capability, confidence: 0.95, reason: "alias '\(alias)'"
            )
        }
        let queryWords = Self.words(query)
        guard !queryWords.isEmpty else { return nil }
        let vocabulary = Set(
            Self.words(capability.id) + capability.aliases.flatMap(Self.words)
                + Self.words(capability.summary)
        )
        let overlap = queryWords.filter { vocabulary.contains($0) }
        guard !overlap.isEmpty else { return nil }
        let confidence = 0.55 + 0.44 * Double(overlap.count) / Double(queryWords.count)
        guard confidence >= 0.55 else { return nil }
        return CapabilityMatch(
            capability: capability,
            confidence: min(confidence, 0.9),
            reason: "\(overlap.count) of \(queryWords.count) words match"
        )
    }

    /// Lowercased word tokens, three characters or more: the same floor
    /// `ToolPlanner.matchesQuery` uses, so a two-letter noise word never names a
    /// capability. Noise words shared by every description — "tool", "file" —
    /// are dropped too: a word every capability owns matches none of them.
    static func words(_ text: String) -> [String] {
        let stop = Set([
            "the", "and", "for", "with", "from", "that", "this", "what", "into",
            "about", "tool", "tools", "file", "files", "using", "your", "name",
        ])
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }

    // MARK: - Catalogue

    /// The discovery text: one line per capability, what the query names first.
    ///
    /// The hard ceiling is what makes the catalogue an O(1) prompt cost: lines
    /// beyond it collapse into a count plus the discovery affordance — name one
    /// and it expands. The model loses nothing it could act on; a held-back
    /// capability is still summonable, it just is not enumerated.
    public func catalogue(query: String = "", ceiling: Int = 600) -> String {
        guard !capabilities.isEmpty else { return "" }

        var lines: [String] = []
        var shown: Set<String> = []
        var budget = ceiling

        // What the query names goes first, full line each, outside the budget:
        // these are the capabilities the round is about, and paying for them is
        // the point of the index.
        for match in resolve(query) {
            guard shown.insert(match.capability.id).inserted else { continue }
            lines.append(line(for: match.capability))
        }

        for capability in capabilities where !shown.contains(capability.id) {
            let line = line(for: capability)
            guard budget >= line.count else {
                let remaining = capabilities.count - shown.count
                lines.append("… \(remaining) more; name one and it expands.")
                return lines.joined(separator: "\n")
            }
            budget -= line.count
            shown.insert(capability.id)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func line(for capability: Capability) -> String {
        switch capability.activation {
        case .toolGroup:
            return "- \(capability.id): \(capability.summary) (\(capability.toolCount) tools)"
        case .delegate:
            return "- \(capability.id): \(capability.summary) (\(capability.toolCount) tools, delegate)"
        }
    }

    private static func firstSentence(of text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var sentence = ""
        for character in text {
            if character == "." && sentence.count > 20 { break }
            sentence.append(character)
        }
        return sentence
    }
}
