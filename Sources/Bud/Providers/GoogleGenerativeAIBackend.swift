import Foundation

/// Client for Google's Gemini dialect — `POST {base}/v1beta/models/{model}:streamGenerateContent`.
///
/// Gemini is not a chat-completions clone with different field names; four things
/// are structurally different and are the reason this file exists rather than a
/// translation table:
///
/// - The model is a path segment, not a body field, and the resource name is
///   `models/{id}` whether or not the caller already spelled the `models/` prefix.
/// - Roles are `user` / `model`, and developer instructions live in a separate
///   top-level `systemInstruction` field rather than in the message list.
/// - Tool calls do not stream as argument fragments keyed by index the way OpenAI
///   does it. A call arrives complete, in one `functionCall` part, so there is
///   nothing to reassemble — and a tool result goes back as a `functionResponse`
///   part inside a `user` turn, not as a `tool` role.
/// - Tool parameter schemas are not JSON Schema: they are Google's `Schema`
///   message, a documented subset. Unknown keywords such as `additionalProperties`
///   are rejected outright, so schemas are rebuilt from the supported fields.
///
/// Documents used: <https://ai.google.dev/api/generate-content> (the REST
/// reference for `models.streamGenerateContent`, `Content`, `Part`, `Tool`,
/// `FunctionDeclaration`, `Schema`, `FinishReason`, `UsageMetadata`,
/// `PromptFeedback`), <https://ai.google.dev/gemini-api/docs/text-generation>,
/// <https://ai.google.dev/gemini-api/docs/function-calling> and
/// <https://ai.google.dev/gemini-api/docs/api-key>.
public struct GoogleGenerativeAIBackend: ChatBackend {
    private let provider: ProviderDescriptor
    private let credentials: ProviderCredentials

