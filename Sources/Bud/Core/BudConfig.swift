import Foundation

// MARK: - Configuration

/// Resolved runtime configuration.
///
/// Resolution order for the model line, highest priority first:
///   1. `~/.bud/config.json`            (Bud-local override)
///   2. `~/.omp/agent/config.yml`       (the user's existing oh-my-pi setup)
///   3. built-in defaults
///
/// The API key comes from `~/.bud/config.json`, then the variable the provider
/// names in the process environment, then that same variable as set in
/// `~/.zshrc`, `~/.zprofile`, `~/.bash_profile` or `~/.profile` — see
/// `resolveKey(named:)`. The profile search is what a GUI launch from Finder
/// depends on, since it inherits no shell environment. There is no Keychain
/// lookup, and none is planned here: a reader who trusts a comment saying a
/// credential is in the Keychain will not think to look for it in `~/.bud`.
///
/// The Glama marketplace key follows the same shape: the stored config, then
/// `GLAMA_API_KEY` in the environment, then the same profile search. Skipping
/// the profile search would strand a key that is already exported in `~/.zshrc`,
/// which is where keys usually live.
/// How much of the model's thinking is shown in the transcript.
public enum ReasoningVisibility: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Streamed while the turn is running, folded away when it finishes. Watching
    /// it think is the point; re-reading it is not.
    case whileThinking = "while-thinking"
    /// Every turn's reasoning stays open.
    case always
    /// Not shown at all.
    case hidden

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .whileThinking: return "While thinking"
        case .always: return "Always"
        case .hidden: return "Hidden"
        }
    }

    public var explanation: String {
        switch self {
        case .whileThinking: return "Shown as it arrives, folded when the answer does"
        case .always: return "Every reply's reasoning stays open"
        case .hidden: return "Not shown"
        }
    }

    /// Whether a reasoning segment is open, given the state of the turn and
    /// whatever the reader chose by hand.
    ///
    /// Its own function rather than a view's computed property because this is the
    /// whole of the behaviour and it should be testable without a window: the
    /// differences between the three modes are three lines here and nowhere else.
    public func isExpanded(isStreaming: Bool, chosen: Bool?) -> Bool {
        if let chosen { return chosen }
        switch self {
        case .always: return true
        case .whileThinking: return isStreaming
        case .hidden: return false
        }
    }
}

public struct BudConfig: Sendable, Codable, Hashable {
    /// The provider the session runs against. See `ProviderRegistry`.
    public var provider: String
    /// The model chosen for each provider, keyed by provider id.
    public var providerModels: [String: String]
    /// Per-provider credentials, keyed by provider id. Storing one key per
    /// provider is what makes switching cheap — configure a provider once, then
    /// move between them without re-entering anything.
    public var providerKeys: [String: String]
    /// Per-provider base URL overrides. Required for the custom entry, and useful
    /// for routing a known provider through a proxy.
    public var providerBaseURLs: [String: String]
    /// Per-provider region, for endpoints whose host names one. Empty means "use
    /// the provider's default".
    public var providerRegions: [String: String]
    /// Glama's API key, for browsing its MCP catalogue. Empty means "not
    /// configured", which the marketplace reports as a call to action.
    public var glamaAPIKey: String
    public var reasoningEffort: String?
    /// How much of the model's thinking is on screen.
    ///
    /// Every provider Bud talks to already streams it — `reasoning_content` on the
    /// delta, decoded and stored on the turn — and the transcript has always been
    /// able to draw it. It was behind a disclosure that started closed, so in
    /// practice nobody saw it: the only way to watch the model think was to guess
    /// that the "Thought for 3.4s" line was a button.
    ///
    /// The default shows it *while* it is happening, which is when it is worth
    /// reading, and folds it away when the answer arrives so that a long
    /// conversation is not mostly thinking. `always` keeps every one open;
    /// `hidden` puts it back the way it was before this existed.
    public var reasoningVisibility: ReasoningVisibility
    public var temperature: Double?
    public var maxTokens: Int?
    public var systemPrompt: String
    public var maxToolRounds: Int
    public var allowParallelSubagents: Int
    /// Whether a tool that changes the machine asks before it acts.
    ///
    /// On by default, and that is the point: a page or a server can put text in
    /// front of a model that has a shell, and the alternative to asking is trusting
    /// the model to notice that the instruction came from somewhere else. Turning
    /// it off is a decision somebody makes in Settings, not one they inherit.
    public var confirmDangerousTools: Bool
    /// How much of the conversation the model is sent, in characters.
    ///
    /// History grew without limit: a tool result is capped at 24,000 characters
    /// when it arrives, and nothing capped the total, so a long conversation
    /// re-sent every result it had ever received on every round. The user keeps
    /// seeing all of it — this bounds what the *model* carries, by dropping the
    /// contents of the oldest tool results first.
    ///
    /// 120,000 characters is about 30,000 tokens: comfortably more than the whole
    /// request prefix, and small enough to leave a 64k window room to think.
    public var historyBudgetChars: Int

