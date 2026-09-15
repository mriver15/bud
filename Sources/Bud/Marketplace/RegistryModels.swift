import Foundation

// MARK: - Wire types
//
// Decoders for `https://registry.modelcontextprotocol.io/v0/servers`.
//
// The registry is community-fed: entries are JSON-Schema-validated but fields
// are added and retired continuously, and one bad record would otherwise take
// the whole page down. So every field except the server name is optional and
// decoded leniently, and a failing entry is contained by `Lossy` — the worst
// case is one missing row in the marketplace, never an empty one.

struct RegistryPage: Decodable, Sendable {
    var servers: [Lossy<RegistryEntry>]
    var metadata: RegistryMetadata?
}

/// Decodes an element in isolation, yielding `nil` when it cannot be read.
struct Lossy<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    var value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct RegistryEntry: Decodable, Sendable {
    var server: RegistryServerPayload
    /// The registry publishes one row per version of a server and flags the
    /// newest one; the flag is not always the last row of the group.
    var isLatest: Bool

    private struct Meta: Decodable, Sendable {
        var official: Official?

        struct Official: Decodable, Sendable {
            var isLatest: Bool?
        }

        private enum CodingKeys: String, CodingKey {
            case official = "io.modelcontextprotocol.registry/official"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case server
        case meta = "_meta"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(RegistryServerPayload.self, forKey: .server)
        isLatest = (try? container.decode(Meta.self, forKey: .meta))?.official?.isLatest ?? false
    }
}

struct RegistryMetadata: Decodable, Sendable {
    var nextCursor: String?
    var count: Int?

    private enum CodingKeys: String, CodingKey {
        case nextCursor
        case count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextCursor = try? container.decode(String.self, forKey: .nextCursor)
        count = try? container.decode(Int.self, forKey: .count)
    }
}

struct RegistryServerPayload: Decodable, Sendable {
    var name: String
    var title: String?
    var description: String?
    var version: String?
    var websiteUrl: String?
    var repository: Repository?
    var icons: [Icon]?
    var packages: [Package]?
    var remotes: [Remote]?

    struct Repository: Decodable, Sendable {
        var url: String?
    }

    struct Icon: Decodable, Sendable {
        var src: String?
        var mimeType: String?
    }

    /// A distributable package (`npm` or `pypi`) launched over stdio. The
    /// registry only ever publishes `transport.type == "stdio"` here, so the
    /// transport is not decoded — a non-stdio package would not be runnable and
    /// is dropped during mapping.
    struct Package: Decodable, Sendable {
        var registryType: String?
        var identifier: String?
        var environmentVariables: [EnvironmentVariable]?
    }

    struct EnvironmentVariable: Decodable, Sendable {
        var name: String?
        var isRequired: Bool?
    }

    struct Remote: Decodable, Sendable {
        var type: String?
        var url: String?
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, version, websiteUrl, repository, icons, packages, remotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try? container.decode(String.self, forKey: .name), !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "registry entry has no server name"
            )
        }
        self.name = name
        title = try? container.decode(String.self, forKey: .title)
        description = try? container.decode(String.self, forKey: .description)
        version = try? container.decode(String.self, forKey: .version)
        websiteUrl = try? container.decode(String.self, forKey: .websiteUrl)
        repository = try? container.decode(Repository.self, forKey: .repository)
        icons = try? container.decode([Icon].self, forKey: .icons)
        packages = try? container.decode([Package].self, forKey: .packages)
        remotes = try? container.decode([Remote].self, forKey: .remotes)
    }
}

// MARK: - Collapsing versions

/// One registry row before de-duplication: one published version of a server.
struct RegistryRow {
    var server: RegistryServer
    var isLatest: Bool

    /// Collapses the several rows one slug can have into a single entry.
    ///
    /// `RegistryServer.id` is the slug, so a list that keeps every version would
    /// hand SwiftUI repeated identities for one row and would offer to install an
    /// arbitrary older version. The winner is the row the registry flags
    /// `isLatest`, falling back to the last row seen — the registry walks a
    /// slug's versions oldest-first, so the last row is the newest when nothing
    /// is flagged. Order is untouched: a slug keeps the position it first
    /// appeared at, which is what keeps search results relevance-ordered.
    static func collapse(_ rows: [RegistryRow]) -> [RegistryServer] {
        var order: [String] = []
        var picked: [String: RegistryRow] = [:]
        for row in rows {
            let slug = row.server.name
            if picked[slug] == nil { order.append(slug) }
            if let current = picked[slug], current.isLatest, !row.isLatest { continue }
            picked[slug] = row
        }
        return order.compactMap { picked[$0]?.server }
    }
}

