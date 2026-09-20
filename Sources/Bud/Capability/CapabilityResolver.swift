import Foundation

/// What a tool succeeding buys it: admission into later rounds' Stage A without
/// the request naming it again. A succeeded tool is the best guess at what is
/// about to be needed, and a failed one is evidence it was not.
public struct StickyEvidence: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        var lastSuccessRound: Int
        var successes: Int
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Records a tool outcome. Only successes stick: a failed call is not
    /// evidence the tool is wanted again.
    public mutating func record(tool: String, succeeded: Bool, round: Int) {
        guard succeeded else { return }
        var entry = entries[tool] ?? Entry(lastSuccessRound: 0, successes: 0)
        entry.lastSuccessRound = round
        entry.successes += 1
        entries[tool] = entry
    }

    /// The tools that succeeded within the window, the most proven first —
    /// success count, then recency. Mirrors the planner's "previous two rounds"
    /// horizon, but only admits what actually worked.
    public func activeTools(currentRound: Int, window: Int = 2) -> [String] {
        entries
            .filter { currentRound - $0.value.lastSuccessRound < window }
            .sorted { left, right in
                if left.value.successes != right.value.successes {
                    return left.value.successes > right.value.successes
                }
                return left.value.lastSuccessRound > right.value.lastSuccessRound
            }
            .map(\.key)
    }
}

/// Phase 6: the decision outputs become the round's capability exposure.
///
/// Stage A under contextCompilerV2: the typed batch — needs_* decisions,
/// primary domain, and their confidences — decides which groups the first
/// request carries, with explicit user intent always winning and sticky
/// evidence keeping what worked. Stage B (fail-open expansion) is unchanged.
public enum CapabilityResolver {
    public struct StageAResult: Sendable {
        public var plan: ToolPlan
        /// The schema weight of what was offered — the figure the recall gate
        /// compares against the planner's.
        public var schemaCharacters: Int

        public init(plan: ToolPlan, schemaCharacters: Int) {
            self.plan = plan
            self.schemaCharacters = schemaCharacters
        }
    }

    public static func stageA(
        state: DecisionState,
        batch: DecisionBatch,
        descriptors: [ToolDescriptor],
        stickyTools: [String],
        bands: DecisionBands = .default
    ) -> StageAResult {
        let query = state.query.lowercased()

        var byName: [String: ToolDescriptor] = [:]
        var byGroup: [String: [ToolDescriptor]] = [:]
        for descriptor in descriptors {
            byName[descriptor.name] = descriptor
            byGroup[descriptor.providerName, default: []].append(descriptor)
        }

        // A decision below the omit band is not evidence: the resolver reads
        // only what the engine was confident about.
        func decision(_ id: String) -> Bool {
            guard let answer = batch.answer(for: id) else { return false }
            return answer.booleanValue == true && answer.confidence >= bands.omit
        }

        let needsBrowser = decision("needs_browser")
        let needsWeb = decision("needs_web")
        let needsFiles = decision("needs_files")
        let needsUI = decision("needs_ui")

        // Promoted groups, in decision order. A group is atomic: naming one
        // tool of a server brings the server's whole surface.
        var promoted: [String] = []
        var promotedSet: Set<String> = []
        func promote(_ group: String) {
            guard !group.isEmpty, promotedSet.insert(group).inserted else { return }
            promoted.append(group)
        }

        // Explicit intent first: what the request names beats every heuristic.
        for descriptor in descriptors {
            let namedTool = ToolPlanner.matchesQuery(name: descriptor.name, query: query)
            let namedServer = ToolPlanner.matchesQuery(name: descriptor.providerName, query: query)
            if namedTool || namedServer { promote(descriptor.providerName) }
        }
        for server in state.connectedServers where ToolPlanner.matchesQuery(name: server, query: query) {
            promote(server)
        }

        // The typed batch: capability routing, exactly the §5.1 decisions.
        if needsBrowser { promote(ToolPlanner.browserProviderName) }
        if needsWeb, let web = byName[ToolPlanner.toolAliases["web_search"] ?? "web_fetch"] {
            promote(web.providerName)
        }
        if needsFiles, let reader = byName["read_file"] {
            promote(reader.providerName)
        }
        if let domain = batch.answer(for: "primary_domain")?.choiceValue,
           byGroup[domain] != nil {
            promote(domain)
        }

        // Sticky execution evidence: what succeeded recently stays available.
        for tool in stickyTools {
            if let descriptor = byName[tool] { promote(descriptor.providerName) }
        }

        // Assemble: recovery core first, then promoted groups, then
        // attachments. Under the flag the UI schemas leave the core when no
        // decision asked for them — the fail-open path admits them if the model
        // calls one.
        var core = ToolPlanner.alwaysOnCore
        if !needsUI {
            core.removeAll {
                $0 == GenUIToolProvider.renderToolName || $0 == GenUIToolProvider.findToolName
            }
        }

        var included: [ToolDescriptor] = []
        var includedNames: Set<String> = []
        func add(_ descriptor: ToolDescriptor) {
            guard includedNames.insert(descriptor.name).inserted else { return }
            included.append(descriptor)
        }

        for name in core {
            if let descriptor = byName[name] { add(descriptor) }
        }
        for group in promoted {
            for descriptor in byGroup[group] ?? [] { add(descriptor) }
        }
        if !state.attachmentPaths.isEmpty {
            for name in ToolPlanner.attachmentTools {
                if let descriptor = byName[name] { add(descriptor) }
            }
        }

        let kept = Array(included.prefix(12))
        let keptNames = Set(kept.map(\.name))

        var omitted: [ToolSummary] = []
        for descriptor in descriptors where !keptNames.contains(descriptor.name) {
            omitted.append(
                ToolSummary(
                    name: descriptor.name,
                    providerName: descriptor.providerName,
                    why: ToolPlanner.omitReason(for: descriptor, browserIntent: needsBrowser)
                )
            )
        }

        let schemaCharacters = kept.reduce(0) {
            $0 + $1.name.count + $1.description.count + $1.schema.stringContentLength
        }
        return StageAResult(
            plan: ToolPlan(
                descriptors: kept,
                omitted: omitted,
                reason: ToolPlanner.reason(kept: kept.count, total: descriptors.count, omitted: omitted)
            ),
            schemaCharacters: schemaCharacters
        )
    }
}