    // MARK: Updates

    /// The GitHub repository whose releases carry the update feed.
    public var updateRepo: String
    /// An explicit manifest URL, for a feed that is not GitHub. Empty means the
    /// repository above.
    public var updateFeedURL: String
    /// Token for a private repository. Empty falls back to the environment.
    public var updateToken: String
    /// `stable` or `prerelease`.
    public var updateChannel: String
    /// Whether Bud looks for updates on its own. Checking is silent; nothing is
    /// ever downloaded without the user asking.
    public var autoCheckUpdates: Bool
    /// Tokens a single conversation may spend before Bud stops starting turns.
    /// Zero means no ceiling, which is the default: a limit nobody asked for
    /// would be the app deciding when to stop working.
    public var conversationTokenBudget: Int

    /// The defaults shipped before this one, verbatim.
    ///
    /// A stored prompt that matches one of these was never a decision — it is a
    /// copy of a default somebody saved a version ago, and letting it win would
    /// mean the shipped prompt could never change for anyone who ever pressed
    /// Save. Matching is on the trimmed text, so a lost trailing newline does not
    /// defeat it. **A change to `defaultSystemPrompt` adds its predecessor here**,
    /// because this list is the whole of what distinguishes "never customised"
    /// from "deliberately changed".
    public static let supersededSystemPrompts: [String] = [
        """
        You are Bud, a native macOS assistant living in a floating Liquid Glass panel.

        You have tools. Use them without asking permission and without narrating that you are about to use them — just call them and report what you found.

        Tool families:
        - `mcp__<server>__<tool>` — tools from connected MCP servers. Their names tell you which server owns them; prefer the most specific server for the job.
        - `render_ui` — emit a rich surface (cards, metrics, tables, charts, buttons) when a visual answer beats prose. Use it for comparisons, dashboards, status reports, and anything the user will want to scan rather than read.
        - `spawn_subagents` — run independent slices of work concurrently, each in a fresh context. Use it when a request has genuinely separable parts; do not use it to do one thing in parallel with itself.
        - `web_fetch`, `read_file`, `list_files`, `run_shell` — local capabilities.

        Style: lead with the answer. Short paragraphs. No preamble, no filler, no summarising what you just did. If a tool failed, say what failed and what you tried. Never invent tool output.
        """,
    ]

    /// Whether this text is a default Bud shipped rather than something somebody
    /// wrote.
    ///
    /// Compared trimmed: a prompt that has been through a save and a load can lose
    /// a trailing newline, and that is not a decision anybody made.
    public static func isShippedDefaultPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        return supersededSystemPrompts.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    public static let defaultSystemPrompt = """
    You are Bud, a collaborator in a floating Liquid Glass panel on this Mac: \
    beside someone competent, on what they care about, never explaining what they \
    clearly know. The regard is real, and it shows as usefulness and memory rather \
    than performed feeling: no pet name, no "friend".

    You have tools. Use them without asking and without narrating that you are \
    about to: call them, and report what you found.

    Tool families:
    - `<server>__<tool>` — tools from connected MCP servers. The name says \
    which server owns it; prefer the most specific server for the job.
    - `render_ui` — emit a rich surface (cards, metrics, tables, charts, buttons) \
    when a visual answer beats prose: comparisons, dashboards, status reports, \
    anything they will scan rather than read.
    - `spawn_subagents` — run independent slices of work concurrently, each in a \
    fresh context. Use it when a request has genuinely separable parts; never to \
    do one thing in parallel with itself.
    - `web_fetch`, `read_file`, `list_files`, `run_shell` — local capabilities.

    How you talk. Lead with the answer. Short sentences, plain words, \
    contractions. Wry when it's free, never at their expense. No preamble, no \
    flattery, no summarising what you just did. Say what you don't know plainly. \
    If a tool failed, say what failed and what you tried; never invent its output.

    What you know. Notes are things you picked up, not a list to recite: never \
    open with "I remember that you…" — just be someone who knows. Keep what's \
    worth keeping, and say nothing about it.
    """

