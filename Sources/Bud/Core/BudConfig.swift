import Foundation

// MARK: - Configuration

/// Resolved runtime configuration.
///
/// Resolution order for the model line, highest priority first:
///   1. `~/.bud/config.json`            (Bud-local override)
///   2. `~/.omp/agent/config.yml`       (the user's existing oh-my-pi setup)
///   3. built-in defaults
///
/// The API key comes from `~/.bud/config.json`, then the Keychain, then
/// `DEEPSEEK_API_KEY` in the environment, then `~/.zshrc`. The shell fallback
/// matters because a GUI launch from Finder inherits no shell environment.
public struct BudConfig: Sendable, Codable, Hashable {
    public var model: String
    public var baseURL: String
    public var apiKey: String
    public var reasoningEffort: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var systemPrompt: String
    public var maxToolRounds: Int
    public var allowParallelSubagents: Int

    public static let defaultSystemPrompt = """
    You are Bud, a native macOS assistant living in a floating Liquid Glass panel.

    You have tools. Use them without asking permission and without narrating that \
    you are about to use them — just call them and report what you found.

    Tool families:
    - `mcp__<server>__<tool>` — tools from connected MCP servers. Their names tell \
    you which server owns them; prefer the most specific server for the job.
    - `render_ui` — emit a rich surface (cards, metrics, tables, charts, buttons) \
    when a visual answer beats prose. Use it for comparisons, dashboards, status \
    reports, and anything the user will want to scan rather than read.
    - `spawn_subagents` — run independent slices of work concurrently, each in a \
    fresh context. Use it when a request has genuinely separable parts; do not \
    use it to do one thing in parallel with itself.
    - `web_fetch`, `read_file`, `list_files`, `run_shell` — local capabilities.

    Style: lead with the answer. Short paragraphs. No preamble, no filler, no \
    summarising what you just did. If a tool failed, say what failed and what \
    you tried. Never invent tool output.
    """

    public init(
        model: String = "deepseek-v4-flash",
        baseURL: String = "https://api.deepseek.com/v1",
        apiKey: String = "",
        reasoningEffort: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        systemPrompt: String = BudConfig.defaultSystemPrompt,
        maxToolRounds: Int = 24,
        allowParallelSubagents: Int = 6
    ) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
        self.maxToolRounds = maxToolRounds
        self.allowParallelSubagents = allowParallelSubagents
    }

    public var displayModel: String { model }
    public var host: String { URL(string: baseURL)?.host() ?? baseURL }
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
        try? FileManager.default.createDirectory(
            at: budDirectory, withIntermediateDirectories: true
        )
    }

    /// Reads and caches. Failure is never fatal — a missing key surfaces in the UI
    /// as a first-run prompt rather than a crash.
    public static func load() -> BudConfig {
        ensureDirectory()
        var config = BudConfig()

        // 2. The user's oh-my-pi configuration wins over built-in defaults.
        if let (model, effort) = readOMPModelRole() {
            config.model = model
            config.reasoningEffort = effort
        }

        // 1. Bud-local override wins over everything on disk.
        if let data = try? Data(contentsOf: configURL),
           let stored = try? JSONDecoder().decode(StoredConfig.self, from: data) {
            if let v = stored.model, !v.isEmpty { config.model = v }
            if let v = stored.baseURL, !v.isEmpty { config.baseURL = v }
            if let v = stored.apiKey, !v.isEmpty { config.apiKey = v }
            if let v = stored.reasoningEffort { config.reasoningEffort = v }
            if let v = stored.temperature { config.temperature = v }
            if let v = stored.maxTokens { config.maxTokens = v }
            if let v = stored.systemPrompt, !v.isEmpty { config.systemPrompt = v }
            if let v = stored.maxToolRounds { config.maxToolRounds = v }
            if let v = stored.allowParallelSubagents { config.allowParallelSubagents = v }
        }

        if config.apiKey.isEmpty { config.apiKey = resolveAPIKey() }
        return config
    }

    public static func save(_ config: BudConfig) {
        ensureDirectory()
        let stored = StoredConfig(
            model: config.model,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            reasoningEffort: config.reasoningEffort,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            systemPrompt: config.systemPrompt,
            maxToolRounds: config.maxToolRounds,
            allowParallelSubagents: config.allowParallelSubagents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: configURL, options: [.atomic])
        // The file holds a credential; keep it owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configURL.path
        )
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

    static func resolveAPIKey() -> String {
        if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty {
            return key
        }
        if let key = readKeyFromShellProfiles(), !key.isEmpty { return key }
        return ""
    }

    /// A Finder-launched app sees none of the shell environment, so the key is
    /// recovered from the profile that defines it.
    static func readKeyFromShellProfiles() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".zprofile", ".bash_profile", ".profile"] {
            let url = home.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("export DEEPSEEK_API_KEY=") ||
                      line.hasPrefix("DEEPSEEK_API_KEY=") else { continue }
                var value = line.replacingOccurrences(of: "export ", with: "")
                    .replacingOccurrences(of: "DEEPSEEK_API_KEY=", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    public struct StoredConfig: Codable, Sendable {
        public var model: String?
        public var baseURL: String?
        public var apiKey: String?
        public var reasoningEffort: String?
        public var temperature: Double?
        public var maxTokens: Int?
        public var systemPrompt: String?
        public var maxToolRounds: Int?
        public var allowParallelSubagents: Int?

        public init(
            model: String? = nil, baseURL: String? = nil, apiKey: String? = nil,
            reasoningEffort: String? = nil, temperature: Double? = nil,
            maxTokens: Int? = nil, systemPrompt: String? = nil,
            maxToolRounds: Int? = nil, allowParallelSubagents: Int? = nil
        ) {
            self.model = model
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.reasoningEffort = reasoningEffort
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.systemPrompt = systemPrompt
            self.maxToolRounds = maxToolRounds
            self.allowParallelSubagents = allowParallelSubagents
        }
    }
}
