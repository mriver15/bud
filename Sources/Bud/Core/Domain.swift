import Foundation

// MARK: - Roles

public enum Role: String, Sendable, Codable, Hashable {
    case system, user, assistant, tool
}

// MARK: - Wire-level tool call

/// A tool invocation exactly as it appears on the DeepSeek wire format.
/// `arguments` stays a raw JSON string because that is what the model emits and
/// what must be echoed back verbatim in the next request.
public struct ToolCall: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var parsedArguments: JSONValue { .objectOrEmpty(parsing: arguments) }
}

// MARK: - Conversation message

/// One entry in the model-facing conversation. Distinct from `Segment`, which is
/// the user-facing transcript: a single assistant turn can expand into many
/// messages (assistant tool_calls, then one `tool` message per result).
public struct ChatMessage: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var role: Role
    public var content: String
    public var reasoning: String?
    public var toolCalls: [ToolCall]
    /// Set only when `role == .tool`; links the result to its `ToolCall.id`.
    public var toolCallID: String?
    public var name: String?

    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: String = "",
        reasoning: String? = nil,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    /// Serialises to the shape DeepSeek expects. `reasoning` is deliberately
    /// dropped: the API returns it for display but rejects it on input.
    public var wireRepresentation: JSONValue {
        var o: [String: JSONValue] = ["role": .string(role.rawValue)]
        if role == .assistant, !toolCalls.isEmpty {
            o["content"] = content.isEmpty ? .null : .string(content)
            o["tool_calls"] = .array(toolCalls.map { call in
                [
                    "id": .string(call.id),
                    "type": "function",
                    "function": ["name": .string(call.name), "arguments": .string(call.arguments)],
                ]
            })
        } else {
            o["content"] = .string(content)
        }
        if let toolCallID { o["tool_call_id"] = .string(toolCallID) }
        if let name { o["name"] = .string(name) }
        return .object(o)
    }
}

// MARK: - Tool metadata

public struct ToolDescriptor: Sendable, Hashable, Identifiable {
    /// Unique across every connected provider; this is the name sent to the model.
    public var id: String
    public var name: String
    public var description: String
    public var schema: JSONValue
    public var providerID: String
    public var providerName: String

    public init(
        name: String,
        description: String,
        schema: JSONValue,
        providerID: String,
        providerName: String
    ) {
        self.id = name
        self.name = name
        self.description = description
        self.schema = schema
        self.providerID = providerID
        self.providerName = providerName
    }

    /// DeepSeek function definition. Names are pre-sanitised by each provider.
    public var wireRepresentation: JSONValue {
        .object([
            "type": "function",
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": schema.objectValue != nil
                    ? schema
                    : .object(["type": "object", "properties": .object([:])]),
            ]),
        ])
    }
}

// MARK: - Tool result

public struct ToolResult: Sendable {
    public var text: String
    /// When present, the transcript renders a generative-UI surface for this
    /// call instead of (or above) the raw text.
    public var ui: JSONValue?
    public var isError: Bool

    public init(text: String, ui: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.ui = ui
        self.isError = isError
    }

    public static func ok(_ text: String) -> ToolResult { ToolResult(text: text) }
    public static func error(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
    public static func ui(_ spec: JSONValue, text: String = "Rendered a UI surface.") -> ToolResult {
        ToolResult(text: text, ui: spec)
    }

    /// What the model sees. Truncated because tool output can be enormous and
    /// every byte is re-sent on each subsequent turn.
    public func modelFacingText(limit: Int = 24_000) -> String {
        if text.count <= limit { return text }
        let cutoff = text.index(text.startIndex, offsetBy: limit)
        let dropped = text.count - limit
        return String(text[..<cutoff]) + "\n\n…[truncated \(dropped) characters]"
    }
}

// MARK: - Transcript segments (user-facing)

public enum ToolRunState: String, Sendable, Codable {
    case queued, running, succeeded, failed
}

public enum NoticeKind: String, Sendable, Codable {
    case info, warning, error
}

/// The user-visible rendering of a turn. Reasoning, text, tool activity and
/// generated UI interleave in arrival order, which is why this is an ordered
/// array rather than separate fields.
public enum Segment: Sendable, Identifiable {
    case reasoning(id: String, text: String)
    case text(id: String, text: String)
    case tool(
        id: String,
        call: ToolCall,
        providerName: String,
        state: ToolRunState,
        resultText: String?,
        ui: JSONValue?
    )
    case notice(id: String, text: String, kind: NoticeKind)

    public var id: String {
        switch self {
        case .reasoning(let id, _), .text(let id, _), .tool(let id, _, _, _, _, _), .notice(let id, _, _):
            return id
        }
    }
}

/// One user or assistant turn in the transcript.
public struct Turn: Sendable, Identifiable {
    public var id: String
    public var role: Role
    public var segments: [Segment]
    public var isStreaming: Bool
    public var error: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        role: Role,
        segments: [Segment] = [],
        isStreaming: Bool = false,
        error: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.segments = segments
        self.isStreaming = isStreaming
        self.error = error
        self.createdAt = createdAt
    }

    /// Appends to the trailing segment when it matches, so streamed deltas
    /// coalesce into one bubble instead of thousands of one-character ones.
    public mutating func appendReasoning(_ delta: String) {
        if case .reasoning(let id, let text) = segments.last {
            segments[segments.count - 1] = .reasoning(id: id, text: text + delta)
        } else {
            segments.append(.reasoning(id: UUID().uuidString, text: delta))
        }
    }

    public mutating func appendText(_ delta: String) {
        if case .text(let id, let text) = segments.last {
            segments[segments.count - 1] = .text(id: id, text: text + delta)
        } else {
            segments.append(.text(id: UUID().uuidString, text: delta))
        }
    }

    public var plainText: String {
        segments.compactMap { seg in
            if case .text(_, let t) = seg { return t }
            return nil
        }.joined()
    }
}
