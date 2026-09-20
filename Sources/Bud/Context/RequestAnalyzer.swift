import Foundation

/// Phase 1 of the context-harness rework: deterministic request signals, assembled
/// into a shadow `ContextMap`.
///
/// The whole point of the phase is measurement without behaviour change. The
/// analyzer is pure: same inputs, same map. It never touches the planner's
/// result, the tool list, or the messages — it reads the same planning inputs the
/// planner read and writes only its own value. Every rule that fires is recorded
/// in `provenance` with its precedence tier, which is what makes the shadow
/// comparable against the current planner rather than just decorative.
public enum RequestAnalyzer {

    /// The planning inputs one round has. Kept as a value so the analyzer stays
    /// pure and the runtime's wiring stays one call.
    public struct Inputs: Sendable {
        public var query: String
        public var surface: String?
        public var attachmentPaths: [String]
        public var recentToolNames: [String]
        public var connectedServers: [String]
        public var round: Int

        public init(
            query: String,
            surface: String?,
            attachmentPaths: [String],
            recentToolNames: [String],
            connectedServers: [String],
            round: Int
        ) {
            self.query = query
            self.surface = surface
            self.attachmentPaths = attachmentPaths
            self.recentToolNames = recentToolNames
            self.connectedServers = connectedServers
            self.round = round
        }
    }

    // MARK: - Entry point

