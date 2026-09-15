import Foundation

// MARK: - Wire types
//
// Decoders for `https://glama.ai/api/mcp`. Every field except the three that
// identify a record (`id`, `name`, `slug`) is optional or defaulted, and a record
// that still cannot be read is contained by `Lossy`: Glama's catalogue is
// publisher-fed, so one odd record must cost one row and never the page.

/// One record from `GET /v1/connectors`: a remote MCP server that its publisher
/// hosts and that answers over streamable HTTP.
///
/// The record carries two URLs, and they are not interchangeable:
///
/// - `listingURL` is the API's `url` — Glama's own page for this record. It is
///   what the API Data License requires every surface showing the record to link.
/// - `connection.url` is the MCP endpoint Bud actually connects to. It is not a
///   listing and must never be shown as attribution.
///
/// Swapping them would break installs and breach the licence at the same time.
public struct GlamaConnector: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var slug: String
    public var namespace: String = ""
    /// Glama's listing page for this record (the API's `url`), not the endpoint.
    public var listingURL: String?
    public var description: String?
    public var attributes: [String] = []
    public var qualityScore: Double?
    public var isBoosted: Bool?
    public var thumbnailUrl: String?
    public var repository: GlamaRepository?
    public var deprecatedAt: String?
    public var healthy: Bool?
    public var toolCount: Int?
    /// Where the server answers, and what it expects of a caller.
    public var connection: Connection?

    public struct Connection: Decodable, Sendable, Hashable {
        public var authType: String?
        public var transport: String?
        public var url: String?
    }
}

/// One record from `GET /v1/servers`: an MCP server published for running from
/// source. The directory carries no run command for these, which is why they map
/// to a browse row with no install options — see `registryServer`.
public struct GlamaServer: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var slug: String
    public var namespace: String = ""
    /// Glama's listing page for this record (the API's `url`).
    public var listingURL: String?
    public var description: String?
    public var attributes: [String] = []
    public var qualityScore: Double?
    public var isBoosted: Bool?
    public var thumbnailUrl: String?
    public var repository: GlamaRepository?
    public var spdxLicense: String?
}

/// Glama publishes `repository` either as an object carrying `url` or not at all.
public struct GlamaRepository: Decodable, Sendable, Hashable {
    public var url: String?
}

/// Cursor envelope both list endpoints answer with.
struct GlamaPageInfo: Decodable, Sendable {
    var endCursor: String?
    var hasNextPage: Bool?
}

struct GlamaConnectorPage: Decodable, Sendable {
    var connectors: [Lossy<GlamaConnector>]
    var pageInfo: GlamaPageInfo?
}

struct GlamaServerPage: Decodable, Sendable {
    var servers: [Lossy<GlamaServer>]
    var pageInfo: GlamaPageInfo?
}

// MARK: - Lenient decoding

/// Field reads shared by the two catalogue records.
///
/// Everything but a record's identity is read leniently: a field of an
/// unexpected type reads as absent rather than throwing, because a publisher
/// typo must not cost the whole page. The identity fields are the exception —
/// without them the record cannot be keyed, de-duplicated or installed, so it is
/// dropped by `Lossy` instead of being shown under a made-up name.
private extension KeyedDecodingContainer {
    func glamaIdentity(_ key: Key) throws -> String {
        guard let value = try? decode(String.self, forKey: key), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "Glama record has no \(key.stringValue)"
            )
        }
        return value
    }

    func glamaValue<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension GlamaConnector {
    private enum CodingKeys: String, CodingKey {
        case id, name, slug, namespace, description, attributes
        case qualityScore, isBoosted, thumbnailUrl, repository
        case deprecatedAt, healthy, toolCount, connection
        case listingURL = "url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.glamaIdentity(.id)
        name = try container.glamaIdentity(.name)
        slug = try container.glamaIdentity(.slug)
        namespace = container.glamaValue(String.self, .namespace) ?? ""
        listingURL = container.glamaValue(String.self, .listingURL)
        description = container.glamaValue(String.self, .description)
        attributes = container.glamaValue([String].self, .attributes) ?? []
        qualityScore = container.glamaValue(Double.self, .qualityScore)
        isBoosted = container.glamaValue(Bool.self, .isBoosted)
        thumbnailUrl = container.glamaValue(String.self, .thumbnailUrl)
        repository = container.glamaValue(GlamaRepository.self, .repository)
        deprecatedAt = container.glamaValue(String.self, .deprecatedAt)
        healthy = container.glamaValue(Bool.self, .healthy)
        toolCount = container.glamaValue(Int.self, .toolCount)
        connection = container.glamaValue(Connection.self, .connection)
    }
}