    public init(
        provider: String = "deepseek",
        providerModels: [String: String] = [:],
        providerKeys: [String: String] = [:],
        providerBaseURLs: [String: String] = [:],
        providerRegions: [String: String] = [:],
        glamaAPIKey: String = "",
        reasoningEffort: String? = nil,
        reasoningVisibility: ReasoningVisibility = .whileThinking,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        systemPrompt: String = BudConfig.defaultSystemPrompt,
        maxToolRounds: Int = 24,
        allowParallelSubagents: Int = 6,
        confirmDangerousTools: Bool = true,
        historyBudgetChars: Int = 120_000,
        updateRepo: String = BudConfig.defaultUpdateRepo,
        updateFeedURL: String = "",
        updateToken: String = "",
        updateChannel: String = "stable",
        autoCheckUpdates: Bool = true,
        conversationTokenBudget: Int = 0
    ) {
        self.provider = provider
        self.providerModels = providerModels
        self.providerKeys = providerKeys
        self.providerBaseURLs = providerBaseURLs
        self.providerRegions = providerRegions
        self.glamaAPIKey = glamaAPIKey
        self.reasoningEffort = reasoningEffort
        self.reasoningVisibility = reasoningVisibility
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
        self.maxToolRounds = maxToolRounds
        self.allowParallelSubagents = allowParallelSubagents
        self.confirmDangerousTools = confirmDangerousTools
        self.historyBudgetChars = historyBudgetChars
        self.updateRepo = updateRepo
        self.updateFeedURL = updateFeedURL
        self.updateToken = updateToken
        self.updateChannel = updateChannel
        self.autoCheckUpdates = autoCheckUpdates
        self.conversationTokenBudget = conversationTokenBudget
    }

    public var displayModel: String { model }
    public var host: String { URL(string: baseURL)?.host() ?? baseURL }

    // MARK: Active provider

    /// The provider the settings currently point at.
    public var activeProvider: ProviderDescriptor {
        ProviderRegistry.provider(orFallback: provider)
    }

