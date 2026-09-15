import Darwin
import Foundation

// MARK: - Transport

/// One JSON-RPC conversation with a server, however it is carried.
///
/// Transports own the byte-level concerns — framing, process lifetime, HTTP
/// sessions — and hand the client complete JSON lines. Nothing above this layer
/// has to know whether the server is a child process or a URL.
public protocol MCPTransport: AnyObject, Sendable {
    /// Brings the transport up. Throwing here means the server was never
    /// reachable, so no cleanup beyond `stop()` is implied.
    func start() async throws
    /// Tears the transport down and finishes the inbound stream. Must be safe to
    /// call after a failure and safe to call twice.
    func stop() async
    /// Writes one framed JSON-RPC message.
    func send(_ line: String) async throws
    /// Inbound JSON lines, in arrival order. The stream finishes when the
    /// transport dies so a reader loop always terminates instead of hanging on a
    /// dead process. Single consumer.
    var lines: AsyncStream<String> { get }
    /// The server's own diagnostic output — stderr for a stdio process, the last
    /// transport failure for HTTP. A failed handshake is almost never explained
    /// by the JSON-RPC reply alone, so this is quoted verbatim in the UI rather
    /// than summarised.
    func diagnostics() async -> String
}

// MARK: - Construction

public enum MCPTransportFactory {
    public static func make(for config: MCPServerConfig) throws -> any MCPTransport {
        if let problem = problem(with: config) {
            switch config.transport {
            case .stdio: throw MCPError.processSpawnFailed(problem)
            case .http, .sse: throw MCPError.http(0, problem)
            }
        }
        switch config.transport {
        case .stdio:
            return StdioTransport(
                command: (config.command ?? "").trimmingCharacters(in: .whitespaces),
                args: config.args,
                env: config.env
            )
        case .http, .sse:
            // The spec replaced HTTP+SSE with streamable HTTP; both kinds are the
            // same POST-based protocol, so one implementation serves them.
            return HTTPTransport(
                url: URL(string: (config.url ?? "").trimmingCharacters(in: .whitespaces))
                    ?? URL(fileURLWithPath: "/"),
                headers: config.headers
            )
        }
    }

    /// Human-readable reason a config cannot be dialled, or `nil` if it looks
    /// usable. Exposed separately so the manager can report the problem without
    /// routing a throw through its error formatter.
    public static func problem(with config: MCPServerConfig) -> String? {
        switch config.transport {
        case .stdio:
            let command = (config.command ?? "").trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? "No command configured." : nil
        case .http, .sse:
            let raw = (config.url ?? "").trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), url.host() != nil else {
                return "No valid http(s) URL configured."
            }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return "The URL must use http or https."
            }
            return nil
        }
    }
}

// MARK: - Executable lookup

