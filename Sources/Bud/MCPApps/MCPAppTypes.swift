import CryptoKit
import Foundation

// MARK: - The persisted reference

/// A rendered app, attached to the tool call that produced it and persisted with
/// that call.
///
/// What is kept is bounded: the resource URI, the connection it was made on, the
/// tool's arguments and a bounded copy of the result the app reads. The HTML
/// itself is not persisted — it is re-fetched and re-validated from the server
/// (or its cache) when the view mounts, so a stored conversation never pins a
/// template the server has since changed, and the transcript file stays small.
public struct MCPAppAttachment: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    /// The MCP server the app belongs to — the only route it may call home on.
    public var serverID: String
    /// The connection the instance was created on. A view whose generation no
    /// longer matches the live connection is refused rather than trusted.
    public var generation: Int
    /// The `ui://` URI rendered for this call.
    public var resourceURI: String
    /// The tool whose result the app displays.
    public var toolName: String
    /// The tool input, delivered to the app as `ui/notifications/tool-input`.
    public var arguments: JSONValue
    /// The tool result, bounded — what `ui/notifications/tool-result` delivers.
    public var result: JSONValue
    public var isError: Bool
    /// The resource's content hash, so the cache can tell a changed template
    /// from a stale one without trusting a URI that points at new bytes.
    public var contentHash: String

    public init(
        id: String = UUID().uuidString,
        serverID: String,
        generation: Int,
        resourceURI: String,
        toolName: String,
        arguments: JSONValue,
        result: JSONValue,
        isError: Bool,
        contentHash: String
    ) {
        self.id = id
        self.serverID = serverID
        self.generation = generation
        self.resourceURI = resourceURI
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.contentHash = contentHash
    }

    /// The CallToolResult shape the app is handed, with the content blocks the
    /// attachment keeps. The raw result is re-assembled from the bounded copy so
    /// the wire message is spec-shaped even after a restart.
    public var callResult: JSONValue {
        var object: [String: JSONValue] = [:]
        if let resultObject = result.objectValue {
            for (key, value) in resultObject where key != "content" && key != "isError" {
                object[key] = value
            }
        }
        object["isError"] = .bool(isError)
        if let content = result["content"] {
            object["content"] = content
        }
        return .object(object)
    }
}

// MARK: - The validated resource

/// Content-Security-Policy domains a server declared for its UI, with the
/// restrictive default the spec requires when nothing was declared.
public struct MCPAppCSP: Sendable, Hashable {
    public var connectDomains: [String]
    public var resourceDomains: [String]
    public var frameDomains: [String]
    public var baseUriDomains: [String]

    public init(
        connectDomains: [String] = [],
        resourceDomains: [String] = [],
        frameDomains: [String] = [],
        baseUriDomains: [String] = []
    ) {
        self.connectDomains = connectDomains
        self.resourceDomains = resourceDomains
        self.frameDomains = frameDomains
        self.baseUriDomains = baseUriDomains
    }

    public init?(json: JSONValue) {
        guard let object = json["ui"]?.objectValue?["csp"]?.objectValue
            ?? json["csp"]?.objectValue
        else { return nil }
        self.init(
            connectDomains: object["connectDomains"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            resourceDomains: object["resourceDomains"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            frameDomains: object["frameDomains"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            baseUriDomains: object["baseUriDomains"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    /// The `Content-Security-Policy` applied to the app document. No loosening:
    /// a directive that is empty or unset gets the restrictive default, and only
    /// origins the server declared are ever allowed.
    public var policy: String {
        let directives: [String] = [
            "default-src 'none'",
            "script-src 'self' 'unsafe-inline'" + origins(resourceDomains),
            "style-src 'self' 'unsafe-inline'" + origins(resourceDomains),
            "img-src 'self' data:" + origins(resourceDomains),
            "font-src 'self' data:" + origins(resourceDomains),
            "media-src 'self' data:" + origins(resourceDomains),
            "connect-src" + (connectDomains.isEmpty ? " 'none'" : " " + connectDomains.joined(separator: " ")),
            "object-src 'none'",
            "frame-src" + (frameDomains.isEmpty ? " 'none'" : " " + frameDomains.joined(separator: " ")),
            "base-uri" + (baseUriDomains.isEmpty ? " 'self'" : " " + baseUriDomains.joined(separator: " ")),
        ]
        // `frame-ancestors` has no meaning for a document already inside a
        // sandboxed iframe, and `sandbox` cannot be tightened from a meta tag.
        return directives.joined(separator: "; ")
    }

    private func origins(_ domains: [String]) -> String {
        domains.isEmpty ? "" : " " + domains.joined(separator: " ")
    }
}

/// A `ui://` resource the host has fetched and validated, ready to render.
public struct MCPAppResource: Sendable, Hashable {
    public var uri: String
    public var mimeType: String
    public var html: String
    public var csp: MCPAppCSP
    public var prefersBorder: Bool?
    public var contentHash: String

    public init(
        uri: String,
        mimeType: String,
        html: String,
        csp: MCPAppCSP,
        prefersBorder: Bool?
    ) {
        self.uri = uri
        self.mimeType = mimeType
        self.html = html
        self.csp = csp
        self.prefersBorder = prefersBorder
        self.contentHash = MCPAppResource.hash(html)
    }

    /// The HTML with the security policy prepended, so the sandboxed document
    /// carries its CSP before a single byte of the app parses.
    public var wrappedHTML: String {
        let policy = csp.policy
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.escapeAttribute(policy))\">"
        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            var copy = html
            copy.insert(contentsOf: meta, at: headRange.upperBound)
            return copy
        }
        // No head: the policy goes first anyway, which a parser still honours.
        return "<!doctype html><head>" + meta + "</head>" + html
    }

    private static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func hash(_ html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

/// Why an app could not be rendered. Every case is also the text fallback: the
/// model's result text is shown instead, so a server that fails validation still
/// answers the call.
public enum MCPAppError: Error, LocalizedError, Hashable, Sendable {
    case unsupportedMime(String)
    case invalidURI(String)
    case oversized(Int)
    case emptyResource
    case notNegotiated
    case generationMismatch
    case serverMissing
    case notAppCallable
    case policyDenied(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMime(let mime):
            return "The resource is not an MCP app: '\(mime)'."
        case .invalidURI(let uri):
            return "The resource URI is not a UI resource: '\(uri)'."
        case .oversized(let bytes):
            return "The app is \(bytes) bytes, over the host's limit."
        case .emptyResource:
            return "The server returned an empty app."
        case .notNegotiated:
            return "The server does not advertise MCP Apps support."
        case .generationMismatch:
            return "The app belongs to a connection that has since been replaced."
        case .serverMissing:
            return "The server this app belongs to is not connected."
        case .notAppCallable:
            return "That tool is not callable by the app."
        case .policyDenied(let reason):
            return "Blocked by policy: \(reason)."
        }
    }
}
