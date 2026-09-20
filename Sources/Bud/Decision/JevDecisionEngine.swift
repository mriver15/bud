import Foundation

/// The TypeSafe Jev adapter: the same typed batch contract, evaluated by a
/// System One model over HTTP.
///
/// Jev does not generate text — it answers typed questions (yes/no
/// probabilities, choices, scores) against a state, which is exactly the
/// `DecisionQuestion` shape. The mapping is direct:
/// - boolean → `noul`, answered true when the yes-probability is ≥ 0.5, with
///   confidence derived from the distance to 0.5 (Jev reports none for noul);
/// - choice → `choice`, with Jev's own confidence;
/// - score → `score`, a probability-weighted level index rounded to the
///   nearest level, with Jev's own confidence.
///
/// Failures throw — the coordinator's deterministic fallback is the floor —
/// and the response's token usage is reported through `onUsage`. Rate-limit
/// and overload responses (429/529) get one delayed retry, which is what the
/// official SDKs do by default.
public struct JevDecisionEngine: DecisionEngine {
    public var id: String { "jev" }

    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!
    public static let defaultModel = "jev-latest"

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let session: URLSession
    /// Where the decision call's token spend is reported, so a per-round
    /// classifier does not make the session's usage accounting lie.
    public var onUsage: (@Sendable (Int, Int) -> Void)?

    public init(
        apiKey: String,
        baseURL: URL = JevDecisionEngine.defaultBaseURL,
        model: String = JevDecisionEngine.defaultModel,
        session: URLSession = .shared,
        onUsage: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.onUsage = onUsage
    }

    public func evaluate(
        state: DecisionState,
        questions: [DecisionQuestion]
    ) async throws -> DecisionBatch {
        guard !apiKey.isEmpty else { throw JevError.noKey }
        guard !questions.isEmpty else {
            return DecisionBatch(engineID: id, answers: [])
        }

        let body = Self.requestBody(state: state, model: model, questions: questions)
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = body.encodedString().data(using: .utf8)

        // One delayed retry on rate-limit and overload, the SDKs' default.
        let (data, response) = try await perform(request, retriesRemaining: 1)
        guard let http = response as? HTTPURLResponse else {
            throw JevError.transport("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw JevError.http(status: http.statusCode, body: bodyText)
        }

        guard let root = JSONValue(parsing: String(data: data, encoding: .utf8) ?? "") else {
            throw JevError.malformed("not JSON")
        }
        if let input = root["usage"]?["input_tokens"]?.doubleValue,
           let output = root["usage"]?["output_tokens"]?.doubleValue {
            onUsage?(Int(input), Int(output))
        }
        guard let rawAnswers = root["answers"]?.objectValue else {
            throw JevError.malformed("no answers object")
        }

        var answers: [DecisionAnswer] = []
        for question in questions {
            guard let raw = rawAnswers[question.id] else { continue }
            guard let (kind, confidence) = Self.map(raw, question: question) else {
                throw JevError.malformed("answer '\(question.id)' does not fit its question type")
            }
            answers.append(
                DecisionAnswer(
                    questionID: question.id,
                    kind: kind,
                    confidence: confidence,
                    rationale: "jev \(root["model"]?.stringValue ?? model)"
                )
            )
        }
        return DecisionBatch(engineID: id, answers: answers)
    }

    private func perform(
        _ request: URLRequest,
        retriesRemaining: Int
    ) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            // One delayed retry on rate-limit and overload — the official SDKs'
            // default policy, and the only statuses worth repeating.
            if let http = response as? HTTPURLResponse,
               (http.statusCode == 429 || http.statusCode == 529),
               retriesRemaining > 0 {
                try await Task.sleep(for: .seconds(1.5))
                return try await perform(request, retriesRemaining: retriesRemaining - 1)
            }
            return (data, response)
        } catch {
            throw JevError.transport(error.localizedDescription)
        }
    }

    // MARK: - Mapping

    static func requestBody(
        state: DecisionState,
        model: String,
        questions: [DecisionQuestion]
    ) -> JSONValue {
        var questionMap: [String: JSONValue] = [:]
        for question in questions {
            switch question {
            case .boolean(let id, let instructions):
                questionMap[id] = .object([
                    "type": .string("noul"),
                    "instructions": .string(instructions),
                ])
            case .choice(let id, let options, let instructions):
                // Criteria maps option to rubric; null means "no extra detail".
                var criteria: [String: JSONValue] = [:]
                for option in options { criteria[option] = .null }
                questionMap[id] = .object([
                    "type": .string("choice"),
                    "instructions": .string(instructions),
                    "criteria": .object(criteria),
                ])
            case .score(let id, let levels, let instructions):
                questionMap[id] = .object([
                    "type": .string("score"),
                    "instructions": .string(instructions),
                    "criteria": .array(levels.map { .string($0) }),
                ])
            }
        }
        let stateObject: JSONValue = .object([
            "query": .string(state.query),
            "surface": state.surface.map { .string($0) } ?? .null,
            "attachments": .array(state.attachmentPaths.map { .string($0) }),
            "recent_tools": .array(state.recentToolNames.map { .string($0) }),
            "connected_servers": .array(state.connectedServers.map { .string($0) }),
            "round": .number(Double(state.round)),
        ])
        return .object([
            "state": stateObject,
            "model": .string(model),
            "questions": .object(questionMap),
        ])
    }

    static func map(
        _ raw: JSONValue,
        question: DecisionQuestion
    ) -> (DecisionAnswer.Kind, Double)? {
        guard raw["type"]?.stringValue != nil else { return nil }
        switch question {
        case .boolean:
            guard raw["type"]?.stringValue == "noul",
                  let yes = raw["noul"]?.doubleValue else { return nil }
            // No confidence field on noul answers: derive from the distance to
            // the 0.5 boundary — a coin flip is no evidence, a 0.95 is strong.
            return (.boolean(yes >= 0.5), 0.5 + abs(yes - 0.5))

        case .choice(_, let options, _):
            guard raw["type"]?.stringValue == "choice",
                  let chosen = raw["choice"]?.stringValue,
                  options.contains(chosen),
                  let confidence = raw["confidence"]?.doubleValue
            else { return nil }
            return (.choice(chosen), confidence)

        case .score(_, let levels, _):
            guard raw["type"]?.stringValue == "score",
                  let value = raw["score"]?.doubleValue,
                  !levels.isEmpty,
                  let confidence = raw["confidence"]?.doubleValue
            else { return nil }
            let index = min(max(Int(value.rounded()), 0), levels.count - 1)
            return (.score(levels[index]), confidence)
        }
    }
}

enum JevError: Error, LocalizedError {
    case noKey
    case transport(String)
    case http(status: Int, body: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No TypeSafe API key. Add one in Settings › Limits."
        case .transport(let message):
            return "TypeSafe is unreachable: \(message)"
        case .http(let status, let body):
            let trimmed = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "TypeSafe returned HTTP \(status): \(trimmed)"
        case .malformed(let message):
            return "TypeSafe answered outside the typed contract: \(message)"
        }
    }
}
