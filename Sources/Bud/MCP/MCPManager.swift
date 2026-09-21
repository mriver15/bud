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

    /// Bumped whenever `toolDescriptors()` would return a different surface — a
    /// server connecting, disconnecting, or a tool being switched off — so the
    /// registry's descriptor cache knows to re-walk this provider. Kept out of
    /// observation: it moves exactly when `allTools` does, and nothing renders
    /// from it.
    @ObservationIgnored public private(set) var descriptorRevision = 0

    /// Asked before an external mutation, and answered by whatever is holding the
    /// panel. `nil` means there is nobody to ask — the measurement CLIs, and
    /// checks that are exercising the tool rather than the gate — and the tool
    /// runs.
    /// The shared execution gate (Phase 7): MCP mutations ask through the same
    /// harness as native tools, so there is one policy surface rather than two
    /// closures kept in step by hand.
    public var harness: ExecutionHarness?

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
    /// Server ids whose "hand this to an agent" hint the user dismissed this
    /// session. Not persisted: it is a nag-reducer, not a preference, and a hint
    /// that has been acted on disappears anyway because `delegated` is set. The
    /// manager holds it rather than the view so the dismissal survives switching
    /// panes — the row is rebuilt on every tab change, and view-local state would
    /// re-suggest the same server the moment the user came back.
    private var dismissedDelegationHints: Set<String> = []

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
            // The cognitive graph learns the server the moment it is added:
            // later queries that name it walk to everything it connects to.
            CognitiveStore.recordServerConnection(name: config.name, tools: tools.map(\.name))
            let version = (info?.version).flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
            appendLog(id, "Connected to \(info?.name ?? config.name)\(version) — \(Self.toolCount(tools.count)).")
        } catch {
            let diagnostics = await client.diagnostics
            await client.stop()
            guard isCurrentConnect(id, token) else { return }
            let message = config.redacting(Self.failureMessage(error: error, diagnostics: diagnostics))
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
        // The surface just emptied without a `refreshTools` pass; tell the
        // registry's cache so a late descriptors read cannot serve dead tools.
        descriptorRevision &+= 1
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
        if let refusal = await refusalUnlessConfirmed(route: route, arguments: arguments) {
            return refusal
        }
        do {
            let full = try await client.callToolFull(name: route.tool, arguments: arguments)
            var result = ToolResult(
                text: full.renderedText,
                ui: MCPClient.surface(for: full.content, titled: route.tool),
                isError: full.isError
            )
            if let attachment = await appAttachment(route: route, client: client, arguments: arguments, full: full) {
                result.apps = [attachment]
            }
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

    /// The app to render for a model call, when the tool declared one, the server
    /// negotiated the extension, and the resource passes validation. A failure at
    /// any point is nil — the text result still answers the call.
    private func appAttachment(
        route: Route,
        client: MCPClient,
        arguments: JSONValue,
        full: MCPCallResult
    ) async -> MCPAppAttachment? {
        guard await client.supportsApps() else { return nil }
        let tool = (await client.cachedTools).first { $0.name == route.tool }
        guard let uri = tool?.ui?.resourceUri else { return nil }
        do {
            let content = try await client.readResource(uri: uri)
            let resource = try MCPAppLoader.validate(content)
            return MCPAppAttachment(
                serverID: route.serverID,
                generation: await client.connectionGeneration,
                resourceURI: uri,
                toolName: route.tool,
                arguments: arguments,
                result: MCPAppLoader.boundedResult(full),
                isError: full.isError,
                contentHash: resource.contentHash
            )
        } catch {
            appendLog(route.serverID, "✗ \(route.tool) app: \(MCPError.wrap(error).errorDescription ?? "invalid")")
            return nil
        }
    }

    // MARK: Apps

    /// Resolves a persisted app reference back into renderable content, or the
    /// reason it cannot be. This is the one gate a stored conversation passes
    /// through on its way to a rendered view.
    public func renderableApp(_ ref: MCPAppAttachment) async -> Result<MCPAppResource, MCPAppError> {
        guard statuses[ref.serverID]?.state == .ready, let client = clients[ref.serverID] else {
            return .failure(.serverMissing)
        }
        guard await client.connectionGeneration == ref.generation else {
            return .failure(.generationMismatch)
        }
        guard await client.supportsApps() else { return .failure(.notNegotiated) }
        do {
            let content = try await client.readResource(uri: ref.resourceURI)
            return .success(try MCPAppLoader.validate(content))
        } catch let error as MCPAppError {
            return .failure(error)
        } catch {
            return .failure(.serverMissing)
        }
    }

    /// The app-initiated `tools/call` route: a tool, named and scoped to one
    /// server, on the connection the app was created on. No global tool-name
    /// lookup, so web content can never name another server's tool and have it
    /// routed.
    ///
    /// The answer is always a spec-shaped `CallToolResult` — a refusal or
    /// failure is `isError: true` with a text block, never a JSON-RPC error —
    /// because the app's SDK turns a JSON-RPC error into a promise rejection the
    /// app may not catch, and a hang reads worse than an error it can show.
    public func serveAppToolCall(
        serverID: String,
        params: JSONValue,
        generation: Int
    ) async -> JSONValue {
        guard let config = servers.first(where: { $0.id == serverID }) else {
            return Self.toolError("No MCP server with that id is configured.")
        }
        guard statuses[config.id]?.state == .ready, let client = clients[config.id] else {
            return Self.toolError("MCP server '\(config.name)' is not connected. Reconnect it in Settings.")
        }
        guard await client.connectionGeneration == generation else {
            return Self.toolError("The app's connection has been replaced. Reload it.")
        }
        guard await client.supportsApps() else {
            return Self.toolError("The server does not support MCP Apps.")
        }
        guard let tool = params["name"]?.stringValue else {
            return Self.toolError("tools/call needs a 'name'.")
        }
        let arguments = params["arguments"].flatMap { $0.objectValue != nil ? $0 : nil } ?? .object([:])
        guard let mcpTool = (await client.cachedTools).first(where: { $0.name == tool }) else {
            return Self.toolError("'\(tool)' is not a tool of '\(config.name)'.")
        }
        guard mcpTool.ui?.isAppCallable ?? false else {
            return Self.toolError("'\(tool)' is not callable by the app.")
        }
        let route = Route(serverID: config.id, serverName: config.name, tool: tool)
        if let refusal = await refusalUnlessConfirmed(route: route, arguments: arguments) {
            return Self.toolError(refusal.text.isEmpty ? "The tool call was refused." : refusal.text)
        }
        do {
            let full = try await client.callToolFull(name: tool, arguments: arguments)
            return MCPAppLoader.boundedResult(full)
        } catch {
            return Self.toolError("MCP tool '\(tool)' failed: \(MCPError.wrap(error).errorDescription ?? "unknown error")")
        }
    }

    /// A `CallToolResult` whose `isError` carries a message, so the app's SDK
    /// resolves the promise and its result handler renders the text.
    private static func toolError(_ message: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    /// Asks before an external mutation, when there is anyone to ask, the server
    /// has asked to be asked, and the tool's un-namespaced name looks like it
    /// changes something. Returns a refusal to hand back to the model, or `nil`
    /// to carry on.
    private func refusalUnlessConfirmed(route: Route, arguments: JSONValue) async -> ToolResult? {
        guard let harness else { return nil }
        guard let config = servers.first(where: { $0.id == route.serverID }),
              config.confirmMutations,
              ToolConfirmation.looksLikeMutation(route.tool)
        else { return nil }

        let request = ToolConfirmation.externalMutation(
            server: config.name,
            action: route.tool,
            tool: ToolNaming.namespaced(server: config.name, tool: route.tool),
            arguments: arguments
        )
        if case .deny = await harness.resolve(request) {
            return NativeToolsProvider.refusal(for: request)
        }
        return nil
    }

    // MARK: Diagnostics

    /// Per-server ring buffer of connection events and captured server output,
    /// oldest first, capped at 200 lines.
    public func logs(id: String) -> [String] { logBuffers[id] ?? [] }

    public func clearLogs(id: String) { logBuffers[id] = [] }

    public func isDelegationHintDismissed(_ id: String) -> Bool {
        dismissedDelegationHints.contains(id)
    }

    public func dismissDelegationHint(_ id: String) {
        dismissedDelegationHints.insert(id)
    }

    /// Cached descriptors for one server. Synchronous so a view can call it while
    /// rendering; call `refreshTools()` when a fresh read is needed.
    public func serverTools(id: String) -> [ToolDescriptor] { toolsByServer[id] ?? [] }

    /// Every tool the server offers, including the ones switched off.
    public func discoveredTools(id: String) -> [ToolDescriptor] { discoveredByServer[id] ?? [] }

    /// Re-publishes the tool surface from what the clients already hold. Never
    /// re-lists over the wire, so it is cheap enough to call after any mutation.
    public func refreshTools() async {
        let collected = await collect()
        if allTools != collected.flat {
            allTools = collected.flat
            descriptorRevision &+= 1
        }
        if toolsByServer != collected.byServer { toolsByServer = collected.byServer }
        if discoveredByServer != collected.discovered { discoveredByServer = collected.discovered }
    }

    // MARK: Internals

    private struct Route {
        var serverID: String
        var serverName: String
        var tool: String
    }

    /// The tools this server is allowed to contribute *to the model*.
    ///
    /// One function, read by both the descriptor pass and by routing, so what the
    /// model is offered and what it can call are the same list by construction.
    /// A tool hidden from the request that still answered a call would be the
    /// same disagreement as the one that made every MCP tool uncallable.
    ///
    /// App-only tools — `visibility: ["app"]` — are dropped here, because they
    /// are not the model's to call. They stay in `discoveredByServer` and are
    /// reachable through the app route only, on the same connection.
    private func servedTools(for config: MCPServerConfig, from cached: [MCPTool]) -> [MCPTool] {
        let visible = cached.filter { $0.ui?.isModelVisible ?? true }
        guard let enabled = config.enabledTools else { return visible }
        let wanted = Set(enabled)
        return visible.filter { wanted.contains($0.name) }
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
            providerName: config.name,
            // Still served, and still callable — the registry routes by name, and
            // the agent that holds it reaches it through the same table. This only
            // says the *main* agent should not be carrying its schema.
            agentOnly: config.delegated
        )
    }

    private func markFailed(_ config: MCPServerConfig, reason: String) async {
        guard let client = clients[config.id] else { return }
        let tail = config.redacting(Self.clipped(await client.diagnostics))
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
        // Server entries carry API keys in `env` and `headers`, so the file is
        // owner-only for the same reason `config.json` is.
        try? BudConfigLoader.writeOwnerOnly(data, to: BudConfigLoader.mcpURL)
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
        // Server output is quoted here verbatim, and this buffer is what the Copy
        // button puts on the pasteboard. Servers print their own configuration at
        // startup, so the values this config declares are replaced before a line
        // is stored rather than on the way out, where only one of the readers
        // would be covered.
        let visible = servers.first { $0.id == id }.map { config in
            lines.map { config.redacting($0) }
        } ?? lines
        let stamp = Date().formatted(date: .omitted, time: .standard)
        var buffer = logBuffers[id] ?? []
        buffer.append(contentsOf: visible.map { "[\(stamp)] \($0)" })
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
