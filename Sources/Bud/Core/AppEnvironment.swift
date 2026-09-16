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
    private var _conversationPrompt = 0
    private var _conversationCompletion = 0

    public let registry = ToolRegistry()

    public init(config: BudConfig) {
        self._config = config
    }

    public var config: BudConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    public var model: String { config.model }

    /// Builds a backend for the *current* provider. Callers get a fresh client per
    /// turn so a mid-session model or provider change takes effect on the next
    /// request without any further plumbing.
    public func makeBackend() -> any ChatBackend {
        let config = self.config
        return ProviderBackendFactory.make(
            provider: config.activeProvider,
            credentials: config.activeCredentials
        )
    }

    // MARK: Usage accounting

    public var usage: (prompt: Int, completion: Int) {
        lock.withLock { (_promptTokens, _completionTokens) }
    }

    public func recordUsage(prompt: Int, completion: Int) {
        lock.withLock {
            _promptTokens += prompt
            _completionTokens += completion
            // Attributed here rather than by the caller because every path that
            // spends tokens — rounds, retries, subagents a turn spawned — comes
            // through this one function, and a per-conversation figure assembled
            // from some of them would be wrong in the direction that matters.
            _conversationPrompt += prompt
            _conversationCompletion += completion
        }
    }

    public func resetUsage() {
        lock.withLock {
            _promptTokens = 0
            _completionTokens = 0
        }
    }

    /// What the open conversation has cost. Reset when the conversation changes,
    /// and seeded from the archive when one is reopened.
    public var conversationUsage: (prompt: Int, completion: Int) {
        lock.withLock { (_conversationPrompt, _conversationCompletion) }
    }

    public func resetConversationUsage(prompt: Int = 0, completion: Int = 0) {
        lock.withLock {
            _conversationPrompt = prompt
            _conversationCompletion = completion
        }
    }
}
