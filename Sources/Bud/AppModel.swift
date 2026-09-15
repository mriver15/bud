import Foundation
import Observation

public enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case general, mcp, marketplace, subagents, tools, about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .mcp: return "Connections"
        case .marketplace: return "Marketplace"
        case .subagents: return "Subagents"
        case .tools: return "Tools"
        case .about: return "About"
        }
    }

    public var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .marketplace: return "square.grid.2x2"
        case .subagents: return "person.3.sequence"
        case .tools: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

/// Root application state. Owns the subsystems, exposes one coherent surface to
/// the views, and is the only writer of the live config.
@MainActor
@Observable
public final class AppModel {
    // MARK: Subsystems

    public let env: AppEnvironment
    public let runtime: AgentRuntime
    public let mcp: MCPManager
    public let marketplace: MarketplaceStore
    public let subagents: SubagentSupervisor

    // MARK: UI state

    public var composerText: String = ""
    public var errorMessage: String?
    public var availableTools: [ToolDescriptor] = []
    public var settingsTab: SettingsTab = .general
    public var showingSettings = false
    public var showingSubagents = false

    /// Live config. Mirrored into `env` on every write so background work always
    /// reads what the user last saved, and persisted only when the user commits
    /// (a per-keystroke file write would be wasteful).
    public var config: BudConfig {
        didSet {
            guard config != oldValue else { return }
            env.config = config
            // The API key and model are read per-request, so a change takes
            // effect on the next turn without any further plumbing.
        }
    }

    /// Set by the shell to present the settings window.
    public var onPresentSettings: (@MainActor (SettingsTab) -> Void)?
    /// Set by the shell to toggle the floating panel.
    public var onTogglePanel: (@MainActor () -> Void)?
    /// Set by the shell to quit.
    public var onQuit: (@MainActor () -> Void)?

    private var didStart = false

    public init(config: BudConfig = BudConfigLoader.load()) {
        let env = AppEnvironment(config: config)
        self.env = env
        self.config = config
        self.runtime = AgentRuntime(env: env)
        self.mcp = MCPManager()
        self.marketplace = MarketplaceStore()
        self.subagents = SubagentSupervisor(env: env)
    }

    // MARK: Derived state

    public var turns: [Turn] { runtime.turns }
    public var isStreaming: Bool { runtime.isStreaming }
    public var statusText: String { runtime.statusText }
    public var modelName: String { config.model }
    public var hasAPIKey: Bool { !config.apiKey.isEmpty }

    public var usageSummary: String {
        let u = env.usage
        guard u.prompt + u.completion > 0 else { return "No usage yet" }
        return "\(BudFormat.tokens(u.prompt)) in · \(BudFormat.tokens(u.completion)) out"
    }

    public var readyServerCount: Int {
        mcp.statuses.values.count { $0.state == .ready }
    }

    public var runningSubagentCount: Int {
        subagents.runs.count { $0.state == .running }
    }

    // MARK: Lifecycle

    /// Registers providers, restores MCP connections and warms the marketplace.
    /// Idempotent — the first window and a menu action can both call it.
    public func start() async {
        guard !didStart else { return }
        didStart = true

        BudConfigLoader.ensureDirectory()
        let providers: [any ToolProvider] = [
            NativeToolsProvider(),
            mcp,
            subagents,
            GenUIToolProvider(),
        ]
        for provider in providers {
            await env.registry.register(provider)
        }

        marketplace.isInstalled = { [weak self] server in
            guard let self else { return false }
            return self.mcp.servers.contains { $0.registryName == server.name }
        }

        await refreshTools()
        await mcp.connectAllAutoStart()
        await refreshTools()

        Task { await marketplace.loadInitial() }
    }

    public func shutdown() async {
        runtime.stop()
        await mcp.shutdown()
        BudConfigLoader.save(config)
    }

    // MARK: Conversation

    public func send(_ text: String? = nil) async {
        let message = (text ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !runtime.isStreaming else { return }
        composerText = ""
        errorMessage = nil
        runtime.send(message)
        // The runtime runs the turn on its own task so the caller (a button, a
        // slash command, a generated-UI action) is never blocked by it.
    }

    public func stop() { runtime.stop() }

    public func clearTranscript() {
        runtime.clear()
        errorMessage = nil
    }

    /// Handles a button press from a generated UI surface: an action carrying a
    /// `prompt` becomes the next user turn, otherwise the action id is reported
    /// back so the model can decide what it means.
    public func submit(action: GenUIAction) async {
        if let prompt = action.payload["prompt"]?.stringValue, !prompt.isEmpty {
            await send(prompt)
        } else {
            await send("The user pressed the “\(action.id)” control.")
        }
    }

    // MARK: Tools

    public func refreshTools() async {
        availableTools = await env.registry.descriptors()
    }

    // MARK: Settings / navigation

    public func openSettings(tab: SettingsTab) {
        settingsTab = tab
        presentingSettings()
    }

    private func presentingSettings() {
        showingSettings = true
        if let onPresentSettings {
            onPresentSettings(settingsTab)
        }
    }

    public func closeSettings() { showingSettings = false }

    public func persistConfig() {
        BudConfigLoader.save(config)
    }

    /// Applies a model switch without touching the rest of the config.
    public func setModel(_ model: String) {
        config.model = model
        env.config = config
        BudConfigLoader.save(config)
    }
}