    /// The model for the active provider.
    ///
    /// Computed over `providerModels` so call sites read naturally while each
    /// provider keeps its own choice underneath. Falls back to the provider's
    /// suggested model so a freshly selected provider is never blank.
    public var model: String {
        get {
            let stored = providerModels[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty { return stored }
            return activeProvider.defaultModel ?? ""
        }
        set { providerModels[provider] = newValue }
    }

    /// The API key for the active provider.
    ///
    /// A computed property rather than a stored one so that existing call sites —
    /// and the verification suites — keep reading naturally, while storage stays
    /// per provider underneath.
    public var apiKey: String {
        get { providerKeys[provider] ?? "" }
        set { providerKeys[provider] = newValue }
    }

    /// The base URL for the active provider: an override when one is set,
    /// otherwise the registry's endpoint resolved for the selected region.
    public var baseURL: String {
        get {
            let override = providerBaseURLs[provider]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let override, !override.isEmpty { return override }
            return activeProvider.baseURL(region: region)
        }
        set { providerBaseURLs[provider] = newValue }
    }

    /// The region for the active provider. Empty means the provider's default.
    ///
    /// Stored per provider like the model and the key: moving between a Bedrock
    /// endpoint in one region and a direct vendor in another should not reset
    /// either one's settings.
    public var region: String {
        get { providerRegions[provider] ?? "" }
        set { providerRegions[provider] = newValue }
    }

    /// Everything a backend needs for the current provider, with the key
    /// resolved from storage, the environment, or the shell profile.
    public var activeCredentials: ProviderCredentials {
        ProviderCredentials(
            apiKey: resolvedKey(for: activeProvider),
            baseURL: providerBaseURLs[provider],
            region: region
        )
    }

    /// Resolves a provider's credential, in the order that makes a
    /// Finder-launched app work: what the user typed, then the process
    /// environment, then their shell profile.
    public func resolvedKey(for provider: ProviderDescriptor) -> String {
        let stored = providerKeys[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return BudConfigLoader.resolveKey(for: provider)
    }

    public static let defaultUpdateRepo = "mriver15/bud"

    /// The repository's token, from settings or the environment.
    ///
    /// Both variable names are read because `gh` uses `GH_TOKEN` while most CI
    /// sets `GITHUB_TOKEN`, and a user who has exported either should not have to
    /// find out which one Bud wanted.
    public var resolvedUpdateToken: String {
        let stored = updateToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        for name in ["BUD_UPDATE_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
            let value = BudConfigLoader.resolveKey(named: name)
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// Everything the updater needs, resolved.
    ///
    /// The signing key is compiled in rather than configurable: a key that could
    /// be edited alongside the config would let anything that can write that file
    /// install anything it likes.
    public var updateFeed: UpdateFeed {
        UpdateFeed(
            repo: updateRepo.trimmingCharacters(in: .whitespaces).isEmpty
                ? Self.defaultUpdateRepo
                : updateRepo,
            manifestURL: updateFeedURL,
            token: resolvedUpdateToken,
            channel: updateChannel,
            publicKey: UpdateTrust.publicKey
        )
    }

    /// True when the active provider wants a key and does not have one.
    public var activeProviderNeedsKey: Bool {
        activeProvider.requiresKey && resolvedKey(for: activeProvider).isEmpty
    }

    /// True when the custom provider is selected but has no endpoint to call.
    public var customProviderNeedsBaseURL: Bool {
        activeProvider.isCustom && baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The first thing standing between the user and a working request, or nil
    /// when the provider is ready.
    ///
    /// Reported as a sentence rather than as booleans because there are now three
    /// distinct reasons Bud cannot send — a missing key, a missing base URL for
    /// the custom entry, and a missing model — and a single "add your API key"
    /// message is wrong for two of them.
    public var setupProblem: String? {
        if customProviderNeedsBaseURL {
            return "\(activeProvider.name) needs a base URL before Bud can send anything."
        }
        if activeProviderNeedsKey {
            return "No API key for \(activeProvider.name)."
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            let suggested = activeProvider.defaultModel.map { " Try \($0)." } ?? ""
            return "No model set for \(activeProvider.name).\(suggested)"
        }
        return nil
    }

    /// Short label for the button that fixes the problem.
    public var setupAction: String { "Open Settings" }
}

// MARK: - Loading

public enum BudConfigLoader {
    public static let budDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".bud", isDirectory: true)

    public static var configURL: URL { budDirectory.appendingPathComponent("config.json") }
    public static var mcpURL: URL { budDirectory.appendingPathComponent("mcp.json") }
    public static var conversationsURL: URL { budDirectory.appendingPathComponent("conversations.json") }

    private static var ompConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/config.yml")
    }

    public static func ensureDirectory() {
        createOwnerOnlyDirectory(budDirectory)
    }

    // MARK: Permissions

    /// Bud's directory holds credentials and transcribed work; nothing in it is
    /// for anyone but its owner. The two modes live here so the number is written
    /// down once, next to the functions that apply it.
    static let directoryMode = 0o700
    static let fileMode = 0o600

    /// Creates a directory its owner alone can read or traverse, and tightens one
    /// that already exists.
    ///
    /// `createDirectory` applies no mode of its own, so `~/.bud` used to take the
    /// umask — 0755 for almost every account — and the directory was listable and
    /// traversable by anyone on the machine while every file inside it was
    /// carefully 0600. The attributes are set on the path afterwards as well,
    /// because `attributes` only apply to a directory this call actually creates:
    /// an install that predates this keeps its 0755 until something fixes it.
    static func createOwnerOnlyDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        restrictToOwner(url, mode: directoryMode)
    }

    /// Makes a file or directory that already exists owner-only.
    static func restrictToOwner(_ url: URL, mode: Int = fileMode) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: url.path
        )
    }