    public static func analyze(
        inputs: Inputs,
        descriptors: [ToolDescriptor],
        plan: ToolPlan,
        notesCharacters: Int,
        promotedSkills: [String],
        budget: ContextLedger
    ) -> ContextMap {
        let query = inputs.query
        let lowered = query.lowercased()

        let offered = descriptors.filter { !$0.agentOnly }
        let agentOnlyGroups = group(descriptors.filter(\.agentOnly))
        let groups = group(offered)

        // Signals are computed once and shared by the capability, entity and
        // provenance passes, so a rule and its record cannot drift apart.
        let browserIntent = ToolPlanner.hasBrowserIntent(query: lowered, surface: inputs.surface)
        let uiIntent = containsAny(
            lowered,
            words: ["dashboard", "chart", "table", "compare", "comparison", "visualize",
                    "visualise", "graph", "plot", "metrics", "sparkline", "histogram"]
        )
        let mutation = mutationIntent(in: lowered)
        let externalData = !urls(in: query).isEmpty
            || !inputs.attachmentPaths.isEmpty
            || inputs.surface == ToolPlanner.browserSurfaceID
        let stepCount = stepMarkers(in: lowered)

        let urlEntities = urls(in: query)
        var entities = urlEntities.map { ContextEntity(kind: .url, value: $0, source: .deterministicSignal) }
        entities.append(contentsOf: paths(in: query, excluding: urlEntities)
            .map { ContextEntity(kind: .path, value: $0, source: .deterministicSignal) })
        entities.append(contentsOf: inputs.attachmentPaths
            .map { ContextEntity(kind: .attachment, value: $0, source: .explicitIntent) })
        for server in inputs.connectedServers where ToolPlanner.matchesQuery(name: server, query: lowered) {
            entities.append(ContextEntity(kind: .server, value: server, source: .explicitIntent))
        }
        if inputs.surface == ToolPlanner.browserSurfaceID {
            entities.append(
                ContextEntity(kind: .browserSurface, value: "browser", source: .explicitIntent)
            )
        }

        // Capabilities: the always-on recovery core, then one assessment per
        // provider group. A group takes the strongest signal that names it —
        // explicit mention beats a deterministic heuristic beats sticky evidence.
        var capabilities: [CapabilityAssessment] = []
        let coreNames = ToolPlanner.alwaysOnCore.filter { name in offered.contains { $0.name == name } }
        if !coreNames.isEmpty {
            capabilities.append(
                CapabilityAssessment(
                    id: "core",
                    confidence: 1.0,
                    tier: .hardPolicy,
                    reason: "always-on recovery and discovery primitives",
                    toolCount: coreNames.count,
                    tools: coreNames
                )
            )
        }

        let recentSet = Set(inputs.recentToolNames)
        let attachmentTools = Set(ToolPlanner.attachmentTools)

        for (group, tools) in groups.sorted(by: { $0.key < $1.key }) {
            let names = tools.map(\.name)
            let named = names.contains { ToolPlanner.matchesQuery(name: $0, query: lowered) }
                || ToolPlanner.matchesQuery(name: group, query: lowered)
            let mentioned = named
                || inputs.connectedServers.contains { $0.caseInsensitiveCompare(group) == .orderedSame
                    && ToolPlanner.matchesQuery(name: $0, query: lowered) }

            let assessment: CapabilityAssessment
            if mentioned {
                assessment = CapabilityAssessment(
                    id: group, confidence: 0.99, tier: .explicitIntent,
                    reason: "explicitly named in the request",
                    toolCount: tools.count, tools: names
                )
            } else if browserIntent && group == ToolPlanner.browserProviderName {
                assessment = CapabilityAssessment(
                    id: group, confidence: 0.9, tier: .deterministicSignal,
                    reason: "the request reads as a browse task",
                    toolCount: tools.count, tools: names
                )
            } else if uiIntent && group == "Interface" {
                assessment = CapabilityAssessment(
                    id: group, confidence: 0.9, tier: .deterministicSignal,
                    reason: "the request names a presentation outcome",
                    toolCount: tools.count, tools: names
                )
            } else if !inputs.attachmentPaths.isEmpty && names.contains(where: attachmentTools.contains) {
                assessment = CapabilityAssessment(
                    id: group, confidence: 0.9, tier: .deterministicSignal,
                    reason: "a staged attachment needs to be read",
                    toolCount: tools.count, tools: names
                )
            } else if names.contains(where: recentSet.contains) {
                assessment = CapabilityAssessment(
                    id: group, confidence: 0.85, tier: .stickyEvidence,
                    reason: "a tool of this group ran in the previous two rounds",
                    toolCount: tools.count, tools: names
                )
            } else {
                assessment = CapabilityAssessment(
                    id: group, confidence: 0, tier: .omitted,
                    reason: "no signal matched this round",
                    toolCount: tools.count, tools: names
                )
            }
            capabilities.append(assessment)
        }

        // Delegates: connected MCP servers and agent-only inventories. Both are
        // reachable only through delegation in the current architecture, which is
        // exactly the roster the roadmap wants to keep out of the parent prompt.
        var delegates: [DelegateCandidate] = []
        for server in inputs.connectedServers {
            let toolCount = groups[server]?.count ?? 0
            delegates.append(
                DelegateCandidate(
                    id: server,
                    toolCount: toolCount,
                    reason: ToolPlanner.matchesQuery(name: server, query: lowered)
                        ? "connected and explicitly named"
                        : "connected"
                )
            )
        }
        for (group, tools) in agentOnlyGroups.sorted(by: { $0.key < $1.key }) {
            delegates.append(
                DelegateCandidate(id: group, toolCount: tools.count, reason: "agent-reachable inventory")
            )
        }

        var memories: [MemoryCandidate] = []
        if notesCharacters > 0 {
            memories.append(
                MemoryCandidate(
                    id: "remembered-notes",
                    characters: notesCharacters,
                    reason: "lesson context carried in the system prompt"
                )
            )
        }

        let skills = promotedSkills.map {
            SkillCandidate(id: $0, reason: "ranked against the current query")
        }

        // Provenance: one entry per signal-level decision, in firing order.
        var provenance: [ContextDecision] = []
        if browserIntent {
            provenance.append(
                ContextDecision(
                    tier: .deterministicSignal,
                    summary: "browse intent from query or surface"
                )
            )
        }
        if uiIntent {
            provenance.append(
                ContextDecision(
                    tier: .deterministicSignal,
                    summary: "presentation intent from query keywords"
                )
            )
        }
        for server in inputs.connectedServers where ToolPlanner.matchesQuery(name: server, query: lowered) {
            provenance.append(
                ContextDecision(tier: .explicitIntent, summary: "named MCP server '\(server)'")
            )
        }
        if !inputs.attachmentPaths.isEmpty {
            provenance.append(
                ContextDecision(
                    tier: .explicitIntent,
                    summary: "\(inputs.attachmentPaths.count) staged attachment(s)"
                )
            )
        }
        if !recentSet.isEmpty {
            provenance.append(
                ContextDecision(
                    tier: .stickyEvidence,
                    summary: "recent tools: \(recentSet.sorted().joined(separator: ", "))"
                )
            )
        }
        for alias in ToolPlanner.toolAliases.keys where lowered.contains(alias) {
            provenance.append(
                ContextDecision(
                    tier: .deterministicSignal,
                    summary: "legacy alias '\(alias)' present (resolves to \(ToolPlanner.toolAliases[alias]!))"
                )
            )
        }
        if mutation != .read {
            provenance.append(
                ContextDecision(tier: .deterministicSignal, summary: "reads as \(mutation.rawValue)")
            )
        }
        if plan.reason.contains("held back") {
            provenance.append(
                ContextDecision(tier: .failOpen, summary: "planner expanded after a held-back call")
            )
        }

        let complexity = complexityLevel(
            queryCount: query.count,
            stepCount: stepCount,
            round: inputs.round,
            trivialSafe: !browserIntent && !uiIntent && mutation == .read && urlEntities.isEmpty
                && inputs.attachmentPaths.isEmpty && mentionedToolCount(in: lowered, groups: groups) == 0
        )
        let ambiguous = isAmbiguous(lowered)

        let risk = riskClass(mutation: mutation, externalData: externalData, query: lowered)

        return ContextMap(
            round: inputs.round,
            intent: IntentAssessment(
                complexity: complexity,
                mutationIntent: mutation,
                ambiguous: ambiguous
            ),
            entities: entities,
            capabilities: capabilities,
            memories: memories,
            skills: skills,
            delegates: delegates,
            execution: ExecutionAssessment(
                mutationIntent: mutation,
                externalData: externalData,
                risk: risk
            ),
            budget: budget,
            provenance: provenance
        )
    }

