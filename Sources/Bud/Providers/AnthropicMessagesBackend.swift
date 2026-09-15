import Foundation

/// Client for the Anthropic Messages dialect.
///
/// This one is a translation layer rather than a header change, because three of
/// the dialect's shapes reach all the way up into how a conversation is written:
/// the system prompt is a top-level field rather than a message, an assistant
/// tool call is a `tool_use` content block inside the assistant message, and a
/// tool *result* goes back as a user message holding a `tool_result` block.
/// Streaming is a sequence of typed events rather than a run of chunks, and the
/// two token counts arrive on two different events.
///
/// The wire facts that differ from the OpenAI path, and that cannot be guessed
/// from it:
/// - Authentication is `x-api-key`, and the format is versioned by an
///   `anthropic-version` header rather than by the endpoint path.
/// - `max_tokens` is required, so one is always sent.
/// - `content_block_start` carries a tool block's `id` and `name`; the arguments
///   then stream as `input_json_delta` fragments keyed by the *content block*
///   index, which is shared with the text and thinking blocks around it.
public struct AnthropicMessagesBackend: ChatBackend {
    private let provider: ProviderDescriptor
    private let credentials: ProviderCredentials

    public init(provider: ProviderDescriptor, credentials: ProviderCredentials) {
        self.provider = provider
        self.credentials = credentials
    }

    /// Anthropic dates its wire format and requires the header on every request,
    /// so the version this client is written against is pinned here.
    private static let apiVersion = "2023-06-01"

    /// `max_tokens` is required here, and Bud leaves it unset unless a caller
    /// passes one. 4096 is deliberately modest: it is the lowest output ceiling
    /// any Claude model ships with, so it is accepted everywhere, and a rejected
    /// over-large value would be unrecoverable for a user who has no setting to
    /// lower it with.
    private static let defaultMaxTokens = 4096

    /// Anthropic's documented effort vocabulary. Bud's picker offers
    /// `low`/`medium`/`high`/`max` and can also carry a value that came from
    /// somewhere else, so anything outside this set is dropped rather than sent
    /// as a request the API would reject.
    private static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// Token counts for one response.
    ///
    /// Held across events because the dialect splits them: `input_tokens` on
    /// `message_start`, `output_tokens` on `message_delta`. They are re-emitted
    /// as a single `.usage` — the consumer sums what it is handed, so yielding
    /// both events' figures would count the prompt twice.
    private struct UsageState {
        var promptTokens = 0
        var completionTokens = 0
        var cachedTokens = 0
        var sawUsage = false
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

        var req = URLRequest(url: try endpoint())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Not `Authorization: Bearer`: this API reads the key from a header of
        // its own, and takes the format version from another.
        if !credentials.apiKey.isEmpty {
            req.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        for (name, value) in credentials.extraHeaders {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.httpBody = try body(for: request)

        let (bytes, response) = try await ProviderHTTP.session.bytes(for: req)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // A bounded drain, so a huge HTML error page cannot be slurped into
            // memory or into the transcript.
            throw ChatBackendError.http(
                status: http.statusCode,
                body: await ProviderHTTP.errorBody(bytes)
            )
        }

        var usage = UsageState()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try decodeEvents(line: line, usage: &usage) {
                continuation.yield(event)
            }
        }

        // Yielded once, at the end, so the two halves are reported together.
        if usage.sawUsage {
            continuation.yield(.usage(
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                cachedTokens: usage.cachedTokens
            ))
        }
    }

    private func endpoint() throws -> URL {
        var base = credentials.resolvedBaseURL(for: provider)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else {
            throw ChatBackendError.transport("No base URL set for \(provider.name).")
        }
        // The registry stores base URLs without their version segment, but a
        // custom endpoint is typed by hand and may already carry it.
        let path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        guard let url = URL(string: base + path) else {
            throw ChatBackendError.transport("Invalid base URL: \(base)")
        }
        return url
    }

