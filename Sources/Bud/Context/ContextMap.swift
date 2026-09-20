import Foundation

// MARK: - Intent

/// How large a task the request reads as. Phase 1 fills this with deterministic
/// length/step/tool heuristics; a later DecisionEngine phase may refine it with a
/// typed classifier without changing the type.
public enum ComplexityLevel: String, Sendable, Codable {
    case trivial, normal, complex, longHorizon
}

/// What the request asks to do to the machine and the world.
///
/// Deterministic keyword detection only, and deliberately coarse: this is the
/// shadow of a future typed decision, not a policy. The ExecutionHarness's
/// allow/confirm/deny surface remains where enforcement happens; this field only
/// records what the request *reads as*.
public enum MutationIntent: String, Sendable, Codable {
    case read, localWrite, execute, externalMutation
}

// MARK: - Decision provenance

/// The precedence ladder from the roadmap's §5.2, minus the classifier tier,
/// which Phase 1 does not run. Lower is stronger: a capability activated by
/// explicit intent is not re-explained by a weaker sticky signal.
public enum DecisionTier: Int, Sendable, Codable, Comparable {
    case hardPolicy = 1
    case explicitIntent = 2
    case deterministicSignal = 3
    case stickyEvidence = 5
    case failOpen = 6
    /// No signal matched; the capability is recorded as an inactive candidate so
    /// the map is complete enough to compare against the planner's omissions.
    case omitted = 99

    public static func < (lhs: DecisionTier, rhs: DecisionTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One thing the request refers to, resolved in code rather than by a model.
public enum EntityKind: String, Sendable, Codable {
    case url, path, attachment, server, browserSurface
}

public struct ContextEntity: Sendable, Codable, Equatable {
    public var kind: EntityKind
    public var value: String
    public var source: DecisionTier

    public init(kind: EntityKind, value: String, source: DecisionTier) {
        self.kind = kind
        self.value = value
        self.source = source
    }
}

// MARK: - Assessments

public struct IntentAssessment: Sendable, Codable, Equatable {
    public var complexity: ComplexityLevel
    public var mutationIntent: MutationIntent
    /// Whether the request reads as underspecified. A heuristic in Phase 1;
    /// clarification policy in a later phase may use a typed score instead.
    public var ambiguous: Bool

    public init(complexity: ComplexityLevel, mutationIntent: MutationIntent, ambiguous: Bool) {
        self.complexity = complexity
        self.mutationIntent = mutationIntent
        self.ambiguous = ambiguous
    }
}

/// One capability group and how strongly the shadow analysis wants it.
///
/// `confidence` mirrors the roadmap's activation bands: >= 0.85 activate, 0.55…0.85
/// advertise, below 0.55 omit. Phase 1 only ever produces deterministic 0/0.85/0.9/0.99/1.0
/// values; the bands exist so a classifier later reports in the same vocabulary.
public struct CapabilityAssessment: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var confidence: Double
    public var tier: DecisionTier
    public var reason: String
    public var toolCount: Int
    public var tools: [String]

    public init(
        id: String,
        confidence: Double,
        tier: DecisionTier,
        reason: String,
        toolCount: Int,
        tools: [String]
    ) {
        self.id = id
        self.confidence = confidence
        self.tier = tier
        self.reason = reason
        self.toolCount = toolCount
        self.tools = tools
    }
}

/// A memory source the analysis believes is relevant. Candidates only: the body
/// is carried as text for compilation, never expanded into the map itself.
public struct MemoryCandidate: Sendable, Codable, Equatable {
    public var id: String
    public var characters: Int
    public var reason: String
    /// The candidate's body, budgeted to `characters`. Empty for candidates
    /// that only describe a source without quoting it (the remembered-notes
    /// block, whose body the prompt path owns).
    public var text: String

    public init(id: String, characters: Int, reason: String, text: String = "") {
        self.id = id
        self.characters = characters
        self.reason = reason
        self.text = text
    }
}

public struct SkillCandidate: Sendable, Codable, Equatable {
    public var id: String
    public var reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// A candidate delegate: a connected MCP server or an agent-only inventory group.
public struct DelegateCandidate: Sendable, Codable, Equatable {
    public var id: String
    public var toolCount: Int
    public var reason: String

    public init(id: String, toolCount: Int, reason: String) {
        self.id = id
        self.toolCount = toolCount
        self.reason = reason
    }
}

public enum RiskClass: String, Sendable, Codable {
    case none, low, medium, high
}

/// What the request implies about side effects and data boundaries, as a
/// deterministic shadow of the future ExecutionHarness assessment.
public struct ExecutionAssessment: Sendable, Codable, Equatable {
    public var mutationIntent: MutationIntent
    /// Whether the request carries data from or points at the outside world:
    /// a URL, a staged file, or the browser surface.
    public var externalData: Bool
    public var risk: RiskClass

