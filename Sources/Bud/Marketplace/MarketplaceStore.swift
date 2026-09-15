import Foundation
import Observation

/// The registry caps a page at 100 servers, which is also the smallest number
/// of round-trips that fills a browseable list. Glama's endpoints cap `first` at
/// 100 too, so one page size serves both catalogues.
private let marketplacePageSize = 100

/// Fetched on open so the marketplace is never an empty box: ~3 pages of the
/// newest publications.
private let marketplaceTargetCount = 300

/// Backstop for a source that keeps handing back cursors — a burst of pages is
/// still a bounded amount of work during launch.
private let marketplaceMaxInitialPages = 8

/// Search results come back relevance-ordered from the source; one page is
/// enough for a query, and more would slow every keystroke's worth of work.
private let marketplaceSearchLimit = 100

// MARK: - Source

/// Which catalogue the marketplace is browsing.
///
/// Two lists, not one merged pool: an official-registry slug and a Glama record
/// can describe the same server under different identities, and folding them
/// together would double-list it and make "installed" ambiguous.
public enum MarketplaceSource: String, CaseIterable, Sendable, Identifiable {
    case official, glama

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .official: return "Official Registry"
        case .glama: return "Glama"
        }
    }

    /// One line for the pane's subtitle: what the source is and what to expect
    /// from it.
    public var blurb: String {
        switch self {
        case .official:
            return "registry.modelcontextprotocol.io — packages and remote endpoints, installable in one click."
        case .glama:
            return "glama.ai — hosted connectors install over HTTP; entries that publish no run command are linked instead."
        }
    }
}

/// Keeps the first row per identity.
///
/// Glama can publish one server as both a connector and a directory entry, and
/// one identity has to mean one row: `ForEach` keys by `id`, and a duplicate
/// would draw the record twice and behave unpredictably. Connectors are listed
/// first, so the installable record is the one that survives.
private func dedupedByIdentity(_ servers: [RegistryServer]) -> [RegistryServer] {
    var seen = Set<String>()
    var unique: [RegistryServer] = []
    for server in servers where seen.insert(server.id).inserted {
        unique.append(server)
    }
    return unique
}

/// Browse + install state for the MCP marketplace.
///
/// Owns the catalogue list, the in-flight request, and the small amount of
/// bookkeeping needed to keep a debounced search field honest: results are only
/// written by the query that is still current.
@MainActor
@Observable
public final class MarketplaceStore: MarketplaceProviding {
    public private(set) var results: [RegistryServer] = []
    public var query: String = ""
    public private(set) var isSearching = false
    public private(set) var loadError: String?
    public private(set) var totalLoaded = 0
    /// Assigned by the shell; the store does not own the MCP server list.
    public var isInstalled: (RegistryServer) -> Bool = { _ in false }

    /// Which catalogue is on screen. Switching clears the list and reloads:
    /// nothing the previous source produced is meaningful under the new one.
    public var source: MarketplaceSource = .official {
        didSet {
            guard source != oldValue else { return }
            resetForNewCatalogue()
            // A setter cannot await, so the reload starts here; the pane's empty
            // state covers the gap until the first page lands.
            initialTask = makeInitialTask()
        }
    }

    /// Glama's key, mirrored from `BudConfig` by the shell — the store does not
    /// own the config. A client is built per request from this, so a key entered
    /// in Settings takes effect without a relaunch.
    public var glamaAPIKey: String = "" {
        didSet {
            guard glamaAPIKey != oldValue, source == .glama else { return }
            // Everything on screen was fetched with the previous key: it may be
            // an error, or a shorter list than this key is entitled to.
            resetForNewCatalogue()
            initialTask = makeInitialTask()
        }
    }