extension GlamaServer {
    private enum CodingKeys: String, CodingKey {
        case id, name, slug, namespace, description, attributes
        case qualityScore, isBoosted, thumbnailUrl, repository, spdxLicense
        case listingURL = "url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.glamaIdentity(.id)
        name = try container.glamaIdentity(.name)
        slug = try container.glamaIdentity(.slug)
        namespace = container.glamaValue(String.self, .namespace) ?? ""
        listingURL = container.glamaValue(String.self, .listingURL)
        description = container.glamaValue(String.self, .description)
        attributes = container.glamaValue([String].self, .attributes) ?? []
        qualityScore = container.glamaValue(Double.self, .qualityScore)
        isBoosted = container.glamaValue(Bool.self, .isBoosted)
        thumbnailUrl = container.glamaValue(String.self, .thumbnailUrl)
        repository = container.glamaValue(GlamaRepository.self, .repository)
        spdxLicense = container.glamaValue(String.self, .spdxLicense)
    }
}

// MARK: - Mapping into the marketplace

/// The fields both catalogue records publish. The row they become, and the name
/// they are known by, are defined once here because they are one rule.
protocol GlamaRecord: Sendable {
    var name: String { get }
    var slug: String { get }
    var namespace: String { get }
    var listingURL: String? { get }
    var description: String? { get }
    var thumbnailUrl: String? { get }
    var repository: GlamaRepository? { get }
}

extension GlamaConnector: GlamaRecord {}
extension GlamaServer: GlamaRecord {}

extension GlamaRecord {
    /// The single identity a record is known by: `RegistryServer.id` and `.name`
    /// here, and `MCPServerConfig.registryName` after an install.
    ///
    /// `isInstalled` answers by comparing `registryName` to `server.name`, so
    /// both ends must be built from this and nothing else, or an installed
    /// server stops showing as installed the moment the list refreshes.
    var registryIdentity: String { "glama:\(namespace)/\(slug)" }

    /// A browse row.
    ///
    /// `websiteURL` carries Glama's listing page: it is the link the API Data
    /// License requires on every record presented, and the only URL on the row
    /// that points at Glama itself rather than at the server's own site.
    func registryRow(options: [RegistryInstallOption]) -> RegistryServer {
        RegistryServer(
            id: registryIdentity,
            name: registryIdentity,
            title: name.isEmpty ? registryIdentity : name,
            summary: description ?? "",
            version: "",
            repositoryURL: repository?.url,
            websiteURL: listingURL,
            iconURL: thumbnailUrl,
            options: options
        )
    }
}

extension GlamaConnector {
    var registryServer: RegistryServer {
        registryRow(options: installOption.map { [$0] } ?? [])
    }

    /// The one way to reach this record: the endpoint its publisher hosts.
    ///
    /// `nil` when Glama published no usable endpoint. A row with no options is
    /// browse-only, which is honest; a fabricated command would not be.
    var installOption: RegistryInstallOption? {
        guard let endpoint = connection?.url, !endpoint.isEmpty else { return nil }
        let note = authorizationNote
        return RegistryInstallOption(
            id: "glama-connector",
            // The endpoint is what Bud connects to, so it is the label; the
            // credential's expected shape rides on the second line, because the
            // option is the only thing the installer form can see and a header
            // the user cannot guess is a header they will get wrong.
            label: note.map { "\(endpoint)\n\($0)" } ?? endpoint,
            transport: .http,
            url: endpoint,
            requiredEnv: note == nil ? [] : ["Authorization"]
        )
    }

    /// What the endpoint expects in `Authorization`, phrased for whoever has to
    /// paste a value. `nil` when Glama says the endpoint takes anonymous callers.
    ///
    /// A missing `authType` is not read as "open": that is unknown, and it is
    /// better to ask for a header that turns out to be unnecessary than to
    /// connect with no credentials against an endpoint that quietly answers
    /// `initialize` and then refuses every tool call.
    var authorizationNote: String? {
        let authType = (connection?.authType ?? "").lowercased()
        switch authType {
        case "none":
            return nil
        case "basic":
            return "Authorization: Basic <base64 user:password>"
        case "oauth2":
            return "Authorization: Bearer <token> — OAuth 2.0. Discover the endpoints at /.well-known/oauth-authorization-server; Bud does not run the OAuth flow."
        default:
            return "Authorization: Bearer <key>"
        }
    }
}

extension GlamaServer {
    /// Browse-only, and deliberately so: Glama's `servers` directory publishes no
    /// npm or PyPI identifier and no run command, so there is nothing to install.
    ///
    /// `npx -y <slug>` would look plausible and be wrong — an install that cannot
    /// start is worse than a card that says so and hands over the repository.
    var registryServer: RegistryServer { registryRow(options: []) }
}
