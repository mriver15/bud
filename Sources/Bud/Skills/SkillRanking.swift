import Foundation

/// Which installed skills a message looks like it needs.
///
/// The catalogue of installed skills rides in the system prompt, and it grows with
/// every install: twenty skills is roughly ten thousand characters on every
/// request, which is more than a third of the built-in tool block. The obvious
/// saving is to list only the relevant ones — and the obvious saving is wrong.
///
/// Measured against the nineteen real skills in the source this app ships, with
/// fourteen messages a person would actually type:
///
/// ```
/// "Fill in a fillable PDF form"      → pdf   #1
/// "Fill out this W-9 form for me"    → pdf   never scored
/// ```
///
/// Thirteen of the fourteen ranked first. The one that scored nothing is the one
/// that matters: a W-9 *is* a PDF form, and no amount of term matching knows that.
/// The model does. So this ranks, and the catalogue **keeps every skill listed** —
/// the ones that score get their full description, and the rest get one line. A
/// filter would have silently dropped the skill that was right.
public enum SkillRanking {
    /// How many get their full description.
    ///
    /// Three, from what was measured rather than from symmetry: across fourteen
    /// real messages the right skill was first **every time it was found at all**,
    /// so the second and third places are there for a message that genuinely spans
    /// skills, and the fourth and fifth were covering noise.
    public static let promote = 3

    /// How close to the best match a skill has to be to get its whole description.
    /// Half is loose enough that a message spanning two skills promotes both, and
    /// tight enough that the tail of incidental words is left as one line each.
    private static let relevanceFloor = 0.5

    /// Skill names, most relevant first. Only those that scored at all, and only
    /// those near the best.
    public static func rank(_ query: String, skills: [Skill], limit: Int = promote) -> [String] {
        let terms = TextRanking.tokens(in: query)
        guard !terms.isEmpty, !skills.isEmpty else { return [] }

        let documents = skills.map { document(for: $0) }
        let base = TextRanking.scores(terms: terms, documents: documents)

        let message = query.lowercased()
        var scored: [(name: String, score: Double)] = []
        for (index, skill) in skills.enumerated() {
            var score = base[index]
            // A word the author said users would use, actually used. Worth more than
            // any amount of overlap, because it is the one signal here that is not a
            // guess: the author knows what this skill is called by the people who
            // need it.
            if skill.triggerAliases.contains(where: { message.contains($0.lowercased()) }) {
                score *= 3
            }
            if score > 0 { scored.append((skill.name, score)) }
        }

        let ordered = scored.sorted { $0.score > $1.score }
        // Only what is in the same league as the best match. Measured on a message
        // that matched nothing at all: the top five still promoted, each on the
        // strength of one incidental word, and the catalogue spelled out five
        // descriptions of skills the message had nothing to do with. A ranking that
        // is noise should promote nothing and cost nothing.
        guard let best = ordered.first?.score, best > 0 else { return [] }
        return ordered
            .prefix(limit)
            .filter { $0.score >= best * relevanceFloor }
            .map(\.name)
    }

    // MARK: - Text

    /// The text a skill is matched on: its name, what it says it is for, and the
    /// words its author says people use for it.
    private static func document(for skill: Skill) -> [String] {
        TextRanking.tokens(in: skill.name.replacingOccurrences(of: "-", with: " ")
            + " " + skill.summary
            + " " + skill.triggers)
    }
}

// MARK: - Text matching

/// The text matching that both rankings are built on.
///
/// `SkillRanking` scores installed skills against a message; `BudStore` scores
/// saved notes against the conversation they sit in front of. That is the same
/// problem twice — a short query against a small catalogue, where the answer is
/// an order rather than a selection — so the token split and the weighting live
/// here once instead of being written twice and drifting apart.
enum TextRanking {
    /// IDF-weighted term overlap, one score per document, in the same order.
    ///
    /// A word that appears in nearly every document says nothing about which one
    /// the query is about, so it is discounted by how many documents carry it; a
    /// word a document repeats counts for more than one it mentions once. That is
    /// the whole of the judgement, and it is deliberately crude — the caller
    /// decides what a score is worth, including discarding it.
    static func scores(terms: [String], documents: [[String]]) -> [Double] {
        guard !terms.isEmpty, !documents.isEmpty else { return documents.map { _ in 0 } }

        var frequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { frequency[term, default: 0] += 1 }
        }
        let total = Double(documents.count)
        let distinct = Set(terms)

        return documents.map { document in
            var score = 0.0
            for term in distinct where document.contains(term) {
                let df = Double(frequency[term] ?? 1)
                score += log(1 + total / df) * (1 + log(Double(document.count { $0 == term })))
            }
            return score
        }
    }

    static func tokens(in text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    /// Words that appear in enough documents to carry no signal, plus the ones
    /// every English sentence has. IDF would discount most of these on its own;
    /// naming them keeps a one-document catalogue from scoring everything equally.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "for", "to", "of", "in", "on", "with", "is",
        "it", "this", "that", "these", "those", "i", "me", "my", "you", "your", "we",
        "can", "make", "use", "uses", "using", "used", "how", "do", "does", "please",
        "help", "need", "want", "from", "into", "be", "as", "at", "by", "so", "if",
        "would", "could", "should", "about", "any", "when", "what", "which", "there",
        "their", "them", "they", "its", "was", "are", "has", "have", "will", "not",
        "skill", "skills", "user", "users", "work", "works", "working", "new",
    ]
}
