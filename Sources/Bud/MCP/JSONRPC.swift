import Foundation

// MARK: - Envelopes

/// A JSON-RPC 2.0 request. `id == nil` produces a notification, which the spec
/// forbids answering — the transports rely on that distinction to know whether a
/// reply will ever come, so it is expressed in the type rather than a flag.
public struct JSONRPCRequest: Sendable, Hashable, Codable {
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONValue? = nil, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return .object(object)
    }
}

extension JSONRPCRequest {
    public init(from decoder: Decoder) throws {
        self.init(json: try decoder.singleValueContainer().decode(JSONValue.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }

    public init(json: JSONValue) {
        self.init(
            id: json["id"],
            method: json["method"]?.stringValue ?? "",
            params: json["params"]
        )
    }
}

public struct JSONRPCError: Sendable, Hashable, Codable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Servers send `code` as a string about as often as a number, and some omit
    /// `message` entirely; a missing field degrades to the standard internal
    /// error code rather than discarding the whole reply.
    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        let code = object["code"]?.doubleValue.map { Int($0) } ?? -32603
        var message = object["message"]?.stringValue ?? ""
        if message.isEmpty, let data = object["data"]?.stringValue { message = data }
        self.init(code: code, message: message, data: object["data"])
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }

    public var mcpError: MCPError { .protocolError(code: code, message: message) }
}

extension JSONRPCError {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(JSONValue.self)
        guard let error = JSONRPCError(json: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not a JSON-RPC error object"
            )
        }
        self = error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }
}

/// A JSON-RPC 2.0 response. Lenient on decode: a server that answers with
/// `id: null` or omits both `result` and `error` must not stall the reader, and
/// the correlation layer turns anything unusable into a protocol error.
public struct JSONRPCResponse: Sendable, Hashable, Codable {
    public var id: JSONValue
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(id: JSONValue, result: JSONValue? = nil, error: JSONRPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    public init(json: JSONValue) {
        self.init(
            id: json["id"] ?? .null,
            result: json["result"],
            error: json["error"].flatMap(JSONRPCError.init(json:))
        )
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": id]
        if let result { object["result"] = result }
        if let error { object["error"] = error.json }
        return .object(object)
    }
}

extension JSONRPCResponse {
    public init(from decoder: Decoder) throws {
        self.init(json: try decoder.singleValueContainer().decode(JSONValue.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }
}

/// What an inbound frame turned out to be. Dispatch on the frame itself rather
/// than decoding into one shape and guessing, because a request, a notification
/// and a response differ only by which keys are present.
public enum JSONRPCInbound: Sendable, Hashable {
    case response(JSONRPCResponse)
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)

    public init(json: JSONValue) {
        if let method = json["method"]?.stringValue {
            let params = json["params"]
            if let id = json["id"], !id.isNull {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
        } else {
            self = .response(JSONRPCResponse(json: json))
        }
    }
}

// MARK: - Correlation

/// Matches replies to the requests that asked for them.
///
/// Three details make this more than a dictionary of continuations:
///
/// 1. **Reserve before send.** `next()` opens the slot for an id *before* the
///    frame is written, so a server that answers faster than the caller suspends
///    cannot race its reply past the waiter and hang the request forever.
/// 2. **A slot outlives its waiter.** A reply that lands while nobody is
///    suspended is held as `.settled` and handed over on the next `awaitResult`.
/// 3. **Death is terminal.** `failAll` resumes everything outstanding and
///    refuses further ids, so a crashed server produces immediate errors instead
///    of requests that never return.
public actor JSONRPCCorrelation {
    private enum Slot: Sendable {
        case open
        case waiting(CheckedContinuation<JSONValue, any Error>)
        case settled(Result<JSONValue, MCPError>)
    }

    private var slots: [Int: Slot] = [:]
    private var nextID: Int
    private var terminal: MCPError?

    public init(startingID: Int = 1) {
        self.nextID = startingID
    }

    public var pendingCount: Int { slots.count }

    /// Allocates the next id and opens its slot. Throws once the transport has
    /// been declared dead.
    public func next() throws -> Int {
        if let terminal { throw terminal }
        let id = nextID
        nextID += 1
        slots[id] = .open
        return id
    }

    /// Waits for the reply to `id`, giving up after `timeout`.
    public func awaitResult(id: Int, timeout: TimeInterval) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.wait(id: id) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                // The deadline has to go through the actor: a waiter suspended on
                // a continuation is not cancellable, so leaving it un-resumed
                // would deadlock the group at scope exit.
                await self.expire(id: id)
                throw MCPError.timeout
            }
            do {
                guard let value = try await group.next() else { throw MCPError.notConnected }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                expire(id: id)
                throw error
            }
        }
    }

    public func resolve(id: JSONValue, result: JSONValue) {
        settle(id: id, with: .success(result))
    }

    public func fail(id: JSONValue, error: MCPError) {
        settle(id: id, with: .failure(error))
    }

    /// Resumes every outstanding request and marks the correlator terminal.
    /// Called when the transport dies or is stopped.
    public func failAll(error: MCPError) {
        terminal = error
        let outstanding = slots
        slots.removeAll()
        for slot in outstanding.values {
            if case .waiting(let continuation) = slot {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Drops a slot without answering it — the caller has already given up.
    public func expire(id: Int) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        if case .waiting(let continuation) = slot {
            continuation.resume(throwing: MCPError.timeout)
        }
    }

    private func settle(id: JSONValue, with result: Result<JSONValue, MCPError>) {
        guard let key = id.stringValue.flatMap(Int.init), let slot = slots[key] else { return }
        switch slot {
        case .waiting(let continuation):
            slots[key] = nil
            continuation.resume(with: result)
        case .open:
            slots[key] = .settled(result)
        case .settled:
            break
        }
    }

    private func wait(id: Int) async throws -> JSONValue {
        guard let slot = slots[id] else { throw MCPError.notConnected }
        switch slot {
        case .settled(let result):
            slots[id] = nil
            return try result.get()
        case .waiting:
            slots[id] = nil
            throw MCPError.protocolError(
                code: -32603,
                message: "Two waiters registered for request \(id)"
            )
        case .open:
            return try await withCheckedThrowingContinuation { continuation in
                slots[id] = .waiting(continuation)
            }
        }
    }
}