    private func body(for request: ChatRequest) throws -> Data {
        let (system, messages) = Self.wireMessages(request.messages)
        var payload: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "stream": .bool(request.stream),
            "max_tokens": .number(Double(request.maxTokens ?? Self.defaultMaxTokens)),
        ]
        // There is no `role: "system"` message in this dialect; the prompt is a
        // top-level field, so Bud's system message is lifted out above.
        if let system, !system.isEmpty { payload["system"] = .string(system) }
        if !request.tools.isEmpty {
            // No `{"type": "function", "function": {...}}` wrapper, and no
            // `tool_choice: "auto"` string either: letting the model decide is
            // the default, so the field is simply absent.
            payload["tools"] = .array(request.tools.map(Self.toolDefinition))
        }
        if let t = request.temperature { payload["temperature"] = .number(t) }
        // Anthropic replaced the thinking token budget with an effort level, and
        // the vocabulary is the same one the OpenAI path forwards. An unset or
        // unknown effort simply means the model's own default applies.
        if let effort = request.reasoningEffort, Self.effortLevels.contains(effort) {
            payload["output_config"] = .object(["effort": .string(effort)])
        }
        return try JSONEncoder().encode(JSONValue.object(payload))
    }

    // MARK: - Message translation

    /// Splits history into the top-level system prompt and the message array,
    /// translating the roles and the tool traffic on the way.
    ///
    /// Bud's history is one flat sequence, but the dialect has three shapes in
    /// it, so this walks it once and groups as it goes: consecutive tool results
    /// collapse into a single user message, because that is how a batch of
    /// results is linked back to the assistant turn that asked for them.
    static func wireMessages(_ history: [ChatMessage]) -> (system: String?, messages: [JSONValue]) {
        var system: [String] = []
        var messages: [JSONValue] = []
        var toolResults: [JSONValue] = []

        func flushToolResults() {
            guard !toolResults.isEmpty else { return }
            messages.append(.object(["role": "user", "content": .array(toolResults)]))
            toolResults = []
        }

        for message in history {
            switch message.role {
            case .system:
                if !message.content.isEmpty { system.append(message.content) }

            case .tool:
                // A result is not a message of its own: it is a `tool_result`
                // block inside a user message. Without an id it cannot be tied
                // to the call that produced it, so it is dropped rather than
                // sent as a block that would fail the whole request.
                guard let id = message.toolCallID, !id.isEmpty else { continue }
                toolResults.append(.object([
                    "type": "tool_result",
                    "tool_use_id": .string(id),
                    "content": .string(message.content),
                ]))

            case .user:
                flushToolResults()
                messages.append(.object(["role": "user", "content": Self.textContent(message.content)]))

            case .assistant:
                flushToolResults()
                messages.append(.object(["role": "assistant", "content": Self.assistantContent(message)]))
            }
        }
        flushToolResults()

        return (system.isEmpty ? nil : system.joined(separator: "\n\n"), messages)
    }

    /// A bare string is the dialect's shorthand for one text block. The array
    /// form only appears when there is no text, where an empty string would
    /// violate the block's minimum length.
    private static func textContent(_ text: String) -> JSONValue {
        text.isEmpty ? .array([]) : .string(text)
    }

    /// An assistant turn is a list of content blocks: whatever prose it wrote,
    /// then one `tool_use` block per call. Note that `input` is an object, where
    /// the OpenAI dialect passes the same arguments as a JSON *string*.
    ///
    /// `reasoning` is dropped, as it is on the OpenAI path: a thinking block has
    /// to be echoed back with the signature that arrived with it, and
    /// `ChatMessage` carries no signature.
    private static func assistantContent(_ message: ChatMessage) -> JSONValue {
        let text = message.content
        guard !message.toolCalls.isEmpty else { return Self.textContent(text) }

        var blocks: [JSONValue] = []
        if !text.isEmpty {
            blocks.append(.object(["type": "text", "text": .string(text)]))
        }
        for call in message.toolCalls {
            blocks.append(.object([
                "type": "tool_use",
                "id": .string(call.id),
                "name": .string(call.name),
                "input": call.parsedArguments,
            ]))
        }
        return .array(blocks)
    }

    /// The dialect's own tool shape. The schema field is `input_schema` rather
    /// than `parameters`, and there is no `function` wrapper around it.
    private static func toolDefinition(_ tool: ToolDescriptor) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.schema.objectValue != nil
                ? tool.schema
                : .object(["type": "object", "properties": .object([:])]),
        ])
    }

    /// Maps `stop_reason` onto the vocabulary the agent loop already switches on,
    /// so its `finishReason == "tool_calls"` test keeps working.
    ///
    /// The dialect's own values are `end_turn`, `max_tokens`, `stop_sequence`,
    /// `tool_use`, `pause_turn`, `refusal` and `model_context_window_exceeded`.
    /// Anything else is passed through untouched, because the versioning policy
    /// reserves the right to add more of them and a rewrite here would hide it.
    private static func stopReason(_ raw: String) -> String {
        switch raw {
        case "tool_use": return "tool_calls"
        case "max_tokens", "model_context_window_exceeded": return "length"
        case "end_turn", "stop_sequence", "pause_turn", "refusal": return "stop"
        default: return raw
        }
    }

    // MARK: - SSE decoding

    /// Decodes one SSE line into every event it carries, accumulating the token
    /// counts that arrive on different events.
    ///
    /// Each frame repeats its type inside the JSON payload, so the `event:` line
    /// carries nothing the payload does not; only `data:` lines are read. Blank
    /// keep-alive lines, `:` comments and `ping` frames decode to `[]`.
    ///
    /// Throws when the stream reports an error of its own. The API can fail
    /// after the 200 has gone out — an `overloaded_error` under load — and a
    /// stream that reports a failure and then says nothing else must not be left
    /// hanging.
    private func decodeEvents(line: String, usage: inout UsageState) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let json = JSONValue(parsing: trimmed) else { return [] }

        switch json["type"]?.stringValue {
        case "message_start":
            // The response opens with the prompt counts; the completion count
            // only arrives with `message_delta`.
            Self.record(json["message"]?["usage"], into: &usage)
            return []

        case "content_block_start":
            // Text and thinking blocks announce themselves and are then carried
            // by deltas. A tool block's id and name appear only here, so this is
            // where the call is opened — at its content block index, which is
            // shared with every block in the response and so is not the tool's
            // own position in the batch. Server-side tools are not Bud's to run,
            // so only client `tool_use` blocks are opened.
            guard let block = json["content_block"],
                  block["type"]?.stringValue == "tool_use"
            else { return [] }
            return [.toolCallDelta(
                index: Int(json["index"]?.doubleValue ?? 0),
                id: block["id"]?.stringValue,
                name: block["name"]?.stringValue,
                argumentsFragment: ""
            )]

        case "content_block_delta":
            guard let delta = json["delta"] else { return [] }
            let index = Int(json["index"]?.doubleValue ?? 0)
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
                return [.contentDelta(text)]

            case "thinking_delta":
                guard let text = delta["thinking"]?.stringValue, !text.isEmpty else { return [] }
                return [.reasoningDelta(text)]

            case "input_json_delta":
                // Fragments are partial JSON, handed on exactly as they arrive;
                // the consumer concatenates them and parses once, the same way
                // it handles the OpenAI path's argument fragments.
                return [.toolCallDelta(
                    index: index,
                    id: nil,
                    name: nil,
                    argumentsFragment: delta["partial_json"]?.stringValue ?? ""
                )]

            default:
                // `signature_delta` accompanies a thinking block and is not
                // displayable; unknown delta types are ignored by policy.
                return []
            }

        case "message_delta":
            // Cumulative, so the latest value wins rather than being summed.
            Self.record(json["usage"], into: &usage)
            guard let reason = json["delta"]?["stop_reason"]?.stringValue else { return [] }
            return [.finish(reason: Self.stopReason(reason))]

        case "error":
            let type = json["error"]?["type"]?.stringValue ?? "unknown_error"
            let detail = json["error"]?["message"]?.stringValue ?? "no message"
            throw ChatBackendError.transport("\(provider.name) ended the stream with \(type): \(detail)")

        default:
            // `content_block_stop`, `message_stop` and `ping` carry no content;
            // anything unknown is ignored by policy.
            return []
        }
    }

    /// Records one event's usage block.
    ///
    /// The blocks are cumulative rather than incremental, so each field is
    /// overwritten with the latest value and a field an event omits keeps what
    /// an earlier event supplied. Cached prompt tokens are billed outside
    /// `input_tokens` here, where the OpenAI dialect's `prompt_tokens` already
    /// includes them, so they are added back to keep the two `.usage` events
    /// meaning the same thing to the caller.
    private static func record(_ usage: JSONValue?, into state: inout UsageState) {
        guard let usage, usage.objectValue != nil else { return }

        if let input = usage["input_tokens"]?.doubleValue {
            let cached = usage["cache_read_input_tokens"]?.doubleValue ?? 0
            let created = usage["cache_creation_input_tokens"]?.doubleValue ?? 0
            state.promptTokens = Int(input + cached + created)
            state.cachedTokens = Int(cached)
            state.sawUsage = true
        }
        if let output = usage["output_tokens"]?.doubleValue {
            state.completionTokens = Int(output)
            state.sawUsage = true
        }
    }
}
