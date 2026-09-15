import Foundation

// MARK: - Streaming chat backend

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [JSONValue]
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoningEffort: String?
    public var stream: Bool

    public init(
        model: String,
        messages: [ChatMessage],
        tools: [JSONValue] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: String? = nil,
        stream: Bool = true
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.stream = stream
    }
}

public enum StreamEvent: Sendable {
    case reasoningDelta(String)
    case contentDelta(String)
    /// `name` and `id` arrive only on the first fragment of a given index.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case finish(reason: String?)
    case usage(promptTokens: Int, completionTokens: Int, cachedTokens: Int)
}

public enum ChatBackendError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No DeepSeek API key. Set DEEPSEEK_API_KEY or add it in Settings."
        case .http(let status, let body):
            let trimmed = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "DeepSeek returned HTTP \(status): \(trimmed)"
        case .transport(let m):
            return "Network error: \(m)"
        case .decoding(let m):
            return "Malformed response: \(m)"
        }
    }
}

/// Contract every model backend satisfies. The subagent supervisor takes this
/// same protocol so subagents reuse the parent's transport, key and model
/// without duplicating any HTTP code.
public protocol ChatBackend: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