    public init(mutationIntent: MutationIntent, externalData: Bool, risk: RiskClass) {
        self.mutationIntent = mutationIntent
        self.externalData = externalData
        self.risk = risk
    }
}

// MARK: - Budget

/// A character accounting of what the round's request actually carried, by
/// bucket. Phase 1 measures the current payload; the ledger semantics (reserves,
/// degradation order) belong to the ContextCompiler phases.
///
/// Named `ContextLedger` because `ContextBudget` is already the Settings row
/// model (Diagnostics.swift) for the same territory viewed from the UI.
public struct ContextLedger: Sendable, Codable, Equatable {
    public var systemCharacters: Int
    public var historyCharacters: Int
    public var toolSchemaCharacters: Int
    public var memoryCharacters: Int
    public var skillsCharacters: Int
    public var totalCharacters: Int

    public init(
        systemCharacters: Int,
        historyCharacters: Int,
        toolSchemaCharacters: Int,
        memoryCharacters: Int,
        skillsCharacters: Int,
        totalCharacters: Int
    ) {
        self.systemCharacters = systemCharacters
        self.historyCharacters = historyCharacters
        self.toolSchemaCharacters = toolSchemaCharacters
        self.memoryCharacters = memoryCharacters
        self.skillsCharacters = skillsCharacters
        self.totalCharacters = totalCharacters
    }
}

/// One rule that fired, with the tier that fired it. The map's audit trail:
/// every candidate above carries its own `tier`/`reason`, and this list records
/// the notable signal-level decisions (browse intent, mutation reading, an alias
/// the model's phrasing resolved) so a trace can be read top to bottom.
public struct ContextDecision: Sendable, Codable, Equatable {
    public var tier: DecisionTier
    public var summary: String

    public init(tier: DecisionTier, summary: String) {
        self.tier = tier
        self.summary = summary
    }
}

// MARK: - The map

/// A typed intermediate representation of what Bud believes is relevant before
/// any provider-specific prompt is constructed. Phase 1 builds it as a shadow of
/// the current ToolPlanner path: every round produces one, nothing in it alters
/// the payload.
public struct ContextMap: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var round: Int
    public var intent: IntentAssessment
    public var entities: [ContextEntity]
    public var capabilities: [CapabilityAssessment]
    public var memories: [MemoryCandidate]
    public var skills: [SkillCandidate]
    public var delegates: [DelegateCandidate]
    public var execution: ExecutionAssessment
    public var budget: ContextLedger
    public var provenance: [ContextDecision]

    public init(
        id: UUID = UUID(),
        round: Int,
        intent: IntentAssessment,
        entities: [ContextEntity],
        capabilities: [CapabilityAssessment],
        memories: [MemoryCandidate],
        skills: [SkillCandidate],
        delegates: [DelegateCandidate],
        execution: ExecutionAssessment,
        budget: ContextLedger,
        provenance: [ContextDecision]
    ) {
        self.id = id
        self.round = round
        self.intent = intent
        self.entities = entities
        self.capabilities = capabilities
        self.memories = memories
        self.skills = skills
        self.delegates = delegates
        self.execution = execution
        self.budget = budget
        self.provenance = provenance
    }
}

// MARK: - Trace

/// The diagnostic surface of the shadow run: what the map decided versus what the
/// current planner actually offered. Pure text over typed inputs, so it can be
/// exercised in the offline suite and rendered anywhere later.
public enum ContextMapTrace {
    /// Activation bands from the roadmap's §5.3; Phase 1's deterministic scores
    /// are all-or-nothing, so the band edges are what a divergence report reads.
    /// Owned by `DecisionPolicy` — the bands are eval outputs, not scattered
    /// constants.
    public static let activateThreshold = DecisionPolicy.activateThreshold
    public static let omitThreshold = DecisionPolicy.omitThreshold

    /// The groups the map would offer that the planner held back, and the groups
    /// the planner paid for that the map scores below its advertise band. Empty
    /// when the shadow agrees with the planner — the expected Phase 1 steady
    /// state, and the baseline a later CapabilityIndex phase moves away from.
    public static func divergences(map: ContextMap, plan: ToolPlan) -> [String] {
        var lines: [String] = []
        let offered = Set(plan.descriptors.map(\.providerName))

        for capability in map.capabilities where capability.id != "core" {
            if capability.confidence >= activateThreshold, !offered.contains(capability.id) {
                lines.append(
                    "map activates '\(capability.id)' (\(capability.reason)) but the planner omitted it"
                )
            } else if capability.confidence < omitThreshold, offered.contains(capability.id) {
                lines.append(
                    "planner offered '\(capability.id)' but the map scores it "
                        + String(format: "%.2f", capability.confidence)
                )
            }
        }
        return lines
    }

    /// One line per round: what was decided, at a glance.
    public static func summary(_ map: ContextMap) -> String {
        let activated = map.capabilities.filter { $0.confidence >= activateThreshold }
        let names = activated.map(\.id).joined(separator: ", ")
        let posture = "\(map.intent.complexity.rawValue)/\(map.intent.mutationIntent.rawValue)"
        return "round \(map.round): \(map.capabilities.count) groups, "
            + "\(activated.count) activated [\(names)], "
            + posture + ", "
            + "budget \(map.budget.totalCharacters) chars, "
            + "\(map.provenance.count) decisions"
    }
}
