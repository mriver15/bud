import Foundation
import Observation

/// The registry caps a page at 100 servers, which is also the smallest number
/// of round-trips that fills a browseable list.
private let marketplacePageSize = 100

/// Fetched on open so the marketplace is never an empty box: ~3 pages of the
/// newest publications.
private let marketplaceTargetCount = 300

/// Backstop for a registry that keeps handing back cursors — a burst of pages is
/// still a bounded amount of work during launch.
private let marketplaceMaxInitialPages = 8

/// Search results come back relevance-ordered from the registry; one page is
/// enough for a query, and more would slow every keystroke's worth of work.
private let marketplaceSearchLimit = 100

/// Browse + install state for the MCP marketplace.
///
/// Owns the registry list, the in-flight request, and the small amount of
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

    /// The query `results` correspond to. Kept apart from `query` because the
    /// field is edited keystroke by keystroke while results legitimately lag.
    public private(set) var lastQuery = ""

    private let client: RegistryClient
    /// The unfiltered first pages, so clearing the field restores the browse
    /// list without a second round-trip.
    private var initialServers: [RegistryServer] = []
    private var didLoadInitial = false
    private var initialTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Incremented per accepted query; a result carrying a stale token is dropped.
    private var queryToken = 0

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

        let client = self.client
        let task = Task { [client, weak self] in
            var collected: [RegistryServer] = []
            var cursor: String?
            var failure: String?
            var pages = 0

            while pages < marketplaceMaxInitialPages {
                pages += 1
                do {
                    let page = try await client.page(cursor: cursor, limit: marketplacePageSize)
                    let before = collected.count
                    collected.append(contentsOf: page.servers)
                    // A page carries one row per published version, so counting
                    // rows would mistake a normal ~60-server page for the end of
                    // the list; staleness is what marks the end instead.
                    collected = collected.collapsingDuplicateSlugs()
                    cursor = collected.count == before ? nil : page.nextCursor
                } catch {
                    failure = error.localizedDescription
                    cursor = nil
                }
                if cursor == nil || collected.count >= marketplaceTargetCount { break }
            }

            guard let self else { return }
            await self.finishInitial(collected, failure: failure)
        }

        initialTask = task
        await task.value
        initialTask = nil
    }

    /// Re-fetches from scratch. Used by the error banner's Retry button and the
    /// toolbar refresh control.
    public func reload() async {
        await initialTask?.value
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
        let task = Task { [client, weak self] in
            let outcome: SearchOutcome
            do {
                outcome = .results(try await client.search(trimmed, limit: marketplaceSearchLimit))
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
        // Blank values, not omitted keys: Settings has to show exactly which
        // variables stand between the user and a working server.
        var env: [String: String] = [:]
        for name in option.requiredEnv { env[name] = "" }

        return MCPServerConfig(
            id: UUID().uuidString,
            name: server.displayTitle,
            transport: option.transport,
            command: option.command,
            args: option.args,
            env: env,
            url: option.url,
            headers: [:],
            enabled: true,
            autoStart: true,
            registryName: server.name
        )
    }

    // MARK: - Completion

    private func finishInitial(_ servers: [RegistryServer], failure: String?) async {
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
}

/// What a debounced search produced. A plain `Result` would need its failure to
/// be an `Error`, and the only thing that survives the hop back to the main actor
/// is the message the user reads.
private enum SearchOutcome: Sendable {
    case results([RegistryServer])
    case failure(String)
}
