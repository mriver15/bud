import Foundation

/// Turns capability wording into an agent, locally and deterministically.
///
/// The roster itself never reaches the parent prompt (§6.2 of the roadmap):
/// the model hands `spawn_subagents` a capability string — "competitive pokemon
/// analysis" — or an agent name, and this resolves it against the roster the
/// app already holds. Exact names always win. Then the words an agent's author
/// declared for it, then a wording the decision engine placed earlier, and only
/// after all three does it fall back to word overlap against each agent's name,
/// summary and declared aliases. A low-confidence match is refused with the two
/// closest names rather than guessed: running the wrong agent is a whole
/// conversation wasted, while one refusal costs a round trip.
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

    /// The form a wording is stored and compared in: case and surrounding space
    /// are the model's, not the roster's, and two spellings of one phrase must
    /// be one row in the learned table and one key in the session's cache.
    public static func normalize(_ wording: String) -> String {
        wording.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// - Parameter learned: wordings an earlier decision placed, from
    ///   ``BudStore/delegateAliases()``. Read as evidence for this roster only:
    ///   a mapping naming an agent that is not in `agents` is ignored, so an
    ///   uninstalled skill cannot keep collecting work through what it taught.
    public static func resolve(
        _ capability: String,
        agents: [AgentDefinition],
        learned: [String: String] = [:]
    ) -> Resolution {
        let query = normalize(capability)
        guard !query.isEmpty else {
            return Resolution(agentID: nil, candidates: [], confidence: 0, reason: "no capability named")
        }

        // An exact agent name is the model speaking the roster's language.
        if let exact = agents.first(where: { $0.name.lowercased() == query }) {
            return Resolution(
                agentID: exact.name, candidates: [], confidence: 0.99, reason: "exact agent name"
            )
        }

        // The words its author says people use for it. Not a guess: this is the
        // one signal here that comes from whoever knows what the agent is for.
        if let declared = agents.first(where: { agent in
            agent.aliases.contains { normalize($0) == query }
        }) {
            return Resolution(
                agentID: declared.name,
                candidates: [],
                confidence: 0.97,
                reason: "'\(query)' is a name '\(declared.name)' declares for itself"
            )
        }

        // A wording the decision engine placed before. Below a declared name and
        // below the roster's own names, because it is second-hand: the engine's
        // answer to this phrase, not the phrase's meaning.
        if let placed = learned[query], agents.contains(where: { $0.name == placed }) {
            return Resolution(
                agentID: placed,
                candidates: [],
                confidence: 0.95,
                reason: "the decision engine placed this wording with '\(placed)'"
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
            let vocabulary = Set(words(of: agent, learned: learned))
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

    /// Everything about an agent that a capability can be matched against: its
    /// name, what it says it does, the names its author gave it, and the wordings
    /// the engine has already placed with it.
    ///
    /// The learned wordings are the point of the table. "Competitive pokemon
    /// analysis" placed with one agent puts `competitive`, `pokemon` and
    /// `analysis` in that agent's vocabulary, so the next task phrased as "pokemon
    /// metagame check" overlaps on evidence rather than falling to the engine
    /// again. Bounded by what the engine has actually answered, so the vocabulary
    /// grows from placements rather than from guesses.
    private static func words(of agent: AgentDefinition, learned: [String: String]) -> [String] {
        var text = agent.name + " " + agent.summary + " " + agent.aliases.joined(separator: " ")
        for (wording, name) in learned where name == agent.name {
            text += " " + wording
        }
        return CapabilityIndex.words(text)
    }
}
