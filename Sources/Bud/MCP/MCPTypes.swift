import Foundation

// MARK: - Errors

/// Every failure the MCP stack can surface.
///
/// The set is closed on purpose: `MCPManager.invoke` turns these into
/// `ToolResult` errors the model reads, and the Settings UI matches on them, so
/// adding a case is a contract change rather than a local convenience.
public enum MCPError: Error, LocalizedError, Hashable, Sendable {
    case transportClosed
    case processSpawnFailed(String)
    case http(Int, String)
    case protocolError(code: Int, message: String)
    case timeout
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .transportClosed:
            return "The MCP server closed the connection."
        case .processSpawnFailed(let reason):
            return "Could not start the MCP server: \(reason)"
        case .http(let status, let body):
            let trimmed = body.count > 400 ? String(body.prefix(400)) + "…" : body
            // Status 0 means no HTTP response was ever produced — refused
            // connection, unresolvable host, stream cut mid-flight. Rendering it
            // as "HTTP 0" would read like a bug in Bud rather than a transport
            // failure, so it gets its own phrasing.
            return status == 0
                ? "MCP transport error: \(trimmed)"
                : "MCP server returned HTTP \(status): \(trimmed)"
        case .protocolError(let code, let message):
            return "MCP protocol error \(code): \(message)"
        case .timeout:
            return "The MCP server did not answer in time."
        case .notConnected:
            return "Not connected to an MCP server."
        }
    }

    /// Normalises the mix of `MCPError`, `URLError`, `POSIXError` and
    /// `CancellationError` that transports can throw, so callers never have to
    /// pattern-match Foundation's error zoo to build a user-facing message.
    public static func wrap(_ error: any Error) -> MCPError {
        if let mcp = error as? MCPError { return mcp }
        if error is CancellationError { return .transportClosed }
        return .http(0, error.localizedDescription)
    }
}

// MARK: - Tools

/// The `_meta.ui` block a tool advertises, and what it points at.
///
/// Parsed from the tool's `_meta.ui` object, with the deprecated flat
/// `_meta["ui/resourceUri"]` form still honoured — the spec says it is on the
/// way out, and a host that dropped it would break every server written against
/// the earlier draft.
public struct MCPToolUI: Sendable, Hashable {
    /// The `ui://` resource rendered for this tool's result, when there is one.
    public var resourceUri: String?
    /// Who can reach the tool. Defaults to `["model", "app"]` when omitted.
    public var visibility: [String]

    public static let defaultVisibility = ["model", "app"]

    public var isModelVisible: Bool { visibility.contains("model") }
    public var isAppCallable: Bool { visibility.contains("app") }

    public init(resourceUri: String?, visibility: [String]) {
        self.resourceUri = resourceUri
        self.visibility = visibility.isEmpty ? Self.defaultVisibility : visibility
    }

    public init?(json: JSONValue) {
        let object = json["ui"]?.objectValue
        let flat = json["ui/resourceUri"]?.stringValue
        let resourceUri = object?["resourceUri"]?.stringValue
            ?? flat
            ?? object?["resourceUri"]?.stringValue
        let visibility = object?["visibility"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard resourceUri != nil || !visibility.isEmpty else { return nil }
        self.init(resourceUri: resourceUri, visibility: visibility)
    }
}

/// One tool as advertised by `tools/list`.
public struct MCPTool: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    /// The server's JSON Schema, passed to the model untouched: rewriting it
    /// would only drop server-specific validation hints.
    public var inputSchema: JSONValue
    /// The UI this tool points at, when the server declared one.
    public var ui: MCPToolUI?

    public var id: String { name }

    public init(name: String, description: String, inputSchema: JSONValue, ui: MCPToolUI? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.ui = ui
    }

    /// Lenient by design. Servers omit `description`, send `inputSchema` shapes
    /// that are not objects, and occasionally pad the array with junk; none of
    /// that should fail an otherwise usable tool list.
    public init?(json: JSONValue) {
        guard let object = json.objectValue,
              let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else { return nil }
        self.name = name
        self.description = object["description"]?.stringValue ?? ""
        self.inputSchema = object["inputSchema"]
            ?? .object(["type": "object", "properties": .object([:])])
        self.ui = object["_meta"].flatMap(MCPToolUI.init(json:))
    }
}

// MARK: - Call results

/// A `tools/call` result, whole.
///
/// `MCPClient.callTool` used to flatten this into `ToolResult.text` and drop
/// everything the model could not read. MCP Apps needs the *complete* result —
/// content blocks, `structuredContent`, `isError` — to hand to the view, so the
/// flattening happens one layer up, and the text-only path keeps exactly the
/// same shape it had.
public struct MCPCallResult: Sendable, Hashable {
    public var content: [MCPContent]
    public var structuredContent: JSONValue?
    public var isError: Bool
    /// The server's result object, verbatim — what the app reads.
    public var raw: JSONValue

    public init(
        content: [MCPContent],
        structuredContent: JSONValue?,
        isError: Bool,
        raw: JSONValue
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.raw = raw
    }

    /// What the model sees — the same text the flat path produced.
    public var renderedText: String {
        var text = content.map(\.rendered).joined(separator: "\n")
        if text.isEmpty {
            text = structuredContent?.encodedString() ?? ""
        }
        return text
    }
}

