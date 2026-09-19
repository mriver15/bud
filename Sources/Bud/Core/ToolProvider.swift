import Foundation

// MARK: - Tool provider

/// Anything that can offer tools to the model: built-in native tools, an MCP
/// server, or the subagent supervisor.
///
/// `invoke` intentionally does not throw. Every failure mode — server crash,
/// timeout, malformed arguments, user denial — is a result the model should see
/// and react to, not an error that aborts the turn.
///
/// The protocol is `@MainActor` because every provider owns observable UI state
/// (connection badges, live subagent rosters). A `nonisolated` requirement would
/// force each one to hand-roll internal hopping for no benefit. Stateless
/// providers such as the native tools stay `nonisolated` in their witnesses,
/// which is a legal narrowing of an isolated requirement.
@MainActor
public protocol ToolProvider: Sendable {
    var providerID: String { get }
    var providerName: String { get }
    /// A monotonically increasing revision for the descriptors this provider
    /// offers. The registry caches the combined tool list and its routing table,
    /// and only re-walks a provider whose revision has moved — so a provider
    /// bumps it exactly when `toolDescriptors()` would return something
    /// different. Static providers (the built-ins) leave the default of zero and
    /// are cached for the life of the process.
    var descriptorRevision: Int { get }
    func toolDescriptors() async -> [ToolDescriptor]
    func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult
    /// Why this provider knows the name but will not answer to it — a tool it has
    /// and is not offering. `nil` when the name means nothing here.
    ///
    /// The registry only routes names that were offered, so a withheld tool never
    /// reaches its owner and would otherwise fail as a typo. This is what lets a
    /// withheld tool say so.
    func withheldReason(for tool: String) async -> String?
}

public extension ToolProvider {
    var descriptorRevision: Int { 0 }
    func withheldReason(for tool: String) async -> String? { nil }
}

/// Providers that must be brought up and torn down (MCP servers, subagent pools).
@MainActor
public protocol LifecycleToolProvider: ToolProvider {
    func start() async throws
    func stop() async
}

// MARK: - Registry