    public init(provider: ProviderDescriptor, credentials: ProviderCredentials) {
        self.provider = provider
        self.credentials = credentials
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, into: continuation)
                } catch is CancellationError {
                    // User pressed stop; not an error worth surfacing.
                } catch let error as ChatBackendError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ChatBackendError.transport(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    private func run(
        _ request: ChatRequest,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        if provider.requiresKey, credentials.apiKey.isEmpty {
            throw ChatBackendError.missingKey(provider: provider.name)
        }

        var req = URLRequest(url: try endpoint(for: request.model))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The header rather than the `?key=` query parameter: both are accepted,
        // but the API-key guide's REST examples use the header, and a key in a URL
        // ends up in logs and error transcripts.
        if !credentials.apiKey.isEmpty {
            req.setValue(credentials.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        for (name, value) in credentials.extraHeaders {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.httpBody = try Self.requestBody(for: request)

        let (bytes, response) = try await ProviderHTTP.session.bytes(for: req)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // A Google error body is JSON, but a proxy in front of it can still
            // serve an HTML page, so the shared bounded drain is used.
            let body = await ProviderHTTP.errorBody(bytes)
            throw ChatBackendError.http(status: http.statusCode, body: body)
        }

        var decoder = Self.GoogleStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try decoder.events(fromLine: line) {
                continuation.yield(event)
            }
        }

        // Usage trails the finish frame often enough — and arrives without any
        // candidate at all — that it is flushed here rather than dropped.
        if let usage = decoder.pendingUsage { continuation.yield(usage) }

        // A blocked prompt and a genuine end-of-answer both come back as HTTP 200.
        // Reporting the first as an empty successful stream would leave the agent
        // loop answering with nothing and no explanation.
        if !decoder.producedOutput {
            throw ChatBackendError.decoding(decoder.emptyResponseExplanation())
        }
    }

    private func endpoint(for model: String) throws -> URL {
        var base = credentials.resolvedBaseURL(for: provider)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else {
            throw ChatBackendError.transport("No base URL set for \(provider.name).")
        }
        let path = "\(base)/v1beta/\(Self.modelResourcePath(model)):streamGenerateContent?alt=sse"
        guard let url = URL(string: path) else {
            throw ChatBackendError.transport("Invalid base URL: \(base)")
        }
        return url
    }

    /// The `models/{model}` resource path, from either spelling of the id.
    ///
    /// Callers hold ids like `models/gemini-2.5-pro` about as often as bare ones
    /// (`ProviderRegistry`'s Google entry prefills the bare `gemini-2.5-pro`), so
    /// prefixing naively produces `models/models/…`, which 404s.
    static func modelResourcePath(_ model: String) -> String {
        let prefix = "models/"
        let bare = model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : model
        // The id is a single path segment; `ProviderHTTP.encodePathComponent`
        // escapes the characters that would otherwise split it.
        return prefix + ProviderHTTP.encodePathComponent(bare)
    }

    static func requestBody(for request: ChatRequest) throws -> Data {
        var payload: [String: JSONValue] = [:]
        payload["contents"] = .array(contents(from: request.messages))

        // Bud carries developer instructions as the first message; Gemini wants
        // them alongside the contents, and only text is supported there.
        if let system = systemInstruction(from: request.messages) {
            payload["systemInstruction"] = .object(["parts": .array([.object(["text": .string(system)])])])
        }

        if !request.tools.isEmpty {
            payload["tools"] = .array([
                .object(["functionDeclarations": .array(request.tools.map(functionDeclaration))])
            ])
        }

        // `ChatRequest.stream` is not consulted: `streamGenerateContent` is the
        // streaming endpoint and has no non-streaming form.
        var config: [String: JSONValue] = [:]
        if let temperature = request.temperature { config["temperature"] = .number(temperature) }
        if let maxTokens = request.maxTokens { config["maxOutputTokens"] = .number(Double(maxTokens)) }
        if let thinking = thinkingConfig(for: request.reasoningEffort) {
            config["thinkingConfig"] = thinking
        }
        if !config.isEmpty { payload["generationConfig"] = .object(config) }

        return try JSONEncoder().encode(JSONValue.object(payload))
    }

    /// Developer instructions, joined when the history carries more than one.
    static func systemInstruction(from messages: [ChatMessage]) -> String? {
        let parts = messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Maps Bud's history onto `contents`.
    ///
    /// Two normalisations are applied because the dialect does not accept the
    /// shape Bud's history has:
    ///
    /// - `tool` messages become `user` turns carrying `functionResponse` parts;
    ///   Gemini has no `tool` role.
    /// - Adjacent same-role entries are merged into one `Content`, so the several
    ///   tool results answering one model turn travel as the single user turn
    ///   Google's examples show, and the conversation keeps alternating between
    ///   `user` and `model` as the API requires.
    static func contents(from messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in messages where message.role != .system {
            let role = message.role == .assistant ? "model" : "user"
            let parts = wireParts(for: message)
            guard !parts.isEmpty else { continue }

            if var last = out.last, last["role"]?.stringValue == role,
               let merged = last["parts"]?.arrayValue.map({ $0 + parts }) {
                last = .object(["role": .string(role), "parts": .array(merged)])
                out[out.count - 1] = last
            } else {
                out.append(.object(["role": .string(role), "parts": .array(parts)]))
            }
        }
        return out
    }

    static func wireParts(for message: ChatMessage) -> [JSONValue] {
        switch message.role {
        case .system:
            return [] // Lifted into `systemInstruction`.

        case .user:
            return message.content.isEmpty ? [] : [.object(["text": .string(message.content)])]

        case .assistant:
            var parts: [JSONValue] = []
            if !message.content.isEmpty { parts.append(.object(["text": .string(message.content)])) }
            // `reasoning` is deliberately dropped, as it is for OpenAI: Gemini
            // returns thought parts for display and does not accept them back.
            for call in message.toolCalls {
                parts.append(.object([
                    "functionCall": .object([
                        "name": .string(call.name),
                        "args": .objectOrEmpty(parsing: call.arguments),
                    ])
                ]))
            }
            return parts

        case .tool:
            // `name` is required by `FunctionResponse` and is the only thing that
            // links a result to its call — Gemini mints no id for a call it made.
            guard let name = message.name, !name.isEmpty else { return [] }
            return [.object([
                "functionResponse": .object([
                    "name": .string(name),
                    "response": .object([
                        "output": .string(message.content),
                    ]),
                ])
            ])]
        }
    }

    /// Bud's reasoning levels are OpenAI's; Gemini's `ThinkingLevel` is a
    /// documented enum with no `max` — `HIGH` is the deepest it exposes — and
    /// `thinkingLevel` only applies to the thinking models.
    ///
    /// `includeThoughts` is what makes thought parts come back at all, so it is
    /// set whenever the user has asked for reasoning rather than unconditionally:
    /// a request that never opted in should not depend on `thinkingConfig` being
    /// accepted by whatever model is configured.
    static func thinkingConfig(for effort: String?) -> JSONValue? {
        guard let effort, !effort.isEmpty else { return nil }
        var config: [String: JSONValue] = ["includeThoughts": .bool(true)]
        switch effort.lowercased() {
        case "low": config["thinkingLevel"] = .string("LOW")
        case "medium": config["thinkingLevel"] = .string("MEDIUM")
        case "high", "max": config["thinkingLevel"] = .string("HIGH")
        default: break // Unknown level: ask for thoughts, set no depth.
        }
        return .object(config)
    }

    static func functionDeclaration(for tool: ToolDescriptor) -> JSONValue {
        let parameters = sanitizedSchema(tool.schema)
        return .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": parameters.objectValue != nil
                ? parameters
                : .object(["type": "object", "properties": .object([:])]),
        ])
    }

    /// The keywords `Schema` defines, taken from the field list in the REST
    /// reference. Notably absent — and therefore rejected by the API — are
    /// `additionalProperties` and `$schema`, both of which MCP tool schemas
    /// routinely carry, along with `$defs`, `$ref`, `oneOf` and `const`.
    private static let supportedSchemaKeys: Set<String> = [
        "type", "format", "title", "description", "nullable", "enum",
        "maxItems", "minItems", "properties", "required",
        "minProperties", "maxProperties", "minLength", "maxLength", "pattern",
        "example", "anyOf", "propertyOrdering", "default", "items",
        "minimum", "maximum",
    ]

    /// Rebuilds a JSON Schema as a `Schema`, keeping only supported keywords.
    ///
    /// Dropping keywords is lossy, so it happens only where the alternative is a
    /// rejected request: every schema key Google does not define is removed, and
    /// the remaining shape — types, properties, required lists, array items — is
    /// what the model actually uses to call the tool.
    static func sanitizedSchema(_ schema: JSONValue) -> JSONValue {
        guard let object = schema.objectValue else { return schema }
        var out: [String: JSONValue] = [:]
        for (key, value) in object {
            switch key {
            case "properties":
                guard let properties = value.objectValue else { break }
                out[key] = .object(properties.mapValues(sanitizedSchema))
            case "items":
                out[key] = sanitizedSchema(value)
            case "anyOf":
                guard let members = value.arrayValue else { break }
                out[key] = .array(members.map(sanitizedSchema))
            default:
                if supportedSchemaKeys.contains(key) { out[key] = value }
            }
        }
        return .object(out)
    }

    // MARK: - SSE decoding

    /// Decodes Gemini's `alt=sse` stream one line at a time.
    ///
    /// Stateful, unlike the OpenAI decoder, because Gemini spreads over several
    /// frames what OpenAI puts in one:
    ///
    /// - `usageMetadata` is cumulative and can appear on every candidate frame,
    ///   while `recordUsage` *adds* what it is given — so usage is held back and
    ///   emitted once, on the finish frame.
    /// - `STOP` means "tool call" or "answer finished" depending on whether any
    ///   `functionCall` part appeared anywhere in the stream, which the last
    ///   frame alone cannot tell.
    struct GoogleStreamDecoder: Sendable {
        /// True once content, reasoning or a tool call has been emitted. An
        /// otherwise empty stream is an error, not an empty answer.
        private(set) var producedOutput = false
        private(set) var pendingUsage: StreamEvent?
        /// Frames carrying a `data:` payload, so "we parsed your stream and there
        /// was nothing in it" can be told apart from "nothing arrived".
        private(set) var frameCount = 0

        private var sawFunctionCall = false
        private var functionCallIndex = 0
        private var finishReason: String?
        private var emittedFinish = false

        mutating func events(fromLine line: String) throws -> [StreamEvent] {
            guard line.hasPrefix("data:") else { return [] } // Blank keep-alives and `event:` lines.
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "[DONE]" else { return [] }
            guard let json = JSONValue(parsing: trimmed) else { return [] }
            frameCount += 1

            // Failures such as an overloaded model arrive as an error object on an
            // otherwise successful stream; without this the stream would just end.
            if let error = json["error"] {
                let message = error["message"]?.stringValue ?? trimmed
                let bounded = message.count > 400 ? String(message.prefix(400)) + "…" : message
                if let code = error["code"]?.doubleValue, code >= 100, code < 600 {
                    throw ChatBackendError.http(status: Int(code), body: bounded)
                }
                throw ChatBackendError.decoding(bounded)
            }

            // A prompt the safety filters refused: no candidates follow, and the
            // reason is here and nowhere else.
            if let reason = json["promptFeedback"]?["blockReason"]?.stringValue,
               !reason.isEmpty, reason != "BLOCK_REASON_UNSPECIFIED" {
                throw ChatBackendError.decoding(
                    "Gemini blocked the prompt (blockReason: \(reason)). No content was generated."
                )
            }

            // Usage is collected from every frame and only surfaced on the finish
            // frame, because the counts are cumulative.
            if let usage = json["usageMetadata"] { pendingUsage = Self.usageEvent(usage) }

            guard let candidate = json["candidates"]?[0] else { return [] }
            var events: [StreamEvent] = []

            for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
                if part["thought"]?.boolValue == true {
                    // A thought part is displayed, never acted on — a function
                    // call the model only thought about is not a function call.
                    if let text = part["text"]?.stringValue, !text.isEmpty {
                        producedOutput = true
                        events.append(.reasoningDelta(text))
                    }
                    continue
                }
                if let text = part["text"]?.stringValue, !text.isEmpty {
                    producedOutput = true
                    events.append(.contentDelta(text))
                    continue
                }
                if let call = part["functionCall"], let name = call["name"]?.stringValue, !name.isEmpty {
                    // Whole, not fragmented: `args` is a complete object by the
                    // time the part is serialised, so it is emitted as the single
                    // fragment of its own call.
                    sawFunctionCall = true
                    producedOutput = true
                    let args = call["args"] ?? .object([:])
                    events.append(.toolCallDelta(
                        index: functionCallIndex,
                        id: nil, // The agent loop mints one; Gemini has none to give.
                        name: name,
                        argumentsFragment: args.encodedString()
                    ))
                    functionCallIndex += 1
                }
            }

            if !emittedFinish, let raw = candidate["finishReason"]?.stringValue, !raw.isEmpty,
               let reason = Self.normalizedFinishReason(raw, sawFunctionCall: sawFunctionCall) {
                finishReason = raw
                emittedFinish = true
                if let usage = pendingUsage {
                    events.append(usage)
                    pendingUsage = nil
                }
                events.append(.finish(reason: reason))
            }
            return events
        }

        /// Why an apparently successful stream carried nothing.
        func emptyResponseExplanation() -> String {
            guard frameCount > 0 else {
                return "Gemini returned an empty stream: no SSE data frames arrived."
            }
            var text = "Gemini returned no content in \(frameCount) stream frame(s)"
            if let finishReason { text += " (finishReason: \(finishReason))" }
            return text + "."
        }

        /// Gemini's `FinishReason` has no tool-call value: a turn that called a
        /// tool ends with `STOP` exactly as an answer does, so the presence of a
        /// `functionCall` part — not the reason alone — decides. The agent loop
        /// keys off `"tool_calls"`, hence the normalisation.
        static func normalizedFinishReason(_ raw: String, sawFunctionCall: Bool) -> String? {
            switch raw.uppercased() {
            case "STOP":
                return sawFunctionCall ? "tool_calls" : "stop"
            case "MAX_TOKENS":
                return "length"
            case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE",
                 "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_RECITATION":
                return "content_filter"
            case "FINISH_REASON_UNSPECIFIED", "":
                return nil
            default:
                // MALFORMED_FUNCTION_CALL, UNEXPECTED_TOOL_CALL,
                // MISSING_THOUGHT_SIGNATURE, MALFORMED_RESPONSE, ESCALATION,
                // TOO_MANY_TOOL_CALLS and OTHER: no OpenAI equivalent, and
                // inventing one would hide the cause. The round still ends.
                return raw.lowercased()
            }
        }

        static func usageEvent(_ usage: JSONValue) -> StreamEvent {
            // `thoughtsTokenCount` is reported separately and is not part of
            // `candidatesTokenCount`, so thought tokens are not billed to the
            // completion count here.
            .usage(
                promptTokens: Int(usage["promptTokenCount"]?.doubleValue ?? 0),
                completionTokens: Int(usage["candidatesTokenCount"]?.doubleValue ?? 0),
                cachedTokens: Int(usage["cachedContentTokenCount"]?.doubleValue ?? 0)
            )
        }
    }
}