extension Array where Element == RegistryServer {
    /// Merges pages of already collapsed servers. A slug whose version rows
    /// straddle a page boundary is the only way a duplicate can survive a page,
    /// and later pages carry its newer rows.
    func collapsingDuplicateSlugs() -> [RegistryServer] {
        RegistryRow.collapse(map { RegistryRow(server: $0, isLatest: false) })
    }
}

// MARK: - Mapping to the UI-facing type

extension RegistryServerPayload {
    /// `id` is the registry slug, so a server keeps its identity across
    /// refreshes and the "already installed" check survives re-fetching.
    var registryServer: RegistryServer {
        var options: [RegistryInstallOption] = []
        var seen = Set<String>()
        // Packages first: a local process needs no network or account, so it is
        // the better default when a server offers both flavours.
        for candidate in (packages ?? []).compactMap(\.installOption) + (remotes ?? []).compactMap(\.installOption) {
            guard seen.insert(candidate.id).inserted else { continue }
            options.append(candidate)
        }

        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? name
        return RegistryServer(
            id: name,
            name: name,
            title: resolvedTitle,
            summary: description ?? "",
            version: version ?? "",
            repositoryURL: repository?.url,
            websiteURL: websiteUrl,
            iconURL: preferredIconURL,
            options: options
        )
    }

    /// `AsyncImage` cannot rasterise SVG, and most entries publish an SVG plus a
    /// PNG; take the raster one when it exists instead of rendering a blank box.
    private var preferredIconURL: String? {
        let candidates: [(mime: String, src: String)] = (icons ?? []).compactMap { icon in
            guard let src = icon.src, !src.isEmpty else { return nil }
            return (icon.mimeType ?? "", src)
        }
        if let raster = candidates.first(where: { $0.mime.hasPrefix("image/") && !$0.mime.contains("svg") }) {
            return raster.src
        }
        return candidates.first?.src
    }
}

extension RegistryServerPayload.Package {
    var installOption: RegistryInstallOption? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let command: String
        let registry: String
        switch registryType?.lowercased() {
        case "npm":
            command = "npx"
            registry = "npm"
        case "pypi":
            command = "uvx"
            registry = "pypi"
        default:
            return nil
        }
        // npm packages are published by bare name and resolved at launch, so the
        // `-y` is what makes the install non-interactive.
        let args = registry == "npm" ? ["-y", identifier] : [identifier]
        return RegistryInstallOption(
            id: "\(registry):\(identifier)",
            label: ([command] + args).joined(separator: " "),
            transport: .stdio,
            command: command,
            args: args,
            requiredEnv: requiredEnvNames
        )
    }

    /// Names the server needs in its environment before it will start.
    ///
    /// Producers that model nothing mark nothing, so an entry list with no
    /// `isRequired` anywhere means "all of these matter"; as soon as the field is
    /// used, only the entries actually flagged required are collected.
    private var requiredEnvNames: [String] {
        let declared: [(name: String, isRequired: Bool?)] = (environmentVariables ?? []).compactMap { variable in
            guard let name = variable.name, !name.isEmpty else { return nil }
            return (name, variable.isRequired)
        }
        guard declared.contains(where: { $0.isRequired != nil }) else {
            return declared.map { $0.name }
        }
        return declared.filter { $0.isRequired == true }.map { $0.name }
    }
}

extension RegistryServerPayload.Remote {
    var installOption: RegistryInstallOption? {
        guard let url, !url.isEmpty else { return nil }
        let transport: MCPTransportKind
        switch type?.lowercased() {
        case "streamable-http", "http":
            transport = .http
        case "sse":
            transport = .sse
        default:
            return nil
        }
        return RegistryInstallOption(
            id: "\(transport.rawValue):\(url)",
            label: url,
            transport: transport,
            url: url
        )
    }
}
