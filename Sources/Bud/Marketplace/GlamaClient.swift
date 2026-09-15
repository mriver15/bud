import Foundation

/// Failures from `https://glama.ai/api/mcp`, reported with the evidence needed
/// to act on them: the API answers every failure with its own document
/// (`{"error":{"code":…,"message":…}}`) and that message is written for the
/// reader — the 401 one says where to create a key. Dumping the raw body instead
/// would hide the only useful sentence in it.
public enum GlamaError: Error, LocalizedError, Sendable, Equatable {
    /// No key configured. Thrown before any request is built.
    case missingKey
    case malformedURL(String)
    case transport(String)
    case unauthorized(String?)
    case rateLimited(reset: String?)
    case http(status: Int, code: String?, message: String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Glama needs an API key. Create one at \(GlamaClient.apiKeysURLString) and paste it into Settings → General."
        case .malformedURL(let raw):
            return "The Glama URL is invalid: \(raw)"
        case .transport(let message):
            return "Could not reach Glama: \(message)"
        case .unauthorized(let message):
            return detail("Glama rejected the API key (HTTP 401).", message)
        case .rateLimited(let reset):
            // The endpoint allows 100 requests/second per IP, so a 429 means
            // something is retrying in a loop rather than that the user did
            // anything wrong.
            let window = reset.map { " The limit resets in \($0)s." } ?? ""
            return "Glama's rate limit was reached (HTTP 429; 100 requests per second).\(window)"
        case .http(let status, let code, let message):
            let label = code.map { " (\($0))" } ?? ""
            return detail("Glama returned HTTP \(status)\(label).", message)
        case .decoding(let path):
            return "Could not read Glama's response: \(path)"
        }
    }

    private func detail(_ headline: String, _ message: String?) -> String {
        guard let message, !message.isEmpty else { return headline }
        return "\(headline) \(message)"
    }
}

/// Reads Glama's MCP catalogue: `connectors` (remote servers a publisher hosts,
/// reachable over streamable HTTP) and `servers` (published to be run from
/// source, with no install recipe in the directory).
public struct GlamaClient: Sendable {
    public static let defaultBaseURLString = "https://glama.ai/api/mcp"

    /// Where a key is created. The API's own 401 message points here, and so does
    /// the error Bud shows, so a user who has none is never left guessing.
    public static let apiKeysURLString = "https://glama.ai/settings/api-keys"

    /// The API's page ceiling; `first` above this is clamped rather than allowed
    /// to fail on a caller's arithmetic.
    public static let maximumLimit = 100

    /// A stalled catalogue must not leave the marketplace spinning.
    public static let timeout: TimeInterval = 20

    public let baseURLString: String
    public let apiKey: String
    private let session: URLSession

    public init(
        apiKey: String,
        baseURLString: String = GlamaClient.defaultBaseURLString,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURLString = baseURLString
        self.session = session
    }

    /// One page of hosted connectors, in `sort` order (the API's default:
    /// recommended first). `nextCursor` is `nil` at the end of the list.
    public func connectors(
        query: String?,
        cursor: String?,
        limit: Int
    ) async throws -> (items: [GlamaConnector], nextCursor: String?) {
        let data = try await get(
            path: "/v1/connectors",
            items: Self.queryItems(query: query, cursor: cursor, limit: limit)
        )
        let page: GlamaConnectorPage = try decode(data)
        return (page.connectors.compactMap(\.value), Self.nextCursor(page.pageInfo))
    }

    /// One page of servers published to run from source.
    public func servers(
        query: String?,
        cursor: String?,
        limit: Int
    ) async throws -> (items: [GlamaServer], nextCursor: String?) {
        let data = try await get(
            path: "/v1/servers",
            items: Self.queryItems(query: query, cursor: cursor, limit: limit)
        )
        let page: GlamaServerPage = try decode(data)
        return (page.servers.compactMap(\.value), Self.nextCursor(page.pageInfo))
    }

    // MARK: - Request

    /// Builds the request — and is where an absent key stops the call, before a
    /// session is involved at all, so no unauthenticated round trip is ever spent
    /// collecting a 401.
    ///
    /// Deliberately synchronous and non-private: this is the only path to a
    /// request, so the offline suite can prove the key check, the
    /// `Authorization` header, the limit clamp and the query encoding through it
    /// without touching the network.
    func makeRequest(path: String, items: [URLQueryItem]) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GlamaError.missingKey }

        let target = baseURLString + path
        guard var components = URLComponents(string: target), components.scheme != nil else {
            throw GlamaError.malformedURL(target)
        }
        // Assigning `queryItems` percent-escapes each value exactly once, so a
        // search for `github/foo` is not double-encoded.
        components.queryItems = items
        guard let url = components.url else { throw GlamaError.malformedURL(target) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bud/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func get(path: String, items: [URLQueryItem]) async throws -> Data {
        let request = try makeRequest(path: path, items: items)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GlamaError.transport(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            throw Self.failure(status: status, data: data, response: http)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Reuses the registry client's decoding reporter: both spell out the
            // coding path that broke, which is the difference between "the API
            // changed shape" and "the socket closed mid-body".
            throw GlamaError.decoding(RegistryClient.describe(error))
        }
    }

    // MARK: - Query and failure parsing

    /// `first`, plus `after` and `query` when they carry something.
    static func queryItems(query: String?, cursor: String?, limit: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "first", value: String(clamp(limit)))]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "after", value: cursor))
        }
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "query", value: trimmed))
        }
        return items
    }

    static func clamp(_ limit: Int) -> Int {
        min(max(limit, 1), maximumLimit)
    }

    /// `nil` once the API says there is no next page; otherwise its cursor, which
    /// the pager uses until a page makes no progress.
    private static func nextCursor(_ pageInfo: GlamaPageInfo?) -> String? {
        guard pageInfo?.hasNextPage != false else { return nil }
        return pageInfo?.endCursor
    }

    /// Maps a non-200 to the case that says what to do about it. The status is
    /// the classification; the body only supplies the wording.
    static func failure(status: Int, data: Data, response: HTTPURLResponse?) -> GlamaError {
        let reported = parsedError(in: data)
        switch status {
        case 401:
            return .unauthorized(reported?.message)
        case 429:
            return .rateLimited(reset: response?.value(forHTTPHeaderField: "RateLimit-Reset"))
        default:
            return .http(status: status, code: reported?.code, message: reported?.message)
        }
    }

    /// `error.code` / `error.message` when the body is the API's error document.
    /// A body that is not (a proxy's HTML page, an empty 502) yields nothing, and
    /// the caller falls back to the status line alone.
    static func parsedError(in data: Data) -> (code: String?, message: String?)? {
        let text = String(decoding: data, as: UTF8.self)
        guard let error = JSONValue(parsing: text)?["error"]?.objectValue else { return nil }
        let code = error["code"]?.stringValue
        let message = error["message"]?.stringValue
        guard code != nil || message != nil else { return nil }
        return (code, message)
    }
}