/// Aggregates every provider and routes a tool call to whichever one declared it.
///
/// Namespacing is enforced here rather than trusted from providers: two MCP
/// servers can legitimately both expose a `search` tool, and the model must be
/// able to address them unambiguously.
public actor ToolRegistry {
    private var providers: [String: any ToolProvider] = [:]
    private var order: [String] = []
    /// Tool name -> owning provider id. Built in the same pass as the cached
    /// list, so the table can never route a name the list did not offer.
    private var routing: [String: String] = [:]

    /// The combined descriptor list, valid while `signature` matches the live
    /// revisions. Rebuilt only when a provider's revision has moved.
    private var cachedDescriptors: [ToolDescriptor] = []
    /// The revision each provider last contributed under, keyed by provider id.
    /// A provider that bumps its revision changes this and forces a rebuild.
    private var signature: [String: Int] = [:]

    /// How many times the combined list has been rebuilt. Public so a check can
    /// observe that an unchanged registry serves from cache without re-walking.
    public private(set) var rebuildCount: Int = 0

    public init() {}

    public func register(_ provider: any ToolProvider) async {
        // Identity is MainActor-isolated along with the provider, so it is read
        // across the boundary rather than assumed nonisolated.
        let id = await provider.providerID
        providers[id] = provider
        if !order.contains(id) { order.append(id) }
        // A new provider has no revision recorded yet, so the signature can no
        // longer describe the world. Rebuild now so routing is ready before the
        // next request, matching the pre-cache behaviour.
        signature = [:]
        await rebuildIfNeeded()
    }

    public func unregister(providerID: String) async {
        providers.removeValue(forKey: providerID)
        order.removeAll { $0 == providerID }
        signature = [:]
        await rebuildIfNeeded()
    }

    public func provider(for id: String) -> (any ToolProvider)? { providers[id] }

    public var providerCount: Int { providers.count }

    /// All descriptors, de-duplicated by name. On a collision the later provider
    /// keeps its original name and the earlier one is re-suffixed, so an MCP
    /// server never silently shadows a native tool.
    ///
    /// The list is cached: a request that asks for the tools it was given a
    /// moment ago gets the cached array back without re-walking or re-serialising
    /// any provider. The revision each provider publishes is what decides whether
    /// the cache is still true — an MCP server connects later and bumps its
    /// revision, and only then is the combined list walked again.
    public func descriptors() async -> [ToolDescriptor] {
        await rebuildIfNeeded()
        return cachedDescriptors
    }

    public func invoke(name: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard let pid = routing[name], let provider = providers[pid] else {
            for pid in order {
                guard let p = providers[pid] else { continue }
                if let reason = await p.withheldReason(for: name) { return .error(reason) }
            }
            let known = routing.keys.sorted().prefix(40).joined(separator: ", ")
            return .error("Unknown tool '\(name)'. Available tools: \(known)")
        }
        return await provider.invoke(tool: name, arguments: arguments, callID: callID)
    }

    /// Human-readable source of a tool, for transcript attribution.
    public func providerName(forTool name: String) async -> String {
        guard let pid = routing[name], let p = providers[pid] else { return "Bud" }
        return await p.providerName
    }

    /// Walks the providers only when one of their revisions has moved. The list
    /// and the routing table are committed together, so the routing a call uses
    /// was offered by the same pass's list — the safety property the cache must
    /// not loosen.
    private func rebuildIfNeeded() async {
        var live: [String: Int] = [:]
        for pid in order {
            guard let p = providers[pid] else { continue }
            live[pid] = await p.descriptorRevision
        }
        guard live != signature else { return }

        var seen: Set<String> = []
        var out: [ToolDescriptor] = []
        var table: [String: String] = [:]
        for pid in order {
            guard let p = providers[pid] else { continue }
            for var d in await p.toolDescriptors() {
                if seen.contains(d.name) {
                    var n = 2
                    while seen.contains("\(d.name)_\(n)") { n += 1 }
                    d.name = "\(d.name)_\(n)"
                    d.id = d.name
                }
                seen.insert(d.name)
                table[d.name] = d.providerID
                out.append(d)
            }
        }
        cachedDescriptors = out
        routing = table
        signature = live
        rebuildCount += 1
    }
}

// MARK: - Tool name sanitisation

public enum ToolNaming {
    /// DeepSeek requires function names matching `^[a-zA-Z0-9_-]{1,64}$`.
    /// MCP allows far more, so every external name is funnelled through here.
    public static func sanitize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
            } else if ch == "." || ch == "/" || ch == " " || ch == ":" {
                out.append("_")
            }
        }
        if out.isEmpty { out = "tool" }
        if out.count > 64 { out = String(out.prefix(64)) }
        return out
    }

    /// An MCP tool's name on the wire: `<server>__<tool>`.
    ///
    /// It used to be `mcp__<server>__<tool>`, which said "MCP" twice — the server
    /// half is already derived from the server's own name, so the prefix only
    /// repeated what the namespace had just said. Five characters per tool, paid
    /// on every request and against a hard 64-character ceiling that long
    /// namespaces were already pressing against.
    ///
    /// The double underscore stays. It is the one thing that has to survive: a
    /// single underscore is what native tools use (`read_file`), so `__` is
    /// reserved for the server boundary and a collision with a built-in name is
    /// not reachable by accident.
    ///
    /// The server half is lower-cased so it agrees with
    /// `MCPServerConfig.namespace` — one server must not be addressable under two
    /// different prefixes. The tool half keeps its case for readability in the
    /// tool list; routing is by lookup table, not by the wire name.
    public static func namespaced(server: String, tool: String) -> String {
        sanitize("\(sanitize(server.lowercased()))__\(tool)")
    }
}
