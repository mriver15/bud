import Foundation

// MARK: - MCP transport

public enum MCPTransportKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case stdio
    case http
    case sse

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stdio: return "Local process (stdio)"
        case .http: return "Streamable HTTP"
        case .sse: return "Server-Sent Events"
        }
    }

    public var symbol: String {
        switch self {
        case .stdio: return "terminal"
        case .http: return "globe"
        case .sse: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - MCP server configuration

/// Persisted form of one MCP server. Stored at `~/.bud/mcp.json`.
public struct MCPServerConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var transport: MCPTransportKind
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]
    public var enabled: Bool
    public var autoStart: Bool
    /// Which of this server's tools are sent to the model.
    ///
    /// `nil` means all of them — the default, and what every server did before
    /// this existed. An empty array means none. Those have to stay distinguishable:
    /// "send everything" and "send nothing" are both things a person means, and a
    /// single empty value cannot say both. An allowlist rather than a denylist
    /// because the point of it is to keep a handful out of a large surface, and
    /// unticking twenty of twenty-five is not a way to choose five.
    public var enabledTools: [String]?
    /// Registry slug when installed from the marketplace; used to show provenance
    /// and to detect "already installed".
    public var registryName: String?
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        transport: MCPTransportKind = .stdio,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        headers: [String: String] = [:],
        enabled: Bool = true,
        autoStart: Bool = true,
        enabledTools: [String]? = nil,
        registryName: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.autoStart = autoStart
        self.enabledTools = enabledTools
        self.registryName = registryName
        self.notes = notes
    }

    /// Whether this server's `tool` is allowed to reach the model.
    public func sends(tool: String) -> Bool {
        guard let enabledTools else { return true }
        return enabledTools.contains(tool)
    }

    /// Namespace prefix for this server's tools, e.g. `mcp__github__`.
    public var namespace: String { ToolNaming.sanitize(name.lowercased()) }

    /// One-line description shown in Settings.
    public var summary: String {
        switch transport {
        case .stdio:
            return ([command ?? ""] + args).joined(separator: " ")
        case .http, .sse:
            return url ?? ""
        }
    }
}

public enum MCPConnectionState: String, Sendable, Codable {
    case stopped, connecting, ready, failed

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .connecting: return "Connecting…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

public struct MCPServerStatus: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var transport: MCPTransportKind
    public var state: MCPConnectionState
    public var toolCount: Int
    public var serverVersion: String?
    public var error: String?

    public init(
        id: String,
        name: String,
        transport: MCPTransportKind,
        state: MCPConnectionState,
        toolCount: Int = 0,
        serverVersion: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.state = state
        self.toolCount = toolCount
        self.serverVersion = serverVersion
        self.error = error
    }
}

// MARK: - MCP management

@MainActor
public protocol MCPManaging: AnyObject {
    var servers: [MCPServerConfig] { get }
    var statuses: [String: MCPServerStatus] { get }
    /// Flattened tool list across every ready server, for Settings + the model.
    var allTools: [ToolDescriptor] { get }

    func addServer(_ config: MCPServerConfig) async
    func updateServer(_ config: MCPServerConfig) async
    func removeServer(id: String) async
    func connect(id: String) async
    func disconnect(id: String) async
    func restart(id: String) async
    func connectAllAutoStart() async
    func shutdown() async
}

// MARK: - Marketplace

public struct RegistryInstallOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var transport: MCPTransportKind
    public var command: String?
    public var args: [String]
    public var url: String?
    /// Environment variables the server needs before it can run. Names only.
    public var requiredEnv: [String]

    public init(
        id: String,
        label: String,
        transport: MCPTransportKind,
        command: String? = nil,
        args: [String] = [],
        url: String? = nil,
        requiredEnv: [String] = []
    ) {
        self.id = id
        self.label = label
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.requiredEnv = requiredEnv
    }
}

