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

/// How many npm probes may be out at once while a Glama list resolves.
///
/// A probe is one small request to one host and a browse list holds hundreds of
/// rows, so the pass is a sliding window rather than a task per row: enough of
/// them in flight to resolve a page promptly, few enough that npm's registry is
/// never asked for a page and a half of names at the same instant.
private let marketplaceNpmProbeConcurrency = 6

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
            return "glama.ai — hosted connectors install over HTTP; directory entries install from npm where the package exists, and are linked to their repository where it does not."
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
    /// Answers the question a Glama directory row raises. Shared by default, and
    /// so memoised for the process: what npm holds does not change with the
    /// catalogue, the key or the query, and a source switch must not spend the
    /// requests again.
    private let resolver: NpmResolver
    /// The npm questions the rows have raised, and their identities so a row
    /// that arrives from two pages — or from a browse and a search — is one
    /// entry. Kept rather than replaced: a row keeps its option when a search
    /// gives way to the browse list again, and an answer that lands has to be
    /// attachable to whichever list is on screen.
    private var npmCandidates: [GlamaNpmCandidate] = []
    private var npmIdentities: Set<String> = []
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

    public init(client: RegistryClient = RegistryClient(), resolver: NpmResolver = .shared) {
        self.client = client
        self.resolver = resolver
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
        let resolver = self.resolver
        let source = self.source
        let token = loadToken
        return Task { [weak self] in
            var collected: [RegistryServer] = []
            var candidates: [GlamaNpmCandidate] = []
            var cursor: String?
            var failure: String?
            var pages = 0

            while pages < marketplaceMaxInitialPages {
                pages += 1
                do {
                    let page = try await Self.page(
                        source: source, client: client, glama: glama, resolver: resolver,
                        query: nil, cursor: cursor, limit: marketplacePageSize
                    )
                    let before = collected.count
                    collected.append(contentsOf: page.items)
                    candidates.append(contentsOf: page.npmCandidates)
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
            await self.finishInitial(
                collected, npmCandidates: candidates, failure: failure, token: token
            )
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
    ///
    /// A directory row is mapped with whatever npm has *already* answered for its
    /// slug, and its question is returned alongside: the answers still open
    /// arrive later, and a list that waited for the last of them would be a list
    /// that does not render until npm has answered for every row on it.
    nonisolated static func page(
        source: MarketplaceSource,
        client: RegistryClient,
        glama: GlamaClient,
        resolver: NpmResolver,
        query: String?,
        cursor: String?,
        limit: Int
    ) async throws -> (items: [RegistryServer], npmCandidates: [GlamaNpmCandidate], nextCursor: String?) {
        switch source {
        case .official:
            if let query, !query.isEmpty {
                // Relevance-ordered search; the registry takes no cursor here.
                return (try await client.search(query, limit: limit), [], nil)
            }
            let page = try await client.page(cursor: cursor, limit: limit)
            return (page.servers, [], page.nextCursor)
        case .glama:
            let connectors = try await glama.connectors(query: query, cursor: cursor, limit: limit)
            let servers = try await glama.servers(query: query, cursor: nil, limit: limit)
            let candidates = servers.items.map(\.npmCandidate)
            let directory = zip(servers.items, candidates).map { record, candidate in
                record.registryServer(option: candidate.resolvedOption(resolver))
            }
            return (
                connectors.items.map(\.registryServer) + directory,
                candidates,
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
        let resolver = self.resolver
        let source = self.source
        let task = Task { [weak self] in
            let outcome: SearchOutcome
            do {
                let page = try await Self.page(
                    source: source, client: client, glama: glama, resolver: resolver,
                    query: trimmed, cursor: nil, limit: marketplaceSearchLimit
                )
                outcome = .results(page.items, page.npmCandidates)
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

    private func finishInitial(
        _ servers: [RegistryServer],
        npmCandidates candidates: [GlamaNpmCandidate],
        failure: String?,
        token: Int
    ) async {
        // A load that a source or key change superseded must not land on the list
        // the user is now looking at.
        guard token == loadToken else { return }

        note(candidates)
        let rows = applyingNpmAnswers(to: servers)
        initialServers = rows
        // A failed fetch stays retryable: an empty cache must not latch.
        didLoadInitial = !rows.isEmpty

        if lastQuery.isEmpty {
            results = rows
            totalLoaded = rows.count
            loadError = failure
        }
        // Whatever is on screen, these rows will be the browse list again as soon
        // as the query is cleared, so their questions are asked either way.
        startNpmProbes()
    }

    private func finishSearch(_ outcome: SearchOutcome, token: Int) async {
        guard token == queryToken else { return }
        isSearching = false
        switch outcome {
        case .results(let servers, let candidates):
            note(candidates)
            results = applyingNpmAnswers(to: servers)
            totalLoaded = results.count
            loadError = nil
            startNpmProbes()
        case .failure(let message):
            // The previous list stays on screen; the banner explains the gap.
            loadError = message
        }
    }

    // MARK: - npm probing

    /// Remembers the questions the rows raise, one entry per row.
    private func note(_ candidates: [GlamaNpmCandidate]) {
        for candidate in candidates where npmIdentities.insert(candidate.identity).inserted {
            npmCandidates.append(candidate)
        }
    }

    /// The rows as they should be shown: one whose package npm has confirmed
    /// carries the option, and one npm has nothing for stays browse-only.
    ///
    /// Reads only what has already been answered, so it is safe to run while
    /// probes are still out, and it is idempotent — a row that already carries its
    /// option is left exactly as it is.
    private func applyingNpmAnswers(to servers: [RegistryServer]) -> [RegistryServer] {
        guard !npmCandidates.isEmpty else { return servers }
        var options: [String: RegistryInstallOption] = [:]
        for candidate in npmCandidates {
            guard let option = candidate.resolvedOption(resolver) else { continue }
            options[candidate.identity] = option
        }
        guard !options.isEmpty else { return servers }
        return servers.map { server in
            guard server.options.isEmpty, let option = options[server.id] else { return server }
            var row = server
            row.options = [option]
            return row
        }
    }

    /// Asks npm about every row that has no answer yet, and attaches each answer
    /// the moment it lands.
    ///
    /// Deliberately not awaited by the load that raised the questions: the list is
    /// on screen before this starts, and a probe is what *may* add an option to a
    /// row, never a precondition for the row being there. A probe that fails, or
    /// that npm never answers, therefore changes nothing at all — which is what
    /// keeps a slow or unreachable registry from touching the catalogue.
    private func startNpmProbes() {
        // Snapshot before anything closes over it. Declaring this below would
        // shadow the property for the whole function, and the filter below would
        // then be capturing a name that does not exist yet — which some compilers
        // accept and others reject outright.
        let resolver = self.resolver
        var seen = Set<String>()
        let pending = npmCandidates.filter { candidate in
            guard seen.insert(candidate.identity).inserted else { return false }
            return resolver.cachedAnswer(candidate.resolverCandidate) == nil
        }
        guard !pending.isEmpty else { return }

        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                var outstanding = 0
                while next < min(marketplaceNpmProbeConcurrency, pending.count) {
                    let candidate = pending[next]
                    next += 1
                    outstanding += 1
                    group.addTask { await Self.ask(resolver, about: candidate) }
                }
                // Sliding window: each answer admits the next probe, so one slow
                // row never holds up the rest — and the row that just got its
                // answer is redrawn immediately rather than at the end of the
                // pass, which is the difference between options appearing one by
                // one and the list switching over all at once.
                while outstanding > 0 {
                    _ = await group.next()
                    outstanding -= 1
                    if next < pending.count {
                        let candidate = pending[next]
                        next += 1
                        outstanding += 1
                        group.addTask { await Self.ask(resolver, about: candidate) }
                    }
                    self?.attachNpmAnswers()
                }
            }
        }
    }

    /// One probe. Nothing is read from the result: the resolver is the memo, and
    /// the row is redrawn from it, so all this has to do is make sure the question
    /// has been asked.
    private nonisolated static func ask(_ resolver: NpmResolver, about candidate: GlamaNpmCandidate) async {
        _ = await resolver.identifier(namespace: candidate.namespace, slug: candidate.slug)
    }

    /// Republishes both lists from the answers in hand. Idempotent, so the answer
    /// that just landed changes exactly the one row it belongs to.
    private func attachNpmAnswers() {
        initialServers = applyingNpmAnswers(to: initialServers)
        results = applyingNpmAnswers(to: results)
    }

    /// Drops everything the previous source or key produced: the rows, the browse
    /// cache, the query text that belonged to the old catalogue, and the tokens
    /// that would otherwise let a response still in flight land on top of the new
    /// list.
    ///
    /// The npm questions are the exception: they are keyed by Glama's own record
    /// identity, so switching away and back is not a reason to ask npm again.
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
    case results([RegistryServer], [GlamaNpmCandidate])
    case failure(String)
}