    /// True when Glama is selected but no key is configured.
    ///
    /// This is a call to action, not a failure: nothing was attempted, so it must
    /// not be reported through `loadError`.
    public var glamaKeyMissing: Bool {
        source == .glama && glamaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The query `results` correspond to. Kept apart from `query` because the
    /// field is edited keystroke by keystroke while results legitimately lag.
    public private(set) var lastQuery = ""

    private let client: RegistryClient
    /// Built per request from `glamaAPIKey`; a `GlamaClient` is a few field
    /// assignments around `URLSession.shared`.
    private var glamaClient: GlamaClient { GlamaClient(apiKey: glamaAPIKey) }
    /// The unfiltered first pages, so clearing the field restores the browse
    /// list without a second round-trip.
    private var initialServers: [RegistryServer] = []
    private var didLoadInitial = false
    private var initialTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Incremented per accepted query; a result carrying a stale token is dropped.
    private var queryToken = 0
    /// The same idea for the browse list: a load superseded by a source or key
    /// change must not write its rows into the list that is now on screen.
    private var loadToken = 0

    public init(client: RegistryClient = RegistryClient()) {
        self.client = client
    }

    // MARK: - Loading

    public func loadInitial() async {
        if didLoadInitial { return }
        if let initialTask {
            await initialTask.value
            return
        }

        let task = makeInitialTask()
        initialTask = task
        await task.value
        initialTask = nil
    }

    /// The paging loop as a task of its own, so a source or key change can start
    /// a fresh load from a synchronous setter.
    private func makeInitialTask() -> Task<Void, Never> {
        let client = self.client
        let glama = glamaClient
        let source = self.source
        let token = loadToken
        return Task { [weak self] in
            var collected: [RegistryServer] = []
            var cursor: String?
            var failure: String?
            var pages = 0

            while pages < marketplaceMaxInitialPages {
                pages += 1
                do {
                    let page = try await Self.page(
                        source: source, client: client, glama: glama,
                        query: nil, cursor: cursor, limit: marketplacePageSize
                    )
                    let before = collected.count
                    collected.append(contentsOf: page.items)
                    // A registry page carries one row per published version, so
                    // counting rows would mistake a normal ~60-server page for
                    // the end of the list; staleness is what marks the end
                    // instead. Glama publishes one record per server, but the
                    // same one can arrive from both of its endpoints.
                    collected = source == .official
                        ? collected.collapsingDuplicateSlugs()
                        : dedupedByIdentity(collected)
                    cursor = collected.count == before ? nil : page.nextCursor
                } catch {
                    failure = error.localizedDescription
                    cursor = nil
                }
                if cursor == nil || collected.count >= marketplaceTargetCount { break }
            }

            guard let self else { return }
            await self.finishInitial(collected, failure: failure, token: token)
        }
    }

    /// One page of whichever catalogue is selected, mapped into marketplace rows.
    ///
    /// Pure and non-isolated so the paging task can call it exactly as it called
    /// the registry client before.
    ///
    /// Glama's two endpoints are read together: `connectors` are hosted and
    /// installable, `servers` are published to run from source and can only be
    /// linked — and both are worth showing. Paging follows the connector cursor,
    /// because every row behind that list has a real endpoint.
    nonisolated static func page(
        source: MarketplaceSource,
        client: RegistryClient,
        glama: GlamaClient,
        query: String?,
        cursor: String?,
        limit: Int
    ) async throws -> (items: [RegistryServer], nextCursor: String?) {
        switch source {
        case .official:
            if let query, !query.isEmpty {
                // Relevance-ordered search; the registry takes no cursor here.
                return (try await client.search(query, limit: limit), nil)
            }
            let page = try await client.page(cursor: cursor, limit: limit)
            return (page.servers, page.nextCursor)
        case .glama:
            let connectors = try await glama.connectors(query: query, cursor: cursor, limit: limit)
            let servers = try await glama.servers(query: query, cursor: nil, limit: limit)
            return (
                connectors.items.map(\.registryServer) + servers.items.map(\.registryServer),
                connectors.nextCursor
            )
        }
    }

    /// Re-fetches from scratch. Used by the error banner's Retry button and the
    /// toolbar refresh control.
    public func reload() async {
        await initialTask?.value
        initialTask = nil
        didLoadInitial = false
        await loadInitial()
    }

    // MARK: - Search

    public func search(_ query: String) async {
        self.query = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = trimmed
        queryToken &+= 1
        let token = queryToken
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            // Clearing the field restores the browse list; the error banner is
            // left alone because no fetch happened.
            searchTask = nil
            isSearching = false
            results = initialServers
            totalLoaded = initialServers.count
            return
        }

        isSearching = true
        loadError = nil
        let client = self.client
        let glama = glamaClient
        let source = self.source
        let task = Task { [weak self] in
            let outcome: SearchOutcome
            do {
                let page = try await Self.page(
                    source: source, client: client, glama: glama,
                    query: trimmed, cursor: nil, limit: marketplaceSearchLimit
                )
                outcome = .results(page.items)
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            guard let self else { return }
            await self.finishSearch(outcome, token: token)
        }

        searchTask = task
        await task.value
    }

    // MARK: - Install mapping

    public func makeConfig(from server: RegistryServer, option: RegistryInstallOption) -> MCPServerConfig {
        Self.makeConfig(from: server, option: option)
    }

    /// Pure mapping from a catalogue row to a persisted server config — static
    /// and non-isolated so the offline self-test can exercise exactly this code,
    /// which is the mapping most likely to be silently wrong.
    ///
    /// Credentials are placed by transport, and that branch is the point of this
    /// function: `env` is read only by the stdio transport, where it becomes the
    /// child process's environment, while the HTTP and SSE transports read
    /// `headers`. A key written to `env` for an HTTP server is never sent — and
    /// the failure is quiet, because many remote servers still answer
    /// `initialize` unauthenticated and only refuse the tool calls.
    nonisolated static func makeConfig(
        from server: RegistryServer,
        option: RegistryInstallOption,
        credentials: [String: String] = [:]
    ) -> MCPServerConfig {
        // Blank values, not omitted keys: Settings has to show exactly which
        // variables stand between the user and a working server.
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        for name in option.requiredEnv {
            let value = credentials[name] ?? ""
            switch option.transport {
            case .stdio: env[name] = value
            case .http, .sse: headers[name] = value
            }
        }

        return MCPServerConfig(
            id: UUID().uuidString,
            name: server.displayTitle,
            transport: option.transport,
            command: option.command,
            args: option.args,
            env: env,
            url: option.url,
            headers: headers,
            enabled: true,
            autoStart: true,
            // The row's identity, and what `isInstalled` compares against: for
            // Glama that is the `glama:<namespace>/<slug>` scheme.
            registryName: server.name
        )
    }

    // MARK: - Completion

    private func finishInitial(_ servers: [RegistryServer], failure: String?, token: Int) async {
        // A load that a source or key change superseded must not land on the list
        // the user is now looking at.
        guard token == loadToken else { return }

        initialServers = servers
        // A failed fetch stays retryable: an empty cache must not latch.
        didLoadInitial = !servers.isEmpty

        guard lastQuery.isEmpty else { return }
        results = servers
        totalLoaded = servers.count
        loadError = failure
    }

    private func finishSearch(_ outcome: SearchOutcome, token: Int) async {
        guard token == queryToken else { return }
        isSearching = false
        switch outcome {
        case .results(let servers):
            results = servers
            totalLoaded = servers.count
            loadError = nil
        case .failure(let message):
            // The previous list stays on screen; the banner explains the gap.
            loadError = message
        }
    }

    /// Drops everything the previous source or key produced: the rows, the browse
    /// cache, the query text that belonged to the old catalogue, and the tokens
    /// that would otherwise let a response still in flight land on top of the new
    /// list.
    private func resetForNewCatalogue() {
        searchTask?.cancel()
        searchTask = nil
        initialTask?.cancel()
        initialTask = nil
        loadToken &+= 1
        queryToken &+= 1
        initialServers = []
        results = []
        totalLoaded = 0
        loadError = nil
        didLoadInitial = false
        lastQuery = ""
        query = ""
    }
}

/// What a debounced search produced. A plain `Result` would need its failure to
/// be an `Error`, and the only thing that survives the hop back to the main actor
/// is the message the user reads.
private enum SearchOutcome: Sendable {
    case results([RegistryServer])
    case failure(String)
}