    // MARK: - Signals

    /// Groups descriptors by provider name, preserving declaration order.
    static func group(_ descriptors: [ToolDescriptor]) -> [String: [ToolDescriptor]] {
        var byGroup: [String: [ToolDescriptor]] = [:]
        for descriptor in descriptors {
            byGroup[descriptor.providerName, default: []].append(descriptor)
        }
        return byGroup
    }

    /// Urls in the query: scheme or `www.` prefixed. Deliberately not "anything
    /// with a dot" — `report.pdf` is a file, not a page.
    static func urls(in text: String) -> [String] {
        matches(
            pattern: #"(?:https?://|www\.)[^\s"'<>]+"#,
            in: text,
            trim: CharacterSet(charactersIn: ".,;:!?)>]")
        )
    }

    /// Paths in the query: absolute (`/…`, `~/…`) or relative with a directory
    /// separator and a file extension (`src/notes.md`). Url hits are excluded,
    /// so a pasted link does not double as a path. A bare domain like
    /// `example.com/docs` does not match: no extension means no file.
    static func paths(in text: String, excluding urls: [String]) -> [String] {
        let candidates = matches(
            pattern: #"~?/[\w@%+.\-]+(?:/[\w@%+.\-~]+)*"#,
            in: text,
            trim: CharacterSet(charactersIn: ".,;:!?")
        ) + matches(
            pattern: #"[\w@%+.\-]+/[\w@%+.\-/~]*\.\w{2,8}"#,
            in: text,
            trim: CharacterSet(charactersIn: ".,;:!?")
        )
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let insideURL = urls.contains { candidate.contains($0) || $0.contains(candidate) }
            return !insideURL && seen.insert(candidate).inserted
        }
    }

    /// Reads what the request wants to do, by verbs. Checked strongest first:
    /// "run deploy" is an execution, "push" is an external mutation, "write" is a
    /// local one. A false positive here costs nothing — the field is diagnostic,
    /// not policy.
    static func mutationIntent(in query: String) -> MutationIntent {
        let q = query.lowercased()
        if containsAny(q, words: ["run", "execute", "install", "compile", "launch", "restart",
                                  "rebuild", "test", "deploy", "start", "stop", "kill"]) {
            return .execute
        }
        // Strong external verbs alone, weak ones only when the request also
        // points at the outside world: "send a postcard" is not a network call.
        if containsAny(q, words: ["push", "commit", "publish", "upload", "pull request"]) {
            return .externalMutation
        }
        if containsAny(q, words: ["send", "post", "tweet", "submit", "email", "merge"])
            && !urls(in: q).isEmpty {
            return .externalMutation
        }
        if containsAny(q, words: ["write", "edit", "create", "save", "rename", "delete", "remove",
                                  "overwrite", "fix", "update", "modify", "refactor", "move",
                                  "copy", "organize"]) {
            return .localWrite
        }
        return .read
    }

    /// Multi-step markers: sequence words and numbered items. A rough count,
    /// enough to separate "rename this file" from a procedure.
    static func stepMarkers(in query: String) -> Int {
        var count = matches(
            pattern: #"\b(step|first|second|third|then|next|after that|finally)\b"#,
            in: query,
            trim: CharacterSet()
        ).count
        for line in query.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.first?.isNumber == true,
               trimmed.dropFirst().first == "." || trimmed.dropFirst().first == ")" {
                count += 1
            }
        }
        return count
    }

    static func complexityLevel(
        queryCount: Int,
        stepCount: Int,
        round: Int,
        trivialSafe: Bool
    ) -> ComplexityLevel {
        // A long-running conversation is its own complexity signal: the request
        // exists inside a task the model has been working on for several rounds.
        if round >= 5 || queryCount >= 500 || stepCount >= 3 { return .longHorizon }
        if queryCount > 200 || stepCount >= 1 { return .complex }
        if trivialSafe && queryCount <= 60 { return .trivial }
        return .normal
    }

    /// "Fix it or roll it back?" — an underspecified choice, and a short question
    /// at all. Heuristic, and recorded as one; the clarification policy phase
    /// replaces this with a typed score.
    static func isAmbiguous(_ query: String) -> Bool {
        guard query.count < 140 else { return false }
        return containsWord(query, "or") || query.contains("either") || query.contains("?")
    }

    static func riskClass(mutation: MutationIntent, externalData: Bool, query: String) -> RiskClass {
        switch mutation {
        case .read: return externalData ? .low : .none
        case .localWrite:
            let destructive = containsAny(query, words: ["delete", "remove", "overwrite", "wipe"])
            return destructive ? .high : .medium
        case .execute, .externalMutation: return .high
        }
    }

    /// How many groups the query names by tool or group name — a second
    /// complexity signal, kept separate from the keyword one.
    static func mentionedToolCount(in query: String, groups: [String: [ToolDescriptor]]) -> Int {
        var count = 0
        for (group, tools) in groups {
            if ToolPlanner.matchesQuery(name: group, query: query)
                || tools.contains(where: { ToolPlanner.matchesQuery(name: $0.name, query: query) }) {
                count += 1
            }
        }
        return count
    }

    // MARK: - Text helpers

    static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func containsAny(_ text: String, words: [String]) -> Bool {
        words.contains { containsWord(text, $0) }
    }

    /// Non-overlapping regex matches, trailing punctuation trimmed.
    static func matches(pattern: String, in text: String, trim: CharacterSet) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let hits = regex.matches(in: text, range: range)
        var seen: Set<String> = []
        var results: [String] = []
        for hit in hits {
            guard let tokenRange = Range(hit.range, in: text) else { continue }
            var token = String(text[tokenRange])
            if !trim.isEmpty {
                token = token.trimmingCharacters(in: trim)
            }
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            results.append(token)
            if results.count == 8 { break }
        }
        return results
    }
}