/// One `resources/read` answer for a `ui://` resource: the MIME type, the HTML
/// as text (blob content is base64-decoded first), and the `_meta` the server
/// sent alongside it.
public struct MCPResourceContent: Sendable, Hashable {
    public var uri: String
    public var mimeType: String
    public var text: String
    public var meta: JSONValue

    public init(uri: String, mimeType: String, text: String, meta: JSONValue) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.meta = meta
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        let contents = object["contents"]?.arrayValue ?? []
        guard let first = contents.first?.objectValue else { return nil }
        guard let uri = first["uri"]?.stringValue, !uri.isEmpty else { return nil }
        self.uri = uri
        self.mimeType = first["mimeType"]?.stringValue ?? ""
        if let text = first["text"]?.stringValue {
            self.text = text
        } else if let blob = first["blob"]?.stringValue,
                  let data = Data(base64Encoded: blob),
                  let decoded = String(data: data, encoding: .utf8) {
            self.text = decoded
        } else {
            self.text = ""
        }
        self.meta = object["_meta"] ?? first["_meta"] ?? .object([:])
    }
}

// MARK: - Result content

/// An `image` content block. The payload is base64 on the wire; Bud does not
/// re-render MCP images, but the size is what makes the placeholder informative.
public struct MCPImage: Sendable, Hashable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }

    public var byteCount: Int {
        let padding = base64.hasSuffix("==") ? 2 : (base64.hasSuffix("=") ? 1 : 0)
        return max(0, base64.count / 4 * 3 - padding)
    }
}

/// One entry of a `tools/call` result content array.
public enum MCPContent: Sendable, Hashable {
    case text(String)
    case image(MCPImage)
    case resource(JSONValue)
    case unknown(String)

    public init(json: JSONValue) {
        switch json["type"]?.stringValue ?? "" {
        case "text":
            self = .text(json["text"]?.stringValue ?? "")
        case "image":
            self = .image(MCPImage(
                mimeType: json["mimeType"]?.stringValue ?? "application/octet-stream",
                base64: json["data"]?.stringValue ?? ""
            ))
        case "resource":
            self = .resource(json["resource"] ?? json)
        default:
            // Some servers emit a bare `resource` block without a `type` tag.
            if let resource = json["resource"] { self = .resource(resource) }
            else { self = .unknown(json["type"]?.stringValue ?? "unknown") }
        }
    }

    /// What the model and the transcript see. Dropping a non-text block would
    /// silently truncate a result, so every case renders something.
    public var rendered: String {
        switch self {
        case .text(let text):
            return text
        case .image(let image):
            return "[image \(image.mimeType), \(image.byteCount) bytes]"
        case .resource(let resource):
            let uri = resource["uri"]?.stringValue ?? "unknown"
            if let text = resource["text"]?.stringValue, !text.isEmpty {
                return "[resource \(uri)]\n\(text)"
            }
            if let mime = resource["mimeType"]?.stringValue {
                return "[resource \(uri), \(mime)]"
            }
            return "[resource \(uri)]"
        case .unknown(let type):
            return "[unsupported MCP content: \(type)]"
        }
    }
}

// MARK: - Initialize

public struct MCPInitializeResult: Sendable, Hashable {
    public var protocolVersion: String
    public var capabilities: JSONValue
    public var serverName: String
    public var serverVersion: String

    public init(
        protocolVersion: String,
        capabilities: JSONValue,
        serverName: String,
        serverVersion: String
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    public init(json: JSONValue) {
        self.protocolVersion = json["protocolVersion"]?.stringValue ?? ""
        self.capabilities = json["capabilities"] ?? .object([:])
        let info = json["serverInfo"]
        self.serverName = info?["name"]?.stringValue ?? "unknown"
        self.serverVersion = info?["version"]?.stringValue ?? ""
    }

    /// Presence of a capability block is the only signal the spec offers, and it
    /// is deliberately not treated as a guarantee — see `MCPClient`'s tolerance
    /// for `-32601`.
    public func supports(_ capability: String) -> Bool {
        guard let block = capabilities[capability] else { return false }
        return !block.isNull
    }
}

// MARK: - Resources and prompts

public struct MCPResource: Sendable, Hashable, Identifiable {
    public var uri: String
    public var name: String
    public var description: String
    public var mimeType: String?

    public var id: String { uri }

    public init(uri: String, name: String, description: String, mimeType: String?) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue,
              let uri = object["uri"]?.stringValue, !uri.isEmpty
        else { return nil }
        self.uri = uri
        self.name = object["name"]?.stringValue ?? uri
        self.description = object["description"]?.stringValue ?? ""
        self.mimeType = object["mimeType"]?.stringValue
    }
}

public struct MCPPromptArgument: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var required: Bool

    public var id: String { name }

    public init(name: String, description: String, required: Bool) {
        self.name = name
        self.description = description
        self.required = required
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue,
              let name = object["name"]?.stringValue, !name.isEmpty
        else { return nil }
        self.name = name
        self.description = object["description"]?.stringValue ?? ""
        self.required = object["required"]?.boolValue ?? false
    }
}

public struct MCPPrompt: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var arguments: [MCPPromptArgument]

    public var id: String { name }

    public init(name: String, description: String, arguments: [MCPPromptArgument]) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue,
              let name = object["name"]?.stringValue, !name.isEmpty
        else { return nil }
        self.name = name
        self.description = object["description"]?.stringValue ?? ""
        self.arguments = (object["arguments"]?.arrayValue ?? []).compactMap(MCPPromptArgument.init(json:))
    }
}
