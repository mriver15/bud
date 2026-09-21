import Foundation

/// The configured-LLM fallback: the same typed batch, evaluated by the session
/// provider instead of by rules.
///
/// Used for the questions the deterministic engine does not own, or for soft
/// judgments a rule cannot make. The contract stays typed — the model is asked
/// for JSON in the batch's own shape, and anything that does not parse fails
/// the whole evaluation rather than being guessed at. Bud never depends on
/// this engine: the harness routes to it, nothing fails when it is not there.
public struct ProviderDecisionEngine: DecisionEngine {
    public var id: String { "provider" }

    private let backend: any ChatBackend
    private let model: String
    /// Where the decision call's token spend is reported, so a per-round
    /// classifier does not make the session's usage accounting lie.
    public var onUsage: (@Sendable (Int, Int) -> Void)?

    public init(
        backend: any ChatBackend,
        model: String,
        onUsage: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.backend = backend
        self.model = model
        self.onUsage = onUsage
    }

    public func evaluate(
        state: DecisionState,
        questions: [DecisionQuestion]
    ) async throws -> DecisionBatch {
        guard !questions.isEmpty else {
            return DecisionBatch(engineID: id, answers: [])
        }

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: Self.prompt(state: state, questions: questions)),
            ],
            tools: [],
            temperature: 0,
            maxTokens: 1_200,
            reasoningEffort: nil
        )

        var text = ""
        for try await event in backend.stream(request) {
            switch event {
            case .contentDelta(let delta):
                text += delta
            case .usage(let prompt, let completion, _):
                onUsage?(prompt, completion)
            default:
                break
            }
        }
        return try Self.parse(text, questions: questions)
    }

    // MARK: - Prompt

    private static let systemPrompt = """
        You answer typed questions about a single user request. Reply with exactly \
        one JSON object and nothing else:
        {"answers":[{"id": "<question id>", "value": <bool or string>, \
        "confidence": <number 0 to 1>}]}

        A boolean question wants true or false. A choice question wants one of its \
        options, exactly as spelled. A score question wants one of its levels, \
        exactly as spelled. Never invent ids; answer only the questions asked.
        """

    private static func prompt(state: DecisionState, questions: [DecisionQuestion]) -> String {
        let stateJSON = [
            "query": state.query,
            "surface": state.surface ?? "",
            "attachments": state.attachmentPaths,
            "recent_tools": state.recentToolNames,
            "connected_servers": state.connectedServers,
            "direct_capabilities": state.directCapabilities,
            "memory_candidates": state.memoryCandidates,
            "round": state.round,
        ] as [String: Any]
        let questionsJSON = questions.map { question -> [String: Any] in
            switch question {
            case .boolean(let id, let instructions, let criteria):
                var item: [String: Any] = ["id": id, "type": "boolean", "instructions": instructions]
                if let criteria {
                    item["criteria"] = ["true": criteria.yes, "false": criteria.no]
                }
                return item
            case .choice(let id, let options, let instructions, let criteria):
                var item: [String: Any] = [
                    "id": id, "type": "choice", "options": options, "instructions": instructions,
                ]
                if let criteria, !criteria.isEmpty {
                    item["criteria"] = criteria
                }
                return item
            case .score(let id, let levels, let instructions):
                return ["id": id, "type": "score", "levels": levels, "instructions": instructions]
            }
        }
        let body = ["state": stateJSON, "questions": questionsJSON] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    // MARK: - Parsing

    /// Tolerant about everything except the answer itself: leading prose and
    /// trailing notes are skipped, but an answer that does not fit its
    /// question's type is a failure, not a guess.
    static func parse(_ text: String, questions: [DecisionQuestion]) throws -> DecisionBatch {
        guard let objectStart = text.firstIndex(of: "{"),
              let objectEnd = text.lastIndex(of: "}"), objectEnd > objectStart
        else {
            throw DecisionParseError.notJSON
        }
        let candidate = String(text[objectStart...objectEnd])
        guard let data = candidate.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawAnswers = object["answers"] as? [[String: Any]]
        else {
            throw DecisionParseError.notJSON
        }

        var answers: [DecisionAnswer] = []
        for raw in rawAnswers {
            guard let id = raw["id"] as? String,
                  let question = questions.first(where: { $0.id == id })
            else { continue }
            let confidence = (raw["confidence"] as? Double) ?? 0.8
            guard let kind = answerKind(for: question, value: raw["value"]) else {
                throw DecisionParseError.wrongType(id: id)
            }
            answers.append(
                DecisionAnswer(
                    questionID: id, kind: kind, confidence: confidence,
                    rationale: "provider judgment"
                )
            )
        }
        return DecisionBatch(engineID: "provider", answers: answers)
    }

    private static func answerKind(
        for question: DecisionQuestion,
        value: Any?
    ) -> DecisionAnswer.Kind? {
        switch (question, value) {
        case (.boolean, let flag as Bool):
            return .boolean(flag)
        case (.choice(_, let options, _, _), let text as String) where options.contains(text):
            return .choice(text)
        case (.score(_, let levels, _), let text as String) where levels.contains(text):
            return .score(text)
        default:
            return nil
        }
    }
}

enum DecisionParseError: Error, LocalizedError {
    case notJSON
    case wrongType(id: String)

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "The decision engine did not return a JSON object."
        case .wrongType(let id):
            return "The decision engine answered '\(id)' with a value that does not fit its type."
        }
    }
}
