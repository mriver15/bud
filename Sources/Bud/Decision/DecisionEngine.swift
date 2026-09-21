import Foundation

// MARK: - State

/// What a decision is made about. The deterministic signals one request
/// carries — the same world `RequestAnalyzer` reads, kept as its own type so
/// the decision layer does not depend on the analyzer's shape.
public struct DecisionState: Sendable, Equatable {
    public var query: String
    public var surface: String?
    public var attachmentPaths: [String]
    public var recentToolNames: [String]
    public var connectedServers: [String]
    public var round: Int
    /// What the query directly names across skills, tools and subagents.
    /// Pre-resolved by the runtime against the index, the tool inventory and
    /// the installed skills — the delegation decision is the complement: a
    /// request that names nothing local has nowhere to land but an agent.
    public var directCapabilities: [String]
    /// How many memory candidates retrieval found for the query. The memory
    /// decision reads this: a request draws on remembered context when the
    /// store holds something that speaks to it, not only when the request
    /// says "memory".
    public var memoryCandidates: Int

    public init(
        query: String,
        surface: String? = nil,
        attachmentPaths: [String] = [],
        recentToolNames: [String] = [],
        connectedServers: [String] = [],
        round: Int = 1,
        directCapabilities: [String] = [],
        memoryCandidates: Int = 0
    ) {
        self.query = query
        self.surface = surface
        self.attachmentPaths = attachmentPaths
        self.recentToolNames = recentToolNames
        self.connectedServers = connectedServers
        self.round = round
        self.directCapabilities = directCapabilities
        self.memoryCandidates = memoryCandidates
    }
}

// MARK: - Questions and answers

/// A typed question (§3.2 of the roadmap): routing returns enums, booleans and
/// scores — not prose that must be parsed back out of a paragraph.
public enum DecisionQuestion: Sendable, Equatable {
    case boolean(id: String, instructions: String)
    /// `criteria` maps each option to a rubric the engine can judge by; nil
    /// entries answer "no extra detail". Used by `delegate_to`, where the
    /// options are agent names and the rubrics are what each agent does.
    case choice(id: String, options: [String], instructions: String, criteria: [String: String]? = nil)
    case score(id: String, levels: [String], instructions: String)

    public var id: String {
        switch self {
        case .boolean(let id, _), .choice(let id, _, _, _), .score(let id, _, _): return id
        }
    }
}

/// The typed answer one question received.
public struct DecisionAnswer: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case boolean(Bool)
        case choice(String)
        case score(String)
    }

    public var questionID: String
    public var kind: Kind
    /// How confident the answering engine is, on the roadmap's bands:
    /// ≥0.85 activate, 0.55…0.85 advertise, below 0.55 omit.
    public var confidence: Double
    public var rationale: String

    public init(questionID: String, kind: Kind, confidence: Double, rationale: String) {
        self.questionID = questionID
        self.kind = kind
        self.confidence = confidence
        self.rationale = rationale
    }

    public var booleanValue: Bool? {
        if case .boolean(let value) = kind { return value }
        return nil
    }

    public var choiceValue: String? {
        if case .choice(let value) = kind { return value }
        return nil
    }

    public var scoreValue: String? {
        if case .score(let value) = kind { return value }
        return nil
    }

    /// The answer as a trace-friendly token.
    public var kindDescription: String {
        switch kind {
        case .boolean(let value): return value ? "true" : "false"
        case .choice(let value): return value
        case .score(let value): return value
        }
    }
}

/// All answers one evaluation produced, keyed by question id.
///
/// Questions that share the same state are evaluated together — one call, one
/// batch — which is the shape a remote classifier is good at and a local
/// deterministic engine does not need.
public struct DecisionBatch: Sendable, Equatable {
    public var engineID: String
    public var answers: [DecisionAnswer]

    public init(engineID: String, answers: [DecisionAnswer]) {
        self.engineID = engineID
        self.answers = answers
    }

    public func answer(for questionID: String) -> DecisionAnswer? {
        answers.first { $0.questionID == questionID }
    }

    /// The ids the batch did not answer, so a caller can spot the gap rather
    /// than read an empty answer as a no.
    public var unanswered: [String] { answers.map(\.questionID) }
}

/// The §5.1 initial batch: the ten decisions every round makes, as typed
/// questions. `domains` is the compact capability-group list the
/// `primary_domain` choice is offered from.
public enum DecisionQuestions {
    public static func initial(domains: [String]) -> [DecisionQuestion] {
        [
            .boolean(id: "needs_files", instructions: "Whether the request needs file reading or writing."),
            .boolean(id: "needs_browser", instructions: "Whether the request needs the live browser."),
            .boolean(id: "needs_web", instructions: "Whether the request needs fetching from the web."),
            .boolean(id: "needs_memory", instructions: "Whether the request draws on remembered context."),
            .boolean(id: "needs_ui", instructions: "Whether the answer should be a structured surface."),
            .boolean(id: "needs_delegate", instructions: "Whether the request has no directly matching skill, subagent, or tool, so the work must be handed to an agent."),
            .choice(id: "complexity", options: ["trivial", "normal", "complex", "long_horizon"],
                    instructions: "How large the task reads."),
            .choice(id: "mutation_intent", options: ["read", "localWrite", "execute", "externalMutation"],
                    instructions: "What the request asks to change."),
            .choice(id: "primary_domain", options: domains,
                    instructions: "The capability group the request is about."),
            .score(id: "ambiguity", levels: ["low", "medium", "high"],
                   instructions: "How underspecified the request reads."),
        ]
    }
}

