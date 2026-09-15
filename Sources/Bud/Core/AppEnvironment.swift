import Foundation

/// Shared, concurrency-safe runtime state: the live config and the tool registry.
///
/// This is deliberately **not** `@MainActor`. Subagents and MCP servers run off
/// the main actor and need the current config synchronously — making them hop to
/// the main actor to read a model name would serialise exactly the parallelism
/// subagents exist to provide. Mutation is guarded by a lock instead; the UI-side
/// observable copy lives in `AppModel`, which is the single writer.
public final class AppEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: BudConfig
    private var _promptTokens = 0
    private var _completionTokens = 0

    public let registry = ToolRegistry()

    public init(config: BudConfig) {
        self._config = config
    }

    public var config: BudConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    public var model: String { config.model }

    /// Builds a backend from the *current* config. Callers get a fresh client per
    /// turn so a mid-session model change takes effect on the next request.
    public func makeBackend() -> any ChatBackend {
        DeepSeekClient(config: config)
    }

    // MARK: Usage accounting

    public var usage: (prompt: Int, completion: Int) {
        lock.withLock { (_promptTokens, _completionTokens) }
    }

    public func recordUsage(prompt: Int, completion: Int) {
        lock.withLock {
            _promptTokens += prompt
            _completionTokens += completion
        }
    }

    public func resetUsage() {
        lock.withLock {
            _promptTokens = 0
            _completionTokens = 0
        }
    }
}
