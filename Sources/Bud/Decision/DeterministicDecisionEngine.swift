import Foundation

/// The always-available decision backend: typed answers over the same
/// deterministic rules `RequestAnalyzer` uses, so the decision layer and the
/// map can never disagree for the same state.
///
/// No network, no configuration, no failure modes — this is what keeps Bud
/// fully functional without any classifier, which the roadmap lists as a
/// release gate. Questions whose ids it does not recognise are left
/// unanswered in the batch, and the caller decides whether to fall back to a
/// provider engine for the gap.
public struct DeterministicDecisionEngine: DecisionEngine {
    public var id: String { "deterministic" }

    public init() {}

    public func evaluate(
        state: DecisionState,
        questions: [DecisionQuestion]
    ) async throws -> DecisionBatch {
        let query = state.query.lowercased()

        var answers: [DecisionAnswer] = []
        for question in questions {
            guard let answer = answer(question, state: state, query: query) else { continue }
            answers.append(answer)
        }
        return DecisionBatch(engineID: id, answers: answers)
    }

    private func answer(
        _ question: DecisionQuestion,
        state: DecisionState,
        query: String
    ) -> DecisionAnswer? {
        switch question.id {
        case "needs_files":
            let files = !state.attachmentPaths.isEmpty
                || !RequestAnalyzer.paths(in: state.query, excluding: RequestAnalyzer.urls(in: state.query)).isEmpty
                || contains(query, ["file", "files", "folder", "directory", "read", "edit"])
            return .boolean(id: question.id, value: files,
                            confidence: 0.9,
                            rationale: files ? "a file, path or file verb is in the request" : "no file signal")

        case "needs_browser":
            let browsing = ToolPlanner.hasBrowserIntent(query: query, surface: state.surface)
            return .boolean(id: question.id, value: browsing,
                            confidence: 0.9,
                            rationale: browsing ? "the request reads as a browse task" : "no browse signal")

        case "needs_web":
            let web = !RequestAnalyzer.urls(in: state.query).isEmpty
                || ToolPlanner.hasBrowserIntent(query: query, surface: state.surface)
            return .boolean(id: question.id, value: web,
                            confidence: 0.9,
                            rationale: web ? "a URL or web intent is present" : "no web signal")

        case "needs_memory":
            let memory = contains(query, ["remember", "recall", "note", "notes", "prefer",
                                          "preference", "what you know", "about me"])
            return .boolean(id: question.id, value: memory,
                            confidence: 0.85,
                            rationale: memory ? "the request reaches for remembered context" : "no memory signal")

        case "needs_ui":
            let ui = contains(query, ["dashboard", "chart", "table", "compare", "comparison",
                                      "visualize", "visualise", "graph", "plot", "metrics",
                                      "sparkline", "histogram"])
            return .boolean(id: question.id, value: ui,
                            confidence: 0.9,
                            rationale: ui ? "the request names a presentation outcome" : "no presentation signal")

        case "needs_delegate":
            let namedServer = state.connectedServers.contains {
                ToolPlanner.matchesQuery(name: $0, query: query)
            }
            let delegation = namedServer
                || contains(query, ["delegate", "hand off", "handoff", "in parallel",
                                    "subagent", "workstream", "split into"])
            return .boolean(id: question.id, value: delegation,
                            confidence: 0.85,
                            rationale: delegation ? "a server is named or the request asks to hand work off" : "no delegation signal")

        case "complexity":
            let stepCount = RequestAnalyzer.stepMarkers(in: query)
            let urlCount = RequestAnalyzer.urls(in: state.query).count
            let level = RequestAnalyzer.complexityLevel(
                queryCount: state.query.count,
                stepCount: stepCount,
                round: state.round,
                trivialSafe: urlCount == 0 && state.attachmentPaths.isEmpty
                    && !contains(query, ["browse", "table", "chart", "compare", "write", "edit", "run"])
            )
            return .choice(id: question.id, value: level.rawValue,
                           confidence: 0.85,
                           rationale: "\(stepCount) step markers, round \(state.round)")

        case "mutation_intent":
            let intent = RequestAnalyzer.mutationIntent(in: query)
            return .choice(id: question.id, value: intent.rawValue,
                           confidence: 0.85,
                           rationale: "verb reading of the request")

        case "primary_domain":
            // The deterministic reading: the group the query names, or the
            // strongest situational group. The engine answers with an option
            // the caller offered, or stays silent when none fits.
            guard case .choice(let id, let options, _) = question else { return nil }
            let named = options.first { ToolPlanner.matchesQuery(name: $0, query: query) }
            let situational: String?
            if ToolPlanner.hasBrowserIntent(query: query, surface: state.surface),
               options.contains(ToolPlanner.browserProviderName) {
                situational = ToolPlanner.browserProviderName
            } else if contains(query, ["dashboard", "chart", "table", "compare"]),
                      options.contains("Interface") {
                situational = "Interface"
            } else {
                situational = nil
            }
            guard let domain = named ?? situational else { return nil }
            return .choice(id: id, value: domain,
                           confidence: named != nil ? 0.95 : 0.85,
                           rationale: named != nil ? "the request names the group" : "situational group from request signals")

        case "ambiguity":
            let ambiguous = RequestAnalyzer.isAmbiguous(query)
            return .score(id: question.id, value: ambiguous ? "high" : "low",
                          confidence: 0.85,
                          rationale: ambiguous ? "an open choice or bare question" : "reads as a single ask")

        default:
            return nil
        }
    }

    private func contains(_ text: String, _ words: [String]) -> Bool {
        words.contains { word in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                       options: [.regularExpression]) != nil
        }
    }
}

private extension DecisionAnswer {
    static func boolean(id: String, value: Bool, confidence: Double, rationale: String) -> DecisionAnswer {
        DecisionAnswer(questionID: id, kind: .boolean(value), confidence: confidence, rationale: rationale)
    }

    static func choice(id: String, value: String, confidence: Double, rationale: String) -> DecisionAnswer {
        DecisionAnswer(questionID: id, kind: .choice(value), confidence: confidence, rationale: rationale)
    }

    static func score(id: String, value: String, confidence: Double, rationale: String) -> DecisionAnswer {
        DecisionAnswer(questionID: id, kind: .score(value), confidence: confidence, rationale: rationale)
    }
}
