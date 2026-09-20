import Foundation

/// Ranked, budgeted retrieval over the cognitive store (§4.3 of the roadmap).
///
/// The pipeline, in order: exact subject/entity matches, bounded graph
/// neighbors, FTS lexical candidates, in-scope directives — then merge, score
/// (relevance, with episode salience as a multiplier and ties broken toward
/// newer rows), and selection within a character budget. Retrieval is ranked,
/// never binary: zero lexical overlap does not imply irrelevance, so what
/// misses the budget is counted in the result's tail rather than silently
/// dropped from every trace.
public enum MemoryRetriever {
    public static func retrieve(
        query: String,
        scope: String? = nil,
        budget: Int = 800,
        maxCandidates: Int = 8
    ) -> [MemoryCandidate] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, budget > 0, maxCandidates > 0 else { return [] }

        let terms = TextRanking.tokens(in: query)
        guard !terms.isEmpty else { return [] }

        struct Entry {
            let id: String
            let text: String
            let score: Double
            let reason: String
            let kindRank: Int
            let refID: Int
        }

        var entries: [Entry] = []
        var seen: Set<String> = []
        func add(_ kind: String, _ kindRank: Int, _ refID: Int, _ text: String, _ score: Double, _ reason: String) {
            let key = "\(kind):\(refID)"
            guard seen.insert(key).inserted else { return }
            entries.append(Entry(id: key, text: text, score: score, reason: reason, kindRank: kindRank, refID: refID))
        }

        // 1. Exact subject matches: an assertion about exactly what was asked.
        for term in terms {
            for fact in CognitiveStore.activeFacts(subject: term, limit: 4) {
                add("fact", 0, fact.id, "\(fact.subject): \(fact.value)", 1.0, "exact subject '\(term)'")
            }
        }

        // 2. Graph neighbors: entities the query names pull in the facts about
        // what they connect to, bounded to two hops and a small node count.
        var neighborSubjects: Set<String> = []
        for term in terms {
            guard let entity = CognitiveStore.entity(named: term) else { continue }
            neighborSubjects.insert(entity.canonicalName)
            for neighbor in CognitiveStore.neighbors(of: entity.id, depth: 2, maxNodes: 8) {
                neighborSubjects.insert(neighbor.canonicalName)
            }
        }
        for subject in neighborSubjects {
            for fact in CognitiveStore.activeFacts(subject: subject, limit: 3) {
                add("fact", 0, fact.id, "\(fact.subject): \(fact.value)", 0.9, "graph neighbor '\(subject)'")
            }
        }

        // 3. FTS lexical: what the words match beyond exact subjects.
        for hit in CognitiveStore.search(query, limit: 12) {
            let kindRank = hit.kind == "episode" ? 1 : 0
            add(hit.kind, kindRank, hit.refID, hit.text, hit.score, "lexical match")
        }

        // 4. Directives: durable instructions admit themselves when the query
        // speaks their language, and always when a scope is in play.
        for directive in CognitiveStore.directives() {
            let shares = terms.contains { TextRanking.tokens(in: directive.text).contains($0) }
            guard shares || scope != nil else { continue }
            add("directive", 0, directive.id, directive.text, shares ? 0.9 : 0.7, "active directive")
        }

        // Merge, weight, order. Episode salience scales its score; equal scores
        // prefer canonical kinds (fact/directive over episode) and, among
        // equals, the newer row.
        let weighted = entries.map { entry -> Entry in
            var score = entry.score
            if entry.id.hasPrefix("episode:"),
               let salience = CognitiveStore.episodeSalience(id: entry.refID) {
                score *= salience
            }
            return Entry(
                id: entry.id, text: entry.text, score: score,
                reason: entry.reason, kindRank: entry.kindRank, refID: entry.refID
            )
        }
        let ordered = weighted.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.kindRank != right.kindRank { return left.kindRank < right.kindRank }
            return left.refID > right.refID
        }

        // Token-budget selection: canonical facts before episodes, and whatever
        // misses the budget is what the budget says no to — the map still
        // records the candidates as provenance.
        var candidates: [MemoryCandidate] = []
        var remaining = budget
        for entry in ordered.prefix(maxCandidates) {
            let text = entry.text.count <= remaining ? entry.text : String(entry.text.prefix(remaining))
            guard !text.isEmpty else { continue }
            candidates.append(
                MemoryCandidate(
                    id: entry.id,
                    characters: text.count,
                    reason: "\(entry.reason), score " + String(format: "%.2f", entry.score),
                    text: text
                )
            )
            remaining -= text.count
        }
        return candidates
    }
}