    /// Writes a file only its owner can read.
    ///
    /// `.atomic` writes a temporary file and renames it into place, and the
    /// temporary is created by the write rather than copied from the destination —
    /// a file that already existed at 0600 still lands at the umask's mode, which
    /// is how `config.json` was safe and the tool-result store beside it was not.
    /// So the permissions are set on the final path, after the rename, which is
    /// the first moment the file exists under its own name.
    static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: fileMode], ofItemAtPath: url.path
        )
    }

    /// Folds a stored config onto a base one.
    ///
    /// Pure and separate from `load()` so the migration can be tested without a
    /// real config file on disk. Getting this wrong loses a credential the user
    /// already gave us, which is the kind of failure that only shows up as a 401
    /// much later.
    static func apply(_ stored: StoredConfig, to config: BudConfig) -> BudConfig {
        var config = config
        if let v = stored.provider, !v.isEmpty { config.provider = v }
        if let v = stored.providerModels { config.providerModels = v }
        if let v = stored.providerKeys { config.providerKeys = v }
        if let v = stored.providerBaseURLs { config.providerBaseURLs = v }
        if let v = stored.providerRegions { config.providerRegions = v }
        if let v = stored.updateRepo { config.updateRepo = v }
        if let v = stored.updateFeedURL { config.updateFeedURL = v }
        if let v = stored.updateToken { config.updateToken = v }
        if let v = stored.updateChannel { config.updateChannel = v }
        if let v = stored.autoCheckUpdates { config.autoCheckUpdates = v }
        if let v = stored.conversationTokenBudget { config.conversationTokenBudget = v }

        // Migration from the single-provider shape. The key and URL used to
        // belong to DeepSeek implicitly, because DeepSeek was the only provider;
        // fold them into the per-provider maps so an existing install keeps
        // working and nobody is asked to re-enter a credential.
        if let legacyKey = stored.apiKey, !legacyKey.isEmpty,
           config.providerKeys["deepseek"]?.isEmpty ?? true {
            config.providerKeys["deepseek"] = legacyKey
        }
        if let legacyURL = stored.baseURL, !legacyURL.isEmpty,
           config.providerBaseURLs["deepseek"]?.isEmpty ?? true {
            config.providerBaseURLs["deepseek"] = legacyURL
        }

        // The pre-provider shape stored the model as a plain string. It belongs
        // to whichever provider was the only one at the time.
        if let legacyModel = stored.model, !legacyModel.isEmpty,
           config.providerModels["deepseek"]?.isEmpty ?? true {
            config.providerModels["deepseek"] = legacyModel
        }

        if let v = stored.glamaAPIKey, !v.isEmpty { config.glamaAPIKey = v }
        if let v = stored.reasoningEffort { config.reasoningEffort = v }
        if let v = stored.reasoningVisibility { config.reasoningVisibility = v }
        if let v = stored.temperature { config.temperature = v }
        if let v = stored.maxTokens { config.maxTokens = v }
        // A prompt that matches a default Bud itself shipped was never a decision,
        // so it does not get to outlive the default it was copied from. Anything
        // else is a real customisation and still wins.
        if let v = stored.systemPrompt, !v.isEmpty, !BudConfig.isShippedDefaultPrompt(v) {
            config.systemPrompt = v
        }
        if let v = stored.maxToolRounds { config.maxToolRounds = v }
        if let v = stored.allowParallelSubagents { config.allowParallelSubagents = v }
        if let v = stored.confirmDangerousTools { config.confirmDangerousTools = v }
        if let v = stored.historyBudgetChars { config.historyBudgetChars = v }
        return config
    }

    /// Reads and caches. Failure is never fatal — a missing key surfaces in the UI
    /// as a first-run prompt rather than a crash.
    public static func load() -> BudConfig {
        ensureDirectory()
        var config = BudConfig()

        // 2. The user's oh-my-pi configuration wins over built-in defaults.
        if let (model, effort) = readOMPModelRole() {
            config.providerModels["deepseek"] = model
            config.reasoningEffort = effort
        }

        // 1. Bud-local override wins over everything on disk.
        if let data = try? Data(contentsOf: configURL),
           let stored = try? JSONDecoder().decode(StoredConfig.self, from: data) {
            config = apply(stored, to: config)
        }

        // A Finder launch inherits no environment, so the profile search is what
        // actually finds a key that is exported in ~/.zshrc.
        if config.glamaAPIKey.isEmpty { config.glamaAPIKey = resolveKey(named: "GLAMA_API_KEY") }
        return config
    }

    public static func save(_ config: BudConfig) {
        ensureDirectory()
        let stored = StoredConfig(from: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        // The file holds a credential; the helper keeps it owner-only.
        try? writeOwnerOnly(data, to: configURL)
    }

    /// Writes only the API key without disturbing anything else.
    public static func persistAPIKey(_ key: String) {
        var config = load()
        config.apiKey = key
        save(config)
    }

    // MARK: oh-my-pi config

    /// Extracts `modelRoles.default`, e.g. `deepseek/deepseek-v4-flash:max`
    /// -> model `deepseek-v4-flash`, effort `max`.
    ///
    /// Hand-rolled rather than pulling in a YAML dependency: the file is two
    /// levels deep and a dependency would be a supply-chain and build cost for
    /// one key. Unknown shapes simply fall through to defaults.
    static func readOMPModelRole() -> (model: String, effort: String?)? {
        guard let text = try? String(contentsOf: ompConfigURL, encoding: .utf8) else { return nil }
        return Self.parseModelRole(fromYAML: text)
    }

    static func parseModelRole(fromYAML text: String) -> (model: String, effort: String?)? {
        var inModelRoles = false
        var indentOfKey: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count

            if let outer = indentOfKey {
                // Inside `modelRoles:` — a sibling key at or below the parent
                // indent ends the block.
                if indent <= outer - 1, !trimmed.hasPrefix("default:") { inModelRoles = false }
            }

            if trimmed.hasPrefix("modelRoles:") {
                inModelRoles = true
                indentOfKey = indent + 1
                continue
            }
            guard inModelRoles, trimmed.hasPrefix("default:") else { continue }

            var value = String(trimmed.dropFirst("default:".count))
                .trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { return nil }

            // `provider/model:effort`
            var model = value
            var effort: String?
            if let colon = model.lastIndex(of: ":") {
                effort = String(model[model.index(after: colon)...])
                model = String(model[..<colon])
            }
            if let slash = model.lastIndex(of: "/") {
                model = String(model[model.index(after: slash)...])
            }
            guard !model.isEmpty else { return nil }
            return (model, effort)
        }
        return nil
    }

    // MARK: API key resolution

    /// Environment first, then the profile a Finder launch never read.
    ///
    /// The value is returned, never logged: both callers only ever assign it to
    /// the config, and a key is a credential.
    static func resolveKey(named variable: String) -> String {
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty {
            return value
        }
        if let value = readKeyFromShellProfiles(named: variable), !value.isEmpty { return value }
        return ""
    }

    /// Tries each variable the provider publishes, in the order it lists them.
    ///
    /// Providers ship more than one name for the same credential — Google accepts
    /// both `GEMINI_API_KEY` and `GOOGLE_GENERATIVE_AI_API_KEY` — and which one a
    /// user exported is not something they should have to think about.
    static func resolveKey(for provider: ProviderDescriptor) -> String {
        for variable in provider.envKeys {
            let value = resolveKey(named: variable)
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// A Finder-launched app sees none of the shell environment, so the key is
    /// recovered from the profile that defines it.
    static func readKeyFromShellProfiles(named variable: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".zprofile", ".bash_profile", ".profile"] {
            let url = home.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let value = parseShellAssignment(in: text, named: variable) { return value }
        }
        return nil
    }

    /// Pulls `NAME=value` — with or without a leading `export ` — out of a
    /// profile's text, unquoting a quoted value.
    ///
    /// Separate from the file walk so the parsing is testable without touching
    /// the filesystem: the quote handling is the part that fails quietly, turning
    /// `export NAME="abc"` into a value with the quotes still on it.
    static func parseShellAssignment(in text: String, named variable: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let assignment: String
            if line.hasPrefix("export \(variable)=") {
                assignment = String(line.dropFirst("export ".count))
            } else if line.hasPrefix("\(variable)=") {
                assignment = line
            } else {
                continue
            }

            var value = String(assignment.dropFirst(variable.count + 1))
                .trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    public struct StoredConfig: Codable, Sendable {
        /// Every field is optional so a config written by an older build still
        /// decodes, and a config written by this build can be read by one that
        /// only knows some of it.
        public var provider: String?
        public var model: String?
        public var providerModels: [String: String]?
        public var providerKeys: [String: String]?
        public var providerBaseURLs: [String: String]?
        public var providerRegions: [String: String]?
        public var updateRepo: String?
        public var updateFeedURL: String?
        public var updateToken: String?
        public var updateChannel: String?
        public var autoCheckUpdates: Bool?
        public var conversationTokenBudget: Int?
        public var glamaAPIKey: String?
        public var reasoningEffort: String?
        public var reasoningVisibility: ReasoningVisibility?
        public var temperature: Double?
        public var maxTokens: Int?
        public var systemPrompt: String?
        public var maxToolRounds: Int?
        public var allowParallelSubagents: Int?
        public var confirmDangerousTools: Bool?
        public var historyBudgetChars: Int?

        /// The single-provider shape Bud used before it supported more than
        /// DeepSeek. Read once and folded into `providerKeys`, never written.
        public var apiKey: String?
        public var baseURL: String?

        /// Projects a live config onto the persisted shape.
        ///
        /// The legacy single-provider fields are deliberately left nil: they are
        /// read once for migration and never written again, so a saved file has
        /// exactly one representation of where a credential lives.
        public init(from config: BudConfig) {
            self.provider = config.provider
            self.model = nil
            self.providerModels = config.providerModels
            self.providerKeys = config.providerKeys
            self.providerBaseURLs = config.providerBaseURLs
            self.providerRegions = config.providerRegions
            self.updateRepo = config.updateRepo
            self.updateFeedURL = config.updateFeedURL
            self.updateToken = config.updateToken
            self.updateChannel = config.updateChannel
            self.autoCheckUpdates = config.autoCheckUpdates
            self.conversationTokenBudget = config.conversationTokenBudget
            self.glamaAPIKey = config.glamaAPIKey
            self.reasoningEffort = config.reasoningEffort
            self.reasoningVisibility = config.reasoningVisibility
            self.temperature = config.temperature
            self.maxTokens = config.maxTokens
            // Left out when it is the default rather than written out again: a
            // kilobyte of prose the binary already contains, that would then have
            // to be recognised as a copy on the next load.
            self.systemPrompt = BudConfig.isShippedDefaultPrompt(config.systemPrompt)
                ? nil
                : config.systemPrompt
            self.maxToolRounds = config.maxToolRounds
            self.allowParallelSubagents = config.allowParallelSubagents
            self.confirmDangerousTools = config.confirmDangerousTools
            self.historyBudgetChars = config.historyBudgetChars
        }

        public init(
            provider: String? = nil,
            model: String? = nil,
            providerModels: [String: String]? = nil,
            providerKeys: [String: String]? = nil,
            providerBaseURLs: [String: String]? = nil,
            providerRegions: [String: String]? = nil,
            updateRepo: String? = nil,
            updateFeedURL: String? = nil,
            updateToken: String? = nil,
            updateChannel: String? = nil,
            autoCheckUpdates: Bool? = nil,
            conversationTokenBudget: Int? = nil,
            glamaAPIKey: String? = nil,
            reasoningEffort: String? = nil,
            reasoningVisibility: ReasoningVisibility = .whileThinking,
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            systemPrompt: String? = nil,
            maxToolRounds: Int? = nil,
            allowParallelSubagents: Int? = nil,
            confirmDangerousTools: Bool? = nil,
            apiKey: String? = nil,
            baseURL: String? = nil
        ) {
            self.provider = provider
            self.model = model
            self.providerModels = providerModels
            self.providerKeys = providerKeys
            self.providerBaseURLs = providerBaseURLs
            self.providerRegions = providerRegions
            self.updateRepo = updateRepo
            self.updateFeedURL = updateFeedURL
            self.updateToken = updateToken
            self.updateChannel = updateChannel
            self.autoCheckUpdates = autoCheckUpdates
            self.conversationTokenBudget = conversationTokenBudget
            self.glamaAPIKey = glamaAPIKey
            self.reasoningEffort = reasoningEffort
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.systemPrompt = systemPrompt
            self.maxToolRounds = maxToolRounds
            self.allowParallelSubagents = allowParallelSubagents
            self.confirmDangerousTools = confirmDangerousTools
            self.apiKey = apiKey
            self.baseURL = baseURL
        }
    }
}
