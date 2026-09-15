import Foundation

/// Failures are reported with the evidence needed to act on them — the registry
/// answers with ProblemDetails JSON (`{"title":…,"detail":…}`), and a bare
/// "request failed" would hide the one useful sentence it sent back.
public enum RegistryClientError: Error, LocalizedError, Sendable {
    case malformedURL(String)
    case transport(String)
    case badStatus(status: Int, detail: String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .malformedURL(let raw):
            return "The registry URL is invalid: \(raw)"
        case .transport(let message):
            return "Could not reach the MCP registry: \(message)"
        case .badStatus(let status, let detail):
            return "The MCP registry returned HTTP \(status): \(detail)"
        case .decoding(let detail):
            return "Could not read the MCP registry response: \(detail)"
        }
    }
}

/// Reads the public MCP registry (the source behind the marketplace browser).
public struct RegistryClient: Sendable {
    public static let defaultBaseURLString = "https://registry.modelcontextprotocol.io/v0/servers"

    /// The registry rejects `limit` above 100 with HTTP 422, so requests are
    /// clamped rather than allowed to fail on a caller's arithmetic.
    public static let maximumLimit = 100

    /// A stalled registry must not leave the marketplace spinning; 20s is long
    /// enough for a cold TLS handshake on a slow link.
    public static let timeout: TimeInterval = 20

    public let baseURLString: String
    private let session: URLSession

    public init(
        baseURLString: String = RegistryClient.defaultBaseURLString,
        session: URLSession = .shared
    ) {
        self.baseURLString = baseURLString
        self.session = session
    }

    /// One page of the registry, in registry order. `nextCursor` is `nil` when
    /// the caller has reached the end.
    ///
    /// The page is collapsed by slug: the registry publishes one row per version,
    /// so a raw page of 100 usually holds ~60 servers — several versions of each.
    public func page(cursor: String?, limit: Int) async throws -> (servers: [RegistryServer], nextCursor: String?) {
        var items = [URLQueryItem(name: "limit", value: String(Self.clamp(limit)))]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let payload = try await fetch(items)
        return (Self.servers(in: payload), payload.metadata?.nextCursor)
    }

    /// Relevance-ordered search. Encoding is left to `URLComponents`, which
    /// percent-escapes the query exactly once (slugs contain `/`).
    public func search(_ query: String, limit: Int) async throws -> [RegistryServer] {
        var items = [URLQueryItem(name: "limit", value: String(Self.clamp(limit)))]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmed))
        }
        let payload = try await fetch(items)
        return Self.servers(in: payload)
    }

    /// Collapses raw rows into installable servers, newest version per slug.
    private static func servers(in payload: RegistryPage) -> [RegistryServer] {
        RegistryRow.collapse(payload.servers.compactMap { entry in
            entry.value.map { RegistryRow(server: $0.server.registryServer, isLatest: $0.isLatest) }
        })
    }

    // MARK: - Transport

    private func fetch(_ items: [URLQueryItem]) async throws -> RegistryPage {
        guard var components = URLComponents(string: baseURLString), components.scheme != nil else {
            throw RegistryClientError.malformedURL(baseURLString)
        }
        components.queryItems = items
        guard let url = components.url else {
            throw RegistryClientError.malformedURL(baseURLString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bud/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RegistryClientError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw RegistryClientError.badStatus(status: status, detail: Self.failureDetail(in: data))
        }

        do {
            return try JSONDecoder().decode(RegistryPage.self, from: data)
        } catch {
            throw RegistryClientError.decoding(Self.describe(error))
        }
    }

    private static func clamp(_ limit: Int) -> Int {
        min(max(limit, 1), maximumLimit)
    }

    /// Prefers the registry's own error document over a raw body dump; falls
    /// back to a prefix when a proxy or HTML error page answered instead.
    static func failureDetail(in data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        if let object = JSONValue(parsing: text)?.objectValue {
            let parts = [object["title"]?.stringValue, object["detail"]?.stringValue]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " — ") }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "empty response body" : String(trimmed.prefix(300))
    }

    /// Turns a `DecodingError` into the path that broke, which is the difference
    /// between "the registry changed shape" and "a socket closed mid-body".
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context.codingPath)) — \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "unexpected null for \(type) at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            let location = context.codingPath.isEmpty ? "" : " at \(path(context.codingPath))"
            return context.debugDescription + location
        @unknown default:
            return String(describing: decoding)
        }
    }

    static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the document root" }
        let joined = codingPath.map { key in
            key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
        }.joined()
        return joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
    }
}
