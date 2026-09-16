import Foundation
import Observation

/// Owns every MCP server Bud knows about: the persisted configuration, one
/// `MCPClient` per running server, and the tool surface they contribute.
///
/// `@MainActor` because it publishes observable state for Settings and the
/// transcript; nothing here blocks, since every wire interaction lives behind a
/// client actor.
@MainActor
@Observable
public final class MCPManager: MCPManaging, ToolProvider {
    public let providerID = "mcp"
    public let providerName = "MCP"

    public private(set) var servers: [MCPServerConfig] = []
    public private(set) var statuses: [String: MCPServerStatus] = [:]
    public private(set) var allTools: [ToolDescriptor] = []
    /// Everything each server offers, whether or not it is being sent. Observable
    /// because the tool picker chooses *from* this: it is the tools that are not
    /// being sent that it exists to show, so it cannot read the served surface.
    public private(set) var discoveredByServer: [String: [ToolDescriptor]] = [:]

    @ObservationIgnored private var clients: [String: MCPClient] = [:]
    /// Bumped by every teardown and every connect attempt for a server, so an
    /// attempt that has been superseded can tell that it no longer owns the
    /// connection.
    @ObservationIgnored private var connectTokens: [String: Int] = [:]
    private var toolsByServer: [String: [ToolDescriptor]] = [:]
    private var logBuffers: [String: [String]] = [:]

    private static let logLimit = 200
    /// Four at a time: connecting a dozen servers at once spawns a dozen node
    /// processes and thrashes both the machine and the network for no gain.
    private static let autostartConcurrency = 4

    public init() {
        let stored = Self.readStored()
        servers = stored
        for config in stored { statuses[config.id] = Self.stoppedStatus(config) }
    }

    // MARK: Server list