/// `Process` does not search `PATH`, and an app launched from Finder inherits a
/// minimal environment, so a config that says `npx` would otherwise resolve to
/// nothing at all. The same widened search path is handed to the child, because
/// `npx` shelling out to `node` fails for exactly the same reason and reports it
/// as an opaque exit code.
enum ExecutableLookup {
    static let fallbackDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
            "\(home)/.volta/bin", "\(home)/.cargo/bin",
        ]
    }()

    static func searchPath(_ environment: [String: String]) -> [String] {
        let inherited = (environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set(inherited)
        var directories = inherited
        for directory in fallbackDirectories where !seen.contains(directory) {
            seen.insert(directory)
            directories.append(directory)
        }
        return directories
    }

    /// Absolute path to `command`, or `nil` when nothing executable by that name
    /// exists.
    static func resolve(_ command: String, environment: [String: String]) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for directory in searchPath(environment) {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Scoped locking

/// `NSLock.lock()` is unavailable from async contexts, so every critical section
/// in this file goes through one synchronous scope. The rule that keeps it sound:
/// the closure never suspends — no `await`, no continuation, no I/O that could
/// block on another task.
private func locked<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
}

// MARK: - stdio

/// A child process speaking newline-delimited JSON-RPC on stdin/stdout.
///
/// `@unchecked Sendable` is sound because every mutable field is reachable only
/// under `lock` and the two `let`s are immutable and thread-safe.
public final class StdioTransport: @unchecked Sendable, MCPTransport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var exitNote: String?
    private var stdoutEnded = false
    private var closed = false

    private static let stderrLimit = 8 * 1024
    private static let stdoutLimit = 8 * 1024 * 1024

    /// Writing to a dead child's stdin raises `SIGPIPE`, whose default action
    /// terminates *this* process. Bud talks to servers it does not control, so
    /// the signal is neutralised once, process-wide, before any write.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.arguments = args
        self.environment = env
        let made = AsyncStream<String>.makeStream(of: String.self)
        self.lines = made.stream
        self.continuation = made.continuation
    }

    public func start() async throws {
        _ = Self.ignoreSIGPIPE
        guard let executable = ExecutableLookup.resolve(command, environment: environment) else {
            throw MCPError.processSpawnFailed(
                "'\(command)' was not found on PATH. Install it or give an absolute path."
            )
        }

        var childEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { childEnvironment[key] = value }
        childEnvironment["PATH"] = ExecutableLookup.searchPath(childEnvironment).joined(separator: ":")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = childEnvironment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(finished)
        }

        do {
            try process.run()
        } catch {
            throw MCPError.processSpawnFailed("\(executable): \(error.localizedDescription)")
        }

        locked(lock) { self.process = process }

        startReading(handle: stdoutPipe.fileHandleForReading, isStdout: true)
        startReading(handle: stderrPipe.fileHandleForReading, isStdout: false)
    }

    public func stop() async {
        let running = locked(lock) { () -> Process? in
            let running = process
            process = nil
            return running
        }

        if let running, running.isRunning {
            // Closing stdin is the protocol's own shutdown signal: a stdio server
            // is required to exit when its input ends, and that death is cleaner
            // than a signal because the server gets to flush on the way out.
            if let pipe = running.standardInput as? Pipe {
                try? pipe.fileHandleForWriting.close()
            }
            running.terminate()
            await awaitRelease(running, seconds: 2)
            if running.isRunning || !locked(lock, { stdoutEnded }) {
                // Escalate. Only the direct child is signalled, which is enough
                // because a wrapper such as `npx` obeys the stdin EOF above — and
                // the wait below observes the *pipe*, so it does not return until
                // every process holding it, child or grandchild, has let go.
                kill(running.processIdentifier, SIGKILL)
                await awaitRelease(running, seconds: 1.5)
            }
        }
        markClosed()
    }

    /// Waits until the process has exited *and* released the stdout pipe. Waiting
    /// on the pipe is what makes the check meaningful for a wrapper: `npx` dying
    /// says nothing about the `node` it started, but the pipe only reaches EOF
    /// once every process holding it is gone.
    private func awaitRelease(_ running: Process, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if locked(lock, { stdoutEnded }) && !running.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public func send(_ line: String) async throws {
        let data = Data((line + "\n").utf8)
        // Liveness and the write share one critical section so two concurrent
        // sends cannot interleave halves of two messages into the child's stdin.
        try locked(lock) {
            guard let process, process.isRunning else { throw MCPError.transportClosed }
            guard let pipe = process.standardInput as? Pipe else { throw MCPError.notConnected }
            do {
                try pipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw MCPError.transportClosed
            }
        }
    }

    public func diagnostics() async -> String {
        locked(lock) {
            var parts: [String] = []
            if let exitNote { parts.append(exitNote) }
            let stderr = String(decoding: stderrBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty { parts.append(stderr) }
            return parts.joined(separator: "\n")
        }
    }

    // MARK: Reading

    /// A blocking read loop on its own thread. `readabilityHandler` would be
    /// lighter, but EOF has to be seen by the same thread that reads: with
    /// handlers, process death and the final chunk of output race, and "the
    /// server printed why it refused to start, then exited" is precisely the
    /// case where losing that chunk costs the user the only real explanation.
    private func startReading(handle: FileHandle, isStdout: Bool) {
        Thread.detachNewThread { [weak self] in
            while let chunk = Self.readChunk(handle) {
                guard let self else { return }
                if isStdout { self.ingestStdout(chunk) } else { self.appendStderr(chunk) }
            }
            try? handle.close()
            guard let self else { return }
            guard isStdout else { return }
            self.markStdoutEnded()
            self.finishStdout()
        }
    }

    /// Reads whatever the pipe holds right now. `FileHandle.read(upToCount:)` is
    /// not usable here: it only returns once its entire count is satisfied, so a
    /// server answering in smaller pieces looks silent until the moment it exits.
    /// The POSIX read returns as soon as any bytes are available. `nil` is EOF.
    private static func readChunk(_ handle: FileHandle) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    private func ingestStdout(_ chunk: Data) {
        // A JSON object can be split across reads and several can share one read,
        // so framing happens on the buffer, never on a chunk.
        let complete = locked(lock) { () -> [String] in
            stdoutBuffer.append(chunk)
            var complete: [String] = []
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
                if let text = Self.decode(line) { complete.append(text) }
            }
            // A server that never emits a newline must not grow the buffer forever.
            if stdoutBuffer.count > Self.stdoutLimit { stdoutBuffer.removeAll() }
            return complete
        }
        for text in complete { continuation.yield(text) }
    }

    private func appendStderr(_ chunk: Data) {
        locked(lock) {
            stderrBuffer.append(chunk)
            if stderrBuffer.count > Self.stderrLimit {
                stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrLimit)
                // Dropping bytes rather than lines would leave a garbled first line
                // in the diagnostic, which is the one line a reader trusts.
                if let newline = stderrBuffer.firstIndex(of: 0x0A) {
                    stderrBuffer.removeSubrange(stderrBuffer.startIndex...newline)
                }
            }
        }
    }

    private func finishStdout() {
        let trailing = locked(lock) { () -> String? in
            defer { stdoutBuffer.removeAll() }
            return stdoutBuffer.isEmpty ? nil : Self.decode(stdoutBuffer)
        }
        if let trailing { continuation.yield(trailing) }
        markClosed()
    }

    private func markClosed() {
        let wasClosed = locked(lock) { () -> Bool in
            let wasClosed = closed
            closed = true
            return wasClosed
        }
        guard !wasClosed else { return }
        continuation.finish()
    }

    private func markStdoutEnded() {
        locked(lock) { stdoutEnded = true }
    }

    private func handleTermination(_ finished: Process) {
        let note = finished.terminationReason == .uncaughtSignal
            ? "The server was killed by signal \(finished.terminationStatus)."
            : "The server exited with status \(finished.terminationStatus)."
        locked(lock) {
            if process === finished { process = nil }
            if exitNote == nil { exitNote = note }
        }
        // Give the stdout reader a moment to drain what the pipe still holds
        // before closing the stream: a server that refuses to start prints why
        // and exits immediately, and that last write is the only useful
        // diagnostic in the whole exchange.
        var waited = 0.0
        while waited < 1.0 {
            if locked(lock, { stdoutEnded }) { break }
            usleep(20_000)
            waited += 0.02
        }
        markClosed()
    }

    private static func decode(_ data: Data) -> String? {
        // Lossy UTF-8 on purpose: one bad byte must not discard an otherwise
        // readable message.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

// MARK: - HTTP

/// Streamable HTTP: every message is a POST, and the reply comes back either as
/// a plain JSON body or as an event stream whose `data:` lines are messages.
public final class HTTPTransport: @unchecked Sendable, MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let timeout: TimeInterval

    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var lastFailure = ""

    /// Ceiling on a single JSON body. A tool result that large is a server bug,
    /// and holding it would cost more than the answer is worth.
    private static let bodyLimit = 16 * 1024 * 1024

    public init(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 120) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        // Long enough for a slow tool call, short enough that a wedged server
        // surfaces as an error the model can read rather than a frozen panel.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = ["User-Agent": "Bud/1.0 (MCP)"]
        self.session = URLSession(configuration: configuration)
        let made = AsyncStream<String>.makeStream(of: String.self)
        self.lines = made.stream
        self.continuation = made.continuation
    }

    /// Nothing to dial: streamable HTTP is request/response, and the session is
    /// kept alive between calls by `URLSession` itself.
    public func start() async throws {}

    public func stop() async {
        session.invalidateAndCancel()
        continuation.finish()
    }

    public func send(_ line: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = Data((line + "\n").utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let opened: (bytes: URLSession.AsyncBytes, response: URLResponse)
        do {
            opened = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw MCPError.transportClosed
        } catch {
            record(lastFailure: error.localizedDescription)
            throw MCPError.http(0, error.localizedDescription)
        }
        guard let http = opened.response as? HTTPURLResponse else {
            throw MCPError.http(0, "The server did not answer with HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = await Self.collect(opened.bytes, limit: 8 * 1024)
            record(lastFailure: "HTTP \(http.statusCode)")
            throw MCPError.http(
                http.statusCode,
                body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : body
            )
        }
        let isEventStream = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
            .contains("text/event-stream")
        if isEventStream {
            try await absorbEventStream(opened.bytes)
        } else {
            try await absorbDocument(opened.bytes)
        }
    }

    public func diagnostics() async -> String {
        locked(lock) { lastFailure }
    }

    private func absorbEventStream(_ bytes: URLSession.AsyncBytes) async throws {
        var emitted = 0
        do {
            for try await raw in bytes.lines {
                guard let payload = Self.eventStreamPayload(raw) else { continue }
                guard payload.hasPrefix("{") || payload.hasPrefix("[") else { continue }
                continuation.yield(payload)
                emitted += 1
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            record(lastFailure: error.localizedDescription)
            // A stream that dies after delivering its message is the server's
            // prerogative — a response is a complete message, so only silence is
            // a failure of the call itself.
            guard emitted == 0 else { return }
            throw MCPError.http(0, error.localizedDescription)
        }
    }

    /// A plain `application/json` body is a *document*, not a line stream: a
    /// server may pretty-print it, and splitting that on newlines would shred one
    /// reply into fragments that no longer parse. The body is taken whole, and
    /// only split when it really is several newline-delimited messages.
    private func absorbDocument(_ bytes: URLSession.AsyncBytes) async throws {
        let body: String
        do {
            body = try await Self.readAll(bytes, limit: Self.bodyLimit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            record(lastFailure: error.localizedDescription)
            throw MCPError.http(0, error.localizedDescription)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if JSONValue(parsing: trimmed) != nil {
            continuation.yield(trimmed)
            return
        }
        for line in trimmed.split(separator: "\n") {
            let payload = line.trimmingCharacters(in: .whitespaces)
            guard payload.hasPrefix("{") || payload.hasPrefix("[") else { continue }
            if JSONValue(parsing: payload) != nil { continuation.yield(payload) }
        }
    }

    /// The JSON payload of one SSE record line, or `nil` for a line that is
    /// framing rather than data: real streams interleave comments, `event:`
    /// names, `id:` and blank separators between messages.
    static func eventStreamPayload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    private static func readAll(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func record(lastFailure message: String) {
        locked(lock) { lastFailure = message }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async -> String {
        let text = (try? await readAll(bytes, limit: limit)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
