import Foundation

/// Turns capability wording into an agent, locally and deterministically.
///
/// The roster itself never reaches the parent prompt (§6.2 of the roadmap):
/// the model hands `spawn_subagents` a capability string — "competitive pokemon
/// analysis" — or an agent name, and this resolves it against the roster the
/// app already holds. Exact names always win; a capability is matched by word
/// overlap against each agent's name and summary, and a low-confidence match is
/// refused with the two closest names rather than guessed: running the wrong
/// agent is a whole conversation wasted, while one refusal costs a round trip.
public enum DelegateResolver {
    public struct Resolution: Sendable, Equatable {
        /// The chosen agent, when the match was confident enough to act on.
        public var agentID: String?
        /// The closest names, for the clarification/refusal path.
        public var candidates: [String]
        public var confidence: Double
        public var reason: String

        public init(
            agentID: String?,
            candidates: [String],
            confidence: Double,
            reason: String
        ) {
            self.agentID = agentID
            self.candidates = candidates
            self.confidence = confidence
            self.reason = reason
        }
    }

    /// The activation band a resolution must reach before it may choose the
    /// agent: at or above this the match is trusted, below it the resolution
    /// returns candidates for the caller to offer as a choice.
    public static let activateThreshold = 0.85

    public static func resolve(_ capability: String, agents: [AgentDefinition]) -> Resolution {
        let query = capability.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Resolution(agentID: nil, candidates: [], confidence: 0, reason: "no capability named")
        }

        // An exact agent name is the model speaking the roster's language.
        if let exact = agents.first(where: { $0.name.lowercased() == query }) {
            return Resolution(
                agentID: exact.name, candidates: [], confidence: 0.99, reason: "exact agent name"
            )
        }

        let queryWords = Set(CapabilityIndex.words(query))
        guard !queryWords.isEmpty else {
            return Resolution(agentID: nil, candidates: [], confidence: 0, reason: "no matchable words")
        }

        struct Score {
            let name: String
            let confidence: Double
            let overlap: Int
        }
        var scored: [Score] = []
        for agent in agents {
            let vocabulary = Set(
                CapabilityIndex.words(agent.name) + CapabilityIndex.words(agent.summary)
            )
            let overlap = queryWords.filter { vocabulary.contains($0) }
            guard !overlap.isEmpty else { continue }
            let ratio = Double(overlap.count) / Double(queryWords.count)
            scored.append(
                Score(
                    name: agent.name,
                    confidence: min(0.55 + 0.44 * ratio, 0.99),
                    overlap: overlap.count
                )
            )
        }
        let ranked = scored.sorted { $0.confidence > $1.confidence }
        guard let best = ranked.first else {
            return Resolution(
                agentID: nil, candidates: [], confidence: 0, reason: "no agent shares words with the capability"
            )
        }

        let candidates = ranked.prefix(2).map(\.name)
        guard best.confidence >= activateThreshold else {
            return Resolution(
                agentID: nil,
                candidates: candidates,
                confidence: best.confidence,
                reason: "\(best.overlap) of \(queryWords.count) words match '\(best.name)'; below the activation band"
            )
        }
        return Resolution(
            agentID: best.name,
            candidates: candidates,
            confidence: best.confidence,
            reason: "\(best.overlap) of \(queryWords.count) words match"
        )
    }
}