    public func addServer(_ config: MCPServerConfig) async {
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
        } else {
            servers.append(config)
        }
        persist()
        statuses[config.id] = Self.stoppedStatus(config)
        appendLog(config.id, "Added \(config.transport.label) server '\(config.name)'.")
        // A server the user just added is one they expect to use; `autoStart`
        // governs launch behaviour, not this.
        if config.enabled { await connect(id: config.id) } else { await refreshTools() }
    }

    public func updateServer(_ config: MCPServerConfig) async {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else {
            await addServer(config)
            return
        }
        let previous = servers[index]
        servers[index] = config
        persist()
        guard previous != config else { return }
        // Any edit — endpoint, arguments, enabled flag — invalidates the running
        // process, so the old one is released before a new one is dialled.
        await stopClient(id: config.id)
        if config.enabled {
            appendLog(config.id, "Configuration changed; reconnecting.")
            await connect(id: config.id)
        } else {
            statuses[config.id] = Self.stoppedStatus(config)
            appendLog(config.id, "Disabled.")
            await refreshTools()
        }
    }

    /// Changes which of a server's tools are sent, without touching its
    /// connection.
    ///
    /// Deliberately not `updateServer`: that treats every difference as a new
    /// endpoint and tears the process down, which for a server started with `npx`
    /// costs seconds of handshake to decide whether one checkbox is ticked. The
    /// tools are already in hand — `refreshTools` re-publishes from the client's
    /// own cache without going near the wire.
    public func setEnabledTools(_ tools: [String]?, for id: String) async {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        guard servers[index].enabledTools != tools else { return }
        servers[index].enabledTools = tools
        persist()
        await refreshTools()
    }

    public func removeServer(id: String) async {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        appendLog(id, "Removing '\(config.name)'.")
        await stopClient(id: id)
        servers.removeAll { $0.id == id }
        statuses.removeValue(forKey: id)
        toolsByServer.removeValue(forKey: id)
        connectTokens.removeValue(forKey: id)
        logBuffers.removeValue(forKey: id)
        persist()
        await refreshTools()
    }

    // MARK: Connection

    public func connect(id: String) async {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        await stopClient(id: id)
        // Claim ownership *after* the teardown: a handshake that is still in
        // flight for this server is now stale, and one that finishes later must
        // not publish a status or keep a process nobody is tracking.
        let token = claimConnect(id)
        guard config.enabled else {
            statuses[id] = Self.stoppedStatus(config)
            appendLog(id, "Skipped: the server is disabled.")
            return
        }
        if let problem = MCPTransportFactory.problem(with: config) {
            statuses[id] = MCPServerStatus(
                id: id, name: config.name, transport: config.transport,
                state: .failed, error: problem
            )
            appendLog(id, "Cannot connect: \(problem)")
            await refreshTools()
            return
        }

        statuses[id] = MCPServerStatus(
            id: id, name: config.name, transport: config.transport, state: .connecting
        )
        appendLog(id, "Connecting — \(config.summary)")
        let client = MCPClient(config: config)
        clients[id] = client
        do {
            try await client.connect()
            guard isCurrentConnect(id, token) else {
                await client.stop()
                return
            }
            let tools = await client.cachedTools
            let info = await client.serverInfo
            statuses[id] = MCPServerStatus(
                id: id, name: config.name, transport: config.transport,
                state: .ready, toolCount: tools.count, serverVersion: info?.version
            )
            let version = (info?.version).flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
            appendLog(id, "Connected to \(info?.name ?? config.name)\(version) — \(Self.toolCount(tools.count)).")
        } catch {
            let diagnostics = await client.diagnostics
            await client.stop()
            guard isCurrentConnect(id, token) else { return }
            let message = Self.failureMessage(error: error, diagnostics: diagnostics)
            statuses[id] = MCPServerStatus(
                id: id, name: config.name, transport: config.transport,
                state: .failed, error: message
            )
            appendLog(id, "Failed to connect — \(message)")
            clients.removeValue(forKey: id)
        }
        await refreshTools()
    }

    public func disconnect(id: String) async {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        await stopClient(id: id)
        statuses[id] = Self.stoppedStatus(config)
        appendLog(id, "Disconnected.")
        await refreshTools()
    }

    public func restart(id: String) async {
        guard servers.contains(where: { $0.id == id }) else { return }
        appendLog(id, "Restarting.")
        // `stopClient` awaits the process's death before `connect` spawns a
        // replacement, so two servers never share a pipe.
        await stopClient(id: id)
        await connect(id: id)
    }

    public func connectAllAutoStart() async {
        let ids = servers.filter { $0.enabled && $0.autoStart }.map(\.id)
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            var outstanding = 0
            while next < min(Self.autostartConcurrency, ids.count) {
                let id = ids[next]
                next += 1
                outstanding += 1
                group.addTask { await self.connect(id: id) }
            }
            // Sliding window: each completion admits the next server, so the
            // fast ones are never held up by the slow ones.
            while outstanding > 0 {
                _ = await group.next()
                outstanding -= 1
                if next < ids.count {
                    let id = ids[next]
                    next += 1
                    outstanding += 1
                    group.addTask { await self.connect(id: id) }
                }
            }
        }
        await refreshTools()
    }

    public func shutdown() async {
        for id in Array(clients.keys) { await stopClient(id: id) }
        for (id, status) in statuses where status.state != .stopped {
            statuses[id] = MCPServerStatus(
                id: status.id, name: status.name, transport: status.transport, state: .stopped
            )
        }
        toolsByServer = [:]
        allTools = []
    }

    // MARK: ToolProvider

    public func toolDescriptors() async -> [ToolDescriptor] {
        await collect().flat
    }

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        if Task.isCancelled { return .error("cancelled") }
        guard let route = await route(for: tool) else {
            return .error("Unknown MCP tool '\(tool)'. No connected MCP server exposes it.")
        }
        guard let client = clients[route.serverID] else {
            return .error("MCP server '\(route.serverName)' is not connected. Reconnect it in Settings.")
        }
        do {
            let result = try await client.callTool(name: route.tool, arguments: arguments)
            appendLog(
                route.serverID,
                result.isError
                    ? "✗ \(route.tool): \(Self.firstLine(result.text))"
                    : "✓ \(route.tool)"
            )
            return result
        } catch is CancellationError {
            return .error("cancelled")
        } catch {
            let failure = MCPError.wrap(error)
            let detail = failure.errorDescription ?? "unknown error"
            appendLog(route.serverID, "✗ \(route.tool): \(detail)")
            if case .transportClosed = failure,
               let config = servers.first(where: { $0.id == route.serverID }) {
                await markFailed(config, reason: "The server closed the connection.")
            }
            return .error("MCP tool '\(tool)' failed: \(detail)")
        }
    }

    // MARK: Diagnostics

    /// Per-server ring buffer of connection events and captured server output,
    /// oldest first, capped at 200 lines.
    public func logs(id: String) -> [String] { logBuffers[id] ?? [] }

    public func clearLogs(id: String) { logBuffers[id] = [] }

    /// Cached descriptors for one server. Synchronous so a view can call it while
    /// rendering; call `refreshTools()` when a fresh read is needed.
    public func serverTools(id: String) -> [ToolDescriptor] { toolsByServer[id] ?? [] }

    /// Every tool the server offers, including the ones switched off.
    public func discoveredTools(id: String) -> [ToolDescriptor] { discoveredByServer[id] ?? [] }

    /// Re-publishes the tool surface from what the clients already hold. Never
    /// re-lists over the wire, so it is cheap enough to call after any mutation.
    public func refreshTools() async {
        let collected = await collect()
        if allTools != collected.flat { allTools = collected.flat }
        if toolsByServer != collected.byServer { toolsByServer = collected.byServer }
        if discoveredByServer != collected.discovered { discoveredByServer = collected.discovered }
    }

    // MARK: Internals

    private struct Route {
        var serverID: String
        var serverName: String
        var tool: String
    }

    /// The tools this server is allowed to contribute.
    ///
    /// One function, read by both the descriptor pass and by routing, so what the
    /// model is offered and what it can call are the same list by construction.
    /// A tool hidden from the request that still answered a call would be the
    /// same disagreement as the one that made every MCP tool uncallable.
    private func servedTools(for config: MCPServerConfig, from cached: [MCPTool]) -> [MCPTool] {
        guard let enabled = config.enabledTools else { return cached }
        let wanted = Set(enabled)
        return cached.filter { wanted.contains($0.name) }
    }

    private struct Collected {
        var byServer: [String: [ToolDescriptor]] = [:]
        var flat: [ToolDescriptor] = []
        var discovered: [String: [ToolDescriptor]] = [:]
    }

    private func collect() async -> Collected {
        var byServer: [String: [ToolDescriptor]] = [:]
        var flat: [ToolDescriptor] = []
        var discovered: [String: [ToolDescriptor]] = [:]
        for config in servers {
            guard statuses[config.id]?.state == .ready else { continue }
            guard let client = clients[config.id], await client.isConnected else {
                // A client that died since the last pass must not keep advertising
                // tools the model can no longer call.
                await markFailed(config, reason: "The server closed the connection.")
                continue
            }
            let cached = await client.cachedTools
            discovered[config.id] = cached.map { descriptor(for: $0, config: config) }
            let served = servedTools(for: config, from: cached).map { descriptor(for: $0, config: config) }
            byServer[config.id] = served
            flat.append(contentsOf: served)
        }
        return Collected(byServer: byServer, flat: flat, discovered: discovered)
    }

    private func route(for name: String) async -> Route? {
        for config in servers {
            guard statuses[config.id]?.state == .ready, let client = clients[config.id] else { continue }
            for tool in servedTools(for: config, from: await client.cachedTools)
            where ToolNaming.namespaced(server: config.name, tool: tool.name) == name {
                return Route(serverID: config.id, serverName: config.name, tool: tool.name)
            }
        }
        return nil
    }

    public func withheldReason(for tool: String) async -> String? {
        guard let owner = await serverWithholding(tool) else { return nil }
        return "'\(tool)' is provided by '\(owner)' but is not switched on. "
            + "Enable it in Settings › MCP › \(owner) › Tools."
    }

    /// The server that has this tool and is not sending it.
    private func serverWithholding(_ name: String) async -> String? {
        for config in servers {
            guard statuses[config.id]?.state == .ready, let client = clients[config.id] else { continue }
            for tool in await client.cachedTools
            where ToolNaming.namespaced(server: config.name, tool: tool.name) == name {
                return config.sends(tool: tool.name) ? nil : config.name
            }
        }
        return nil
    }

    private func descriptor(for tool: MCPTool, config: MCPServerConfig) -> ToolDescriptor {
        ToolDescriptor(
            name: ToolNaming.namespaced(server: config.name, tool: tool.name),
            description: tool.description.isEmpty
                ? "\(tool.name), provided by the \(config.name) MCP server."
                : tool.description,
            schema: tool.inputSchema,
            providerID: providerID,
            providerName: config.name
        )
    }

    private func markFailed(_ config: MCPServerConfig, reason: String) async {
        guard let client = clients[config.id] else { return }
        let tail = Self.clipped(await client.diagnostics)
        let message = tail.isEmpty ? reason : "\(reason)\n\(tail)"
        let status = MCPServerStatus(
            id: config.id, name: config.name, transport: config.transport,
            state: .failed, error: message
        )
        if statuses[config.id] != status { statuses[config.id] = status }
        appendLog(config.id, "Connection lost — \(reason)")
        await stopClient(id: config.id)
    }

    /// Stops and forgets a client, awaiting its process's death so a replacement
    /// can be spawned immediately afterwards. Also invalidates any connect still
    /// in flight, so a handshake that finishes after Stop cannot resurrect the
    /// server or leave its process running untracked.
    private func stopClient(id: String) async {
        invalidateConnect(id)
        guard let client = clients.removeValue(forKey: id) else { return }
        let wasConnected = await client.isConnected
        let diagnostics = await client.diagnostics
        await client.stop()
        // Only a server that was healthy until now has new output worth showing;
        // a failed connect has already been quoted in its status.
        if wasConnected, !diagnostics.isEmpty {
            appendLog(id, "Server output:")
            appendLogTail(id, diagnostics)
        }
    }

    private func invalidateConnect(_ id: String) {
        connectTokens[id, default: 0] += 1
    }

    private func claimConnect(_ id: String) -> Int {
        let token = (connectTokens[id] ?? 0) + 1
        connectTokens[id] = token
        return token
    }

    private func isCurrentConnect(_ id: String, _ token: Int) -> Bool {
        connectTokens[id] == token
    }

    // MARK: Persistence

    /// Reads `~/.bud/mcp.json`, seeding an empty file on first run. A file that
    /// exists but does not parse is left untouched: silently rewriting it would
    /// discard every server the user configured over a single typo.
    private static func readStored() -> [MCPServerConfig] {
        let url = BudConfigLoader.mcpURL
        guard let data = try? Data(contentsOf: url) else {
            writeStored([])
            return []
        }
        return (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
    }

    private static func writeStored(_ servers: [MCPServerConfig]) {
        BudConfigLoader.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers) else { return }
        let url = BudConfigLoader.mcpURL
        try? data.write(to: url, options: [.atomic])
        // Server entries carry API keys in `env` and `headers`, so the file is
        // owner-only for the same reason `config.json` is.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func persist() { Self.writeStored(servers) }

    private func appendLog(_ id: String, _ message: String) {
        appendLogLines(id, [message])
    }

    private func appendLogTail(_ id: String, _ text: String) {
        appendLogLines(id, text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    private func appendLogLines(_ id: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        var buffer = logBuffers[id] ?? []
        buffer.append(contentsOf: lines.map { "[\(stamp)] \($0)" })
        if buffer.count > Self.logLimit {
            buffer.removeFirst(buffer.count - Self.logLimit)
        }
        logBuffers[id] = buffer
    }

    // MARK: Formatting

    private static func stoppedStatus(_ config: MCPServerConfig) -> MCPServerStatus {
        MCPServerStatus(
            id: config.id, name: config.name, transport: config.transport, state: .stopped
        )
    }

    private static func failureMessage(error: any Error, diagnostics: String) -> String {
        let base = MCPError.wrap(error).errorDescription ?? String(describing: error)
        let tail = clipped(diagnostics)
        // The server's own stderr is usually the only thing that explains a failed
        // handshake, so it is quoted rather than summarised.
        return tail.isEmpty ? base : "\(base)\n\(tail)"
    }

    private static func clipped(_ text: String, limit: Int = 1200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    private static func toolCount(_ count: Int) -> String {
        count == 1 ? "1 tool" : "\(count) tools"
    }

    private static func firstLine(_ text: String) -> String {
        let line = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