public struct RegistryServer: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var title: String
    public var summary: String
    public var version: String
    public var repositoryURL: String?
    public var websiteURL: String?
    public var iconURL: String?
    public var options: [RegistryInstallOption]

    public init(
        id: String = UUID().uuidString,
        name: String,
        title: String,
        summary: String,
        version: String = "",
        repositoryURL: String? = nil,
        websiteURL: String? = nil,
        iconURL: String? = nil,
        options: [RegistryInstallOption] = []
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.summary = summary
        self.version = version
        self.repositoryURL = repositoryURL
        self.websiteURL = websiteURL
        self.iconURL = iconURL
        self.options = options
    }

    public var displayTitle: String { title.isEmpty ? name : title }
}

@MainActor
public protocol MarketplaceProviding: AnyObject {
    var results: [RegistryServer] { get }
    var query: String { get set }
    var isSearching: Bool { get }
    var loadError: String? { get }
    var totalLoaded: Int { get }
    /// Assigned by the shell so a card can show an "Installed" badge. The store
    /// cannot answer this itself — it does not own the MCP server list.
    var isInstalled: (RegistryServer) -> Bool { get set }

    func loadInitial() async
    func search(_ query: String) async
    /// Pure mapping — the caller decides whether to add the server.
    func makeConfig(from server: RegistryServer, option: RegistryInstallOption) -> MCPServerConfig
}

// MARK: - Subagents

public enum SubagentState: String, Sendable, Codable {
    case queued, running, done, failed, cancelled

    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Working"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

public struct SubagentSpec: Sendable {
    public var title: String
    public var prompt: String
    /// Overrides the parent model when set (e.g. escalate a hard slice to pro).
    public var model: String?
    /// When false the subagent runs without tools — pure reasoning/analysis.
    public var allowTools: Bool
    /// The named agent this runs as. `nil` is an unnamed workstream that behaves
    /// the way subagents always have: every tool, one prompt, the session model.
    public var agent: String?
    /// How deep in the tree this sits. A root run dispatched by the conversation is
    /// 0; work a subagent delegates is 1. Depth is what bounds nesting — see
    /// `SubagentSupervisor.maxDepth`.
    public var depth: Int
    /// The run that delegated this one, when it was a subagent.
    public var parentID: String?

    public init(
        title: String,
        prompt: String,
        model: String? = nil,
        allowTools: Bool = true,
        agent: String? = nil,
        depth: Int = 0,
        parentID: String? = nil
    ) {
        self.title = title
        self.prompt = prompt
        self.model = model
        self.allowTools = allowTools
        self.agent = agent
        self.depth = depth
        self.parentID = parentID
    }
}

public struct SubagentRun: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var prompt: String
    public var model: String
    public var state: SubagentState
    public var output: String
    public var reasoning: String
    public var toolCallCount: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var error: String?
    /// The agent it ran as, when it was named. Shown on the row, because "which
    /// kind of thing did this" is the first thing anyone wants to know about a
    /// delegation, and a title the model invented does not answer it.
    public var agent: String?
    /// The run that delegated it. Children are indented under their parent rather
    /// than listed beside it — a flat list of two depths reads as one list that
    /// happens to be jumbled.
    public var parentID: String?
    /// 0 for work the conversation asked for; 1 for work a subagent delegated.
    public var depth: Int

    public init(
        id: String = UUID().uuidString,
        title: String,
        prompt: String,
        model: String,
        state: SubagentState = .queued,
        output: String = "",
        reasoning: String = "",
        toolCallCount: Int = 0,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        error: String? = nil,
        agent: String? = nil,
        parentID: String? = nil,
        depth: Int = 0
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.model = model
        self.state = state
        self.output = output
        self.reasoning = reasoning
        self.toolCallCount = toolCallCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.agent = agent
        self.parentID = parentID
        self.depth = depth
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

@MainActor
public protocol SubagentSupervising: AnyObject {
    var runs: [SubagentRun] { get }
    /// Runs every spec concurrently and resolves once all have settled.
    func spawn(_ specs: [SubagentSpec]) async -> [SubagentRun]
    func cancel(id: String)
    func clearFinished()
}

// MARK: - Generative UI

public struct GenUIAction: Sendable, Hashable {
    public var id: String
    public var payload: JSONValue

    public init(id: String, payload: JSONValue = .null) {
        self.id = id
        self.payload = payload
    }
}
