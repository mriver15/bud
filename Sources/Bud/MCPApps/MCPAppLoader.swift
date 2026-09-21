import Foundation

// MARK: - Validation

/// Turns a fetched `ui://` resource into something safe to render, or refuses
/// it.
///
/// The gate is here and it is strict: the spec's MIME type, the `ui://` scheme,
/// a byte bound, and a Content-Security-Policy that only ever admits what the
/// server declared. Nothing is rendered until all of it holds, because a host
/// that rendered a resource on trust is a host whose transcript is a browser.
public enum MCPAppLoader {
    /// One megabyte of HTML is far more than any real app; the bound is what
    /// keeps a hostile or broken server from handing the host a transcript-sized
    /// document to parse on the main thread.
    public static let maxHTMLBytes = 1_000_000
    /// The initial content type, per the specification.
    public static let requiredMimeType = "text/html;profile=mcp-app"

    /// Validates a resource and produces the renderable form.
    public static func validate(_ content: MCPResourceContent) throws -> MCPAppResource {
        guard content.uri.hasPrefix("ui://") else {
            throw MCPAppError.invalidURI(content.uri)
        }
        guard content.mimeType.contains("text/html"), content.mimeType.contains("mcp-app") else {
            throw MCPAppError.unsupportedMime(content.mimeType)
        }
        guard !content.text.isEmpty else {
            throw MCPAppError.emptyResource
        }
        guard content.text.utf8.count <= maxHTMLBytes else {
            throw MCPAppError.oversized(content.text.utf8.count)
        }
        let csp = MCPAppCSP(json: content.meta) ?? MCPAppCSP()
        let border = content.meta["ui"]?["prefersBorder"]?.boolValue
            ?? content.meta["prefersBorder"]?.boolValue
        return MCPAppResource(
            uri: content.uri,
            mimeType: content.mimeType,
            html: content.text,
            csp: csp,
            prefersBorder: border
        )
    }

    /// The bounded result the attachment keeps: `content` held whole only while
    /// it is small, and the text truncated to a line boundary past that — the
    /// app reads `structuredContent` for its data, and the content blocks are
    /// the human-readable fallback.
    public static func boundedResult(_ result: MCPCallResult) -> JSONValue {
        var object: [String: JSONValue] = result.raw.objectValue ?? [:]
        object["isError"] = .bool(result.isError)
        if let structured = result.structuredContent {
            object["structuredContent"] = structured
        }
        let blocks = result.content.map(\.rendered)
        let joined = blocks.joined(separator: "\n")
        let cap = 24_000
        let bounded = joined.count > cap
            ? String(joined.prefix(cap)) + "\n…[truncated]"
            : joined
        object["content"] = .array([
            .object(["type": .string("text"), "text": .string(bounded)]),
        ])
        return .object(object)
    }
}
