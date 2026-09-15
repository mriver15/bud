import Foundation

/// DeepSeek chat-completions client.
///
/// Speaks the OpenAI-compatible streaming protocol that DeepSeek exposes, with
/// two vendor specifics: `reasoning_content` on the delta (chain-of-thought,
/// which must be displayed but never sent back), and tool calls that stream as
/// argument fragments keyed by index.
public struct DeepSeekClient: ChatBackend {
    private let config: BudConfig

    public init(config: BudConfig) {
        self.config = config
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // The timeout is an inactivity timer, so a long generation that keeps
        // emitting deltas stays alive; this only catches a genuinely dead socket.
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 1800
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

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
        guard !config.apiKey.isEmpty else { throw ChatBackendError.missingAPIKey }

        let url = try endpoint()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try body(for: request)

        let (bytes, response) = try await Self.session.bytes(for: req)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The error body arrives as a normal body on a non-2xx; drain a
            // bounded amount so a huge HTML error page cannot be slurped.
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 8192 { break }
            }
            throw ChatBackendError.http(
                status: http.statusCode,
                body: String(data: collected, encoding: .utf8) ?? ""
            )
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in Self.decodeEvents(line: line) {
                continuation.yield(event)
            }
        }
    }

    private func endpoint() throws -> URL {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw ChatBackendError.transport("Invalid base URL: \(config.baseURL)")
        }
        return url
    }

    private func body(for request: ChatRequest) throws -> Data {
        var payload: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(request.messages.map(\.wireRepresentation)),
            "stream": .bool(request.stream),
        ]
        if !request.tools.isEmpty {
            payload["tools"] = .array(request.tools)
            payload["tool_choice"] = .string("auto")
        }
        if let t = request.temperature { payload["temperature"] = .number(t) }
        if let m = request.maxTokens { payload["max_tokens"] = .number(Double(m)) }
        if let e = request.reasoningEffort, !e.isEmpty {
            payload["reasoning_effort"] = .string(e)
        }
        return try JSONEncoder().encode(JSONValue.object(payload))
    }

    // MARK: - SSE decoding

    /// Decodes one SSE line into every event it carries.
    ///
    /// This returns an array because DeepSeek's terminal frame carries
    /// `finish_reason` *and* the `usage` block in a single chunk. Returning one
    /// event per line silently dropped the finish reason, which is what the agent
    /// loop keys off to decide a round is over.
    ///
    /// Returns `[]` for anything that is not a data frame: blank keep-alive
    /// lines, `:` comments, and the `[DONE]` sentinel.
    static func decodeEvents(line: String) -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return [] }
        guard let json = JSONValue(parsing: trimmed) else { return [] }

        var events: [StreamEvent] = []

        // Usage may arrive on its own frame with no choices at all, so it is read
        // before the choice is required.
        if let usage = json["usage"] {
            events.append(.usage(
                promptTokens: Int(usage["prompt_tokens"]?.doubleValue ?? 0),
                completionTokens: Int(usage["completion_tokens"]?.doubleValue ?? 0),
                cachedTokens: Int(usage["prompt_cache_hit_tokens"]?.doubleValue ?? 0)
            ))
        }

        guard let choice = json["choices"]?[0] else { return events }

        if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
            events.append(.finish(reason: reason))
            return events
        }

        guard let delta = choice["delta"] else { return events }

        // A single frame may pipeline several calls; each index is its own call.
        if let calls = delta["tool_calls"]?.arrayValue, !calls.isEmpty {
            for call in calls {
                events.append(.toolCallDelta(
                    index: Int(call["index"]?.doubleValue ?? 0),
                    id: call["id"]?.stringValue,
                    name: call["function"]?["name"]?.stringValue,
                    argumentsFragment: call["function"]?["arguments"]?.stringValue ?? ""
                ))
            }
            return events
        }

        if let r = delta["reasoning_content"]?.stringValue, !r.isEmpty {
            events.append(.reasoningDelta(r))
        } else if let c = delta["content"]?.stringValue, !c.isEmpty {
            events.append(.contentDelta(c))
        }
        return events
    }

    /// Convenience for callers that only care about the first event.
    static func decode(line: String) -> StreamEvent? {
        decodeEvents(line: line).first
    }
}