// MARK: - Engine

/// Which engine answers the routing batch, as configured (§11 of the
/// roadmap). `provider` is the configured-LLM fallback for questions the
/// deterministic rules do not own; a Jev adapter joins as a case when its
/// endpoint contract exists. Anything unselected still works: the
/// deterministic engine is always the floor.
public enum DecisionEngineID: String, Sendable, Codable, CaseIterable {
    case deterministic
    case provider
    case jev

    public var label: String {
        switch self {
        case .deterministic: return "Deterministic (rules, offline)"
        case .provider: return "Provider (the session model)"
        case .jev: return "Jev (TypeSafe, typed decisions)"
        }
    }
}

/// The seam every decision backend satisfies: a typed batch in, a typed batch
/// out. The deterministic engine is always available; the provider engine is
/// the configured-LLM fallback; a future local classifier or Jev adapter slots
/// into the same contract without touching the callers.
public protocol DecisionEngine: Sendable {
    var id: String { get }
    func evaluate(state: DecisionState, questions: [DecisionQuestion]) async throws -> DecisionBatch
}

// MARK: - Policy

public enum ActivationDisposition: String, Sendable, Equatable {
    case activate, advertise, omit
}

/// The confidence bands from §5.3, as a value rather than scattered constants.
/// The bands are eval outputs, not permanent numbers: tuning phases change
/// them here, in one place, and every consumer reads the same thresholds.
public struct DecisionBands: Sendable, Equatable {
    public var activate: Double
    public var omit: Double

    public static let `default` = DecisionBands(activate: 0.85, omit: 0.55)

    public init(activate: Double, omit: Double) {
        self.activate = activate
        self.omit = omit
    }

    public func disposition(_ confidence: Double) -> ActivationDisposition {
        if confidence >= activate { return .activate }
        if confidence >= omit { return .advertise }
        return .omit
    }
}

/// The default bands, kept as a namespace for the call sites that predate the
/// configurable form.
public enum DecisionPolicy {
    public static let activateThreshold = DecisionBands.default.activate
    public static let omitThreshold = DecisionBands.default.omit

    public static func disposition(_ confidence: Double) -> ActivationDisposition {
        DecisionBands.default.disposition(confidence)
    }
}

// MARK: - Trace

/// The shadow comparison between a decision batch and the analyzer's map built
/// from the same state. Agreement is silence; every disagreement is a named
/// line, so a drift between the two deterministic views is visible rather than
/// papered over.
public enum DecisionTrace {
    public static func compare(batch: DecisionBatch, map: ContextMap, plan: ToolPlan) -> [String] {
        var lines: [String] = []

        func capabilityActivated(_ id: String) -> Bool {
            map.capabilities.contains { $0.id == id && $0.confidence >= DecisionPolicy.activateThreshold }
        }

        func check(_ question: String, _ engineSays: Bool, _ mapSays: Bool, _ label: String) {
            guard engineSays != mapSays else { return }
            lines.append(
                "decision '\(question)' says \(engineSays ? "yes" : "no") but the map \(label)"
            )
        }

        if let answer = batch.answer(for: "needs_browser")?.booleanValue {
            check("needs_browser", answer, capabilityActivated(ToolPlanner.browserProviderName),
                  "scores the browser group at \(map.capabilities.first { $0.id == ToolPlanner.browserProviderName }?.confidence ?? 0)")
        }
        if let answer = batch.answer(for: "needs_ui")?.booleanValue {
            check("needs_ui", answer, capabilityActivated("Interface"), "scores the interface group differently")
        }
        if let answer = batch.answer(for: "complexity")?.choiceValue {
            let mapped = map.intent.complexity.rawValue
            if answer != mapped {
                lines.append("decision 'complexity' says \(answer) but the map reads \(mapped)")
            }
        }
        if let answer = batch.answer(for: "mutation_intent")?.choiceValue {
            let mapped = map.intent.mutationIntent.rawValue
            if answer != mapped {
                lines.append("decision 'mutation_intent' says \(answer) but the map reads \(mapped)")
            }
        }
        if let answer = batch.answer(for: "ambiguity")?.scoreValue {
            let mapped = map.intent.ambiguous ? "high" : "low"
            if answer != mapped {
                lines.append("decision 'ambiguity' scores \(answer) but the map reads \(mapped)")
            }
        }
        return lines
    }

    /// Divergences between a configured engine's batch and the deterministic
    /// view of the same state. Agreement is silence; each disagreement names
    /// the question and both answers. Only called when the two engines differ,
    /// so the deterministic self-comparison never costs a line.
    public static func engineDivergence(
        configured: DecisionBatch,
        deterministic: DecisionBatch
    ) -> [String] {
        var lines: [String] = []
        for answer in deterministic.answers {
            guard let other = configured.answer(for: answer.questionID) else { continue }
            if other.kind != answer.kind {
                lines.append(
                    "decision '\(answer.questionID)': \(configured.engineID) said "
                        + "\(other.kindDescription), deterministic said \(answer.kindDescription)"
                )
            }
        }
        return lines
    }
}
