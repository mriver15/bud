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
    func toolDescriptors() async -> [ToolDescriptor]
    func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult
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
    /// Tool name -> owning provider id, rebuilt whenever providers change.
    private var routing: [String: String] = [:]

    public init() {}

    public func register(_ provider: any ToolProvider) async {
        // Identity is MainActor-isolated along with the provider, so it is read
        // across the boundary rather than assumed nonisolated.
        let id = await provider.providerID
        providers[id] = provider
        if !order.contains(id) { order.append(id) }
        await rebuildRouting()
    }

    public func unregister(providerID: String) async {
        providers.removeValue(forKey: providerID)
        order.removeAll { $0 == providerID }
        await rebuildRouting()
    }

    public func provider(for id: String) -> (any ToolProvider)? { providers[id] }

    public var providerCount: Int { providers.count }

    /// All descriptors, de-duplicated by name. On a collision the later provider
    /// keeps its original name and the earlier one is re-suffixed, so an MCP
    /// server never silently shadows a native tool.
    public func descriptors() async -> [ToolDescriptor] {
        var seen: Set<String> = []
        var out: [ToolDescriptor] = []
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
                out.append(d)
            }
        }
        return out
    }

    public func wireToolDefinitions() async -> [JSONValue] {
        await descriptors().map(\.wireRepresentation)
    }

    public func invoke(name: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard let pid = routing[name], let provider = providers[pid] else {
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

    private func rebuildRouting() async {
        routing = [:]
        for d in await descriptors() { routing[d.name] = d.providerID }
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

    /// The server half is lower-cased so it agrees with
    /// `MCPServerConfig.namespace` — one server must not be addressable under two
    /// different prefixes. The tool half keeps its case for readability in the
    /// tool list; routing is by lookup table, not by the wire name.
    public static func namespaced(server: String, tool: String) -> String {
        sanitize("mcp__\(server.lowercased())__\(tool)")
    }
}
