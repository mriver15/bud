import Foundation

/// The protocol half of an MCP connection: one transport, one correlation table,
/// one reader loop.
///
/// An actor rather than a class because replies arrive on the reader task while
/// callers are suspended on continuations — every path that touches connection
/// state has to be serialised against that.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"
    public static let clientName = "Bud"
    public static let clientVersion = "1.0"
    /// The MCP Apps extension. Negotiated in `initialize`, and the only gate in
    /// front of rendering a server's `ui://` resource.
    public static let appsExtension = "io.modelcontextprotocol/ui"
    /// Handshakes and listings are bounded so a wedged server cannot leave a
    /// server status stuck on "connecting" forever.
    public static let handshakeTimeout: TimeInterval = 30
    /// Tool calls legitimately take minutes — a browser-automation server
    /// crawling a site, a build server compiling — so they get the full budget.
    public static let callTimeout: TimeInterval = 120
    /// Page cap for cursor pagination: a server that repeats its cursor must not
    /// trap the handshake in a loop that never ends.
    private static let maxPages = 50

    private let config: MCPServerConfig
    private var transport: (any MCPTransport)?
    private var correlation = JSONRPCCorrelation()
    private var reader: Task<Void, Never>?
    /// Bumped on every connect *and* every stop. A reader that finishes after its
    /// session was replaced must not fail the next session's requests.
    private var session = 0
    private var handshake: MCPInitializeResult?
    private var live = false

    /// Tools from the last listing, refreshed when the server announces a change.
    /// The manager reads this instead of re-listing on every registry query.
    public private(set) var cachedTools: [MCPTool] = []
    /// The last thing the server said outside the protocol, captured on failure
    /// and on death, for the status detail in Settings.
    public private(set) var diagnostics = ""
    /// UI resources, keyed by URI. Small and bounded by the resources a server
    /// declares; invalidated when the server announces a list change and when
    /// the connection is replaced, so a view can never hold a template that a
    /// later list superseded.
    private var resourceCache: [String: JSONValue] = [:]

    public var isConnected: Bool { live }

    /// Which connection this is, bumped on every connect and stop. An App
    /// instance binds to this, so a rendered view from a connection that has
    /// since been torn down and re-established is refused rather than trusted.
    public var connectionGeneration: Int { session }

    public var serverInfo: (name: String, version: String)? {
        guard let handshake else { return nil }
        return (handshake.serverName, handshake.serverVersion)
    }

    public init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: Lifecycle

    /// Runs the full handshake: `initialize`, the `initialized` notification, and
    /// the first tool listing. Any failure leaves the client stopped — the caller
    /// gets a throw, never a half-open connection.
    public func connect() async throws {
        await stop()
        let transport = try MCPTransportFactory.make(for: config)
        session += 1
        let token = session
        correlation = JSONRPCCorrelation()
        self.transport = transport
        cachedTools = []
        resourceCache = [:]
        handshake = nil
        live = false

        do {
            try await transport.start()
            startReader(transport, token: token)
            let result = try await request(
                "initialize",
                params: .object([
                    "protocolVersion": .string(Self.protocolVersion),
                    "capabilities": .object([
                        // Advertised here so the server knows this host can
                        // render its apps, and read back from the server's own
                        // capabilities to decide whether to.
                        Self.appsExtension: .object([:]),
                    ]),
                    "clientInfo": .object([
                        "name": .string(Self.clientName),
                        "version": .string(Self.clientVersion),
                    ]),
                ]),
                timeout: Self.handshakeTimeout
            )
            let negotiated = MCPInitializeResult(json: result)
            handshake = negotiated
            await sendNotification("notifications/initialized")
            cachedTools = try await optionalList("tools/list", key: "tools", decode: MCPTool.init(json:))
            live = true
        } catch {
            diagnostics = await transport.diagnostics()
            await stop()
            throw error
        }
    }

    public func stop() async {
        session += 1
        reader?.cancel()
        reader = nil
        let transport = self.transport
        self.transport = nil
        live = false
        if let transport { await transport.stop() }
        await correlation.failAll(error: .transportClosed)
    }

    // MARK: Listings

    /// Re-lists tools and updates the cache. Throws only when the server is
    /// unreachable — a server without a `tools` capability answers `-32601`, which
    /// is a legitimate empty list.
    @discardableResult
    public func listTools() async throws -> [MCPTool] {
        cachedTools = try await optionalList("tools/list", key: "tools", decode: MCPTool.init(json:))
        return cachedTools
    }

    public func listResources() async throws -> [MCPResource] {
        guard supports("resources") else { return [] }
        return try await optionalList(
            "resources/list",
            key: "resources",
            decode: MCPResource.init(json:)
        )
    }

    public func listPrompts() async throws -> [MCPPrompt] {
        guard supports("prompts") else { return [] }
        return try await optionalList("prompts/list", key: "prompts", decode: MCPPrompt.init(json:))
    }

    /// Does the server advertise a capability? Absence is taken at face value:
    /// the spec requires servers to declare what they implement.
    private func supports(_ capability: String) -> Bool {
        handshake?.supports(capability) ?? false
    }

    // MARK: Calls

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        let full = try await callToolFull(name: name, arguments: arguments)
        return ToolResult(
            text: full.renderedText,
            ui: Self.surface(for: full.content, titled: name),
            isError: full.isError
        )
    }

    /// The complete result — content blocks, structured content and the raw
    /// object — for a caller that wants more than the flattened text. MCP Apps
    /// renders from this; the model-facing path above stays text-only.
    public func callToolFull(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        let result = try await request(
            "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments.objectValue != nil ? arguments : .object([:]),
            ]),
            timeout: Self.callTimeout
        )
        return MCPCallResult(
            content: (result["content"]?.arrayValue ?? []).map(MCPContent.init(json:)),
            structuredContent: result["structuredContent"],
            isError: result["isError"]?.boolValue ?? false,
            raw: result
        )
    }

    /// Reads one resource, for a known `ui://` URI. The server's answer is
    /// cached by URI and invalidated when the connection is replaced or the
    /// server announces a list change, so a template is fetched once and never
    /// assumed current across generations.
    ///
    /// A known URI does not require `resources/list` to have worked: apps are
    /// discovered through tool metadata, and a server may omit them from the
    /// listing on purpose.
    public func readResource(uri: String) async throws -> MCPResourceContent {
        if let cached = resourceCache[uri] {
            if let content = MCPResourceContent(json: cached) { return content }
            resourceCache.removeValue(forKey: uri)
        }
        let result = try await request(
            "resources/read",
            params: .object(["uri": .string(uri)]),
            timeout: Self.handshakeTimeout
        )
        resourceCache[uri] = result
        guard let content = MCPResourceContent(json: result) else {
            throw MCPError.protocolError(
                code: -32602, message: "resources/read returned no content for '\(uri)'"
            )
        }
        return content
    }

    /// Whether the server and this host negotiated the Apps extension.
    ///
    /// The spec names `io.modelcontextprotocol/ui`, and a compliant server
    /// declares it. Several real servers — including the one this host was first
    /// exercised against — declare `resources` and link tools to `ui://`
    /// resources through `_meta.ui` without the dedicated extension, which is the
    /// spec's own discovery mechanism. Both count as negotiated; the resource
    /// validation (scheme, MIME, byte bound, CSP) is the hard gate either way.
    public func supportsApps() -> Bool {
        if handshake?.supports(Self.appsExtension) == true { return true }
        return handshake?.supports("resources") == true
            && cachedTools.contains { $0.ui?.resourceUri != nil }
    }

    /// The pictures in a result, as something to draw.
    ///
    /// A server that answers with an image content block used to have its bytes
    /// thrown away — the model was told "[image image/png, 41234 bytes]" and the
    /// person watching saw nothing at all. The model still gets that line, because
    /// it cannot look at a picture; the bytes are written to Bud's own directory
    /// so the picture can be shown beside the call.
    ///
    /// This also means a tool does not need somewhere public to put an image. A
    /// server on the same machine can just return it.
    static func surface(for contents: [MCPContent], titled title: String) -> JSONValue? {
        let files = contents.compactMap { content -> String? in
            guard case .image(let image) = content,
                  let url = ImageAssets.store(base64: image.base64, mimeType: image.mimeType)
            else { return nil }
            return url.absoluteString
        }
        guard !files.isEmpty else { return nil }

        // Tiles rather than one full-width image each: an answer with several
        // pictures in it is almost always a set — a team, a gallery, a diff — and
        // six screenshots stacked down the transcript is not how anyone reads it.
        let tiles: [JSONValue] = files.map { url in
            .object([
                "type": .string("image"),
                "url": .string(url),
                "height": .number(180),
                "fit": .string("fit"),
            ])
        }
        let body: JSONValue = tiles.count == 1
            ? tiles[0]
            : .object([
                "type": .string("grid"),
                "columns": .number(Double(min(3, tiles.count))),
                "children": .array(tiles),
            ])
        return .object([
            "title": .string(title),
            "components": .array([body]),
        ])
    }

    // MARK: Request plumbing

    private func request(
        _ method: String,
        params: JSONValue?,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        guard let transport else { throw MCPError.notConnected }
        let correlation = self.correlation
        let id = try await correlation.next()
        let idValue = JSONValue.number(Double(id))
        let line = JSONRPCRequest(id: idValue, method: method, params: params).json.encodedString()

        // The reply can land before `send` returns — a streamable-HTTP server
        // holds its event stream open past the answer — so the two run
        // concurrently, and a send failure is reported by failing the pending
        // request rather than by throwing here.
        let sender = Task {
            do { try await transport.send(line) }
            catch { await correlation.fail(id: idValue, error: MCPError.wrap(error)) }
        }
        defer { sender.cancel() }
        return try await correlation.awaitResult(id: id, timeout: timeout)
    }

    /// Sends a message that has no reply. A server that answers with an open
    /// event stream would otherwise stall the handshake; the bytes are written
    /// either way, so the wait is bounded and then abandoned.
    private func sendNotification(_ method: String) async {
        guard let transport else { return }
        let line = JSONRPCRequest(method: method).json.encodedString()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await transport.send(line) }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func optionalList<T>(
        _ method: String,
        key: String,
        decode: (JSONValue) -> T?
    ) async throws -> [T] {
        do {
            return try await paginate(method, key: key, timeout: Self.handshakeTimeout)
                .compactMap(decode)
        } catch let error as MCPError {
            // "-32601 Method not found" is how a server without the capability
            // answers. An empty list is the truthful result; failing the whole
            // connection over it would be wrong.
            if case .protocolError(let code, _) = error, code == -32601 { return [] }
            throw error
        }
    }

    private func paginate(
        _ method: String,
        key: String,
        timeout: TimeInterval
    ) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request(
                method,
                params: params.isEmpty ? nil : .object(params),
                timeout: timeout
            )
            items.append(contentsOf: result[key]?.arrayValue ?? [])
            let next = result["nextCursor"]?.stringValue
            cursor = (next?.isEmpty ?? true) ? nil : next
            pages += 1
        } while cursor != nil && pages < Self.maxPages
        return items
    }

    // MARK: Reader

    private func startReader(_ transport: any MCPTransport, token: Int) {
        reader?.cancel()
        reader = Task { [weak self] in
            for await line in transport.lines {
                if Task.isCancelled { break }
                await self?.ingest(line, token: token)
            }
            await self?.handleTransportEnd(token: token)
        }
    }

    private func handleTransportEnd(token: Int) async {
        guard token == session else { return }
        if let transport { diagnostics = await transport.diagnostics() }
        live = false
        await correlation.failAll(error: .transportClosed)
    }

    private func ingest(_ line: String, token: Int) async {
        guard token == session, let value = JSONValue(parsing: line) else { return }
        switch JSONRPCInbound(json: value) {
        case .response(let response):
            if let error = response.error {
                await correlation.fail(id: response.id, error: error.mcpError)
            } else if let result = response.result {
                await correlation.resolve(id: response.id, result: result)
            } else {
                await correlation.fail(
                    id: response.id,
                    error: .protocolError(
                        code: -32603,
                        message: "Reply carried neither result nor error."
                    )
                )
            }
        case .request(let id, let method, _):
            // Servers probe capabilities a client never promised — `roots/list`,
            // `sampling/createMessage`. Answering "method not found" keeps such a
            // server moving instead of leaving it blocked on a reply that would
            // never arrive.
            let error = JSONRPCError(code: -32601, message: "Method not found: \(method)")
            let line = JSONRPCResponse(id: id, error: error).json.encodedString()
            if let transport { _ = try? await transport.send(line) }
        case .notification(let method, _):
            // The one notification that changes what Bud advertises.
            if method == "notifications/tools/list_changed" {
                _ = try? await listTools()
            }
            // A changed resource list can re-point a `ui://` URI at new HTML,
            // so the cache is dropped rather than trusted past the announcement.
            if method == "notifications/resources/list_changed" {
                resourceCache = [:]
            }
        }
    }
}
