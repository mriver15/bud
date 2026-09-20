import Foundation

// MARK: - Server health

/// The connection health of one MCP server, derived from the state the manager
/// already publishes. A small vocabulary over `MCPConnectionState` rather than a
/// second source of truth: every input is one the manager owns, so the badge can
/// never disagree with the status line it sits beside.
public enum ServerHealth: Sendable, Hashable {
    case healthy
    case starting
    case authNeeded
    case crashed
    case disabled

    public var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .starting: return "Starting"
        case .authNeeded: return "Auth needed"
        case .crashed: return "Crashed"
        case .disabled: return "Disabled"
        }
    }

    public var symbol: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .starting: return "clock.fill"
        case .authNeeded: return "key.fill"
        case .crashed: return "exclamationmark.octagon.fill"
        case .disabled: return "circle.slash.fill"
        }
    }

    /// Derives the badge state from exactly what the manager exposes.
    ///
    /// - `state == .ready` is Healthy; `.connecting` is Starting.
    /// - `.failed` is split by whether the error text says it was the credentials:
    ///   an auth-looking failure is "Auth needed", anything else is "Crashed".
    /// - Everything else is Disabled: a disabled server is Disabled outright, and
    ///   so is a stopped one — whether it will not auto-start or was disconnected
    ///   by hand, a stopped server offers the model nothing right now.
    ///
    /// `autoStart` does not appear because it changes nothing the badge shows: a
    /// stopped server is Disabled whether or not it would have connected at
    /// launch, and a server that *is* connected is Healthy/Starting however it got
    /// there.
    public static func derive(
        state: MCPConnectionState,
        enabled: Bool,
        error: String?
    ) -> ServerHealth {
        guard enabled else { return .disabled }
        switch state {
        case .ready: return .healthy
        case .connecting: return .starting
        case .failed: return looksLikeAuth(error) ? .authNeeded : .crashed
        case .stopped: return .disabled
        }
    }

    /// Whether a failed server's error text reads as a credentials problem
    /// rather than a crash.
    ///
    /// Matched on explicit signals — the HTTP auth status codes and the words
    /// servers actually print — not on a guess about what a token looks like.
    /// It is deliberately conservative: a failure that does not *say* it is about
    /// credentials maps to "Crashed", which is the honest default for "it broke".
    /// The only real cost of the heuristic is a server that prints `401` once and
    /// then crashes being labelled "Auth needed"; the reverse error — hiding
    /// "your key is wrong" behind "it crashed" — sends the user through a log for
    /// a fact the badge already knew.
    private static func looksLikeAuth(_ error: String?) -> Bool {
        guard let error, !error.isEmpty else { return false }
        let lower = error.lowercased()
        let signals = [
            "401", "403",
            "unauthorized", "unauthorised",
            "authentication", "unauthenticated",
            "api key", "apikey",
            "invalid token", "invalid credential", "bad credentials",
            "credentials", "forbidden", "permission denied",
        ]
        return signals.contains { lower.contains($0) }
    }
}

// MARK: - Diagnostic bundle

/// Builds the redacted plain-text bundle behind Settings › About's
/// "Copy diagnostics". Everything goes through the same redaction every server
/// already applies to its own log, so a secret that leaks into any field is
/// caught even if that field forgot to redact itself.
@MainActor
public enum DiagnosticBundle {
    /// The bundle, ready for the pasteboard. No file is written.
    public static func build(model: AppModel) -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        var out: [String] = []
        out.append("Bud diagnostics — \(Date().formatted(date: .abbreviated, time: .shortened))")
        out.append("")
        out.append(
            "Deliberately omitted: API keys, environment-variable and header values, "
            + "provider base URLs, and anything else a server declares as a secret. "
            + "Shown: the app and macOS version, the provider and model names, and each "
            + "server's name, transport, connection state, command line or URL, and tool counts."
        )
        out.append("")
        out.append("App")
        out.append("  version:  \(appVersion) (\(build))")
        out.append("  macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("  provider: \(model.config.activeProvider.name)")
        out.append("  model:    \(model.config.model)")
        out.append("")
        out.append("MCP servers (\(model.mcp.servers.count))")

        let servers = model.mcp.servers
        if servers.isEmpty {
            out.append("  (none)")
        } else {
            for config in servers {
                let status = model.mcp.statuses[config.id]
                let health = ServerHealth.derive(
                    state: status?.state ?? .stopped,
                    enabled: config.enabled,
                    error: status?.error
                )
                let sent = model.mcp.serverTools(id: config.id).count
                let discovered = model.mcp.discoveredTools(id: config.id).count
                let summary = config.summary.isEmpty ? "No command or URL yet." : config.summary
                let tools = discovered > 0
                    ? "\(sent) of \(discovered) tools"
                    : "\(sent) tools"
                out.append("  \(config.name)  \(config.transport.label)  \(health.label)  \(summary)  \(tools)")
            }
        }

        out.append("")
        out.append("Recent errors")
        var errors: [String] = []
        for config in servers {
            if let error = model.mcp.statuses[config.id]?.error, !error.isEmpty {
                errors.append("  \(config.name): \(error)")
            }
        }
        if let lastError = model.runtime.lastError, !lastError.isEmpty {
            errors.append("  app: \(lastError)")
        }
        // The banner the user is looking at right now is the single most useful
        // error a support request can carry, and the reason the scrub below has
        // to run over provider keys rather than only over what servers declare.
        if let visible = model.errorMessage, !visible.isEmpty {
            errors.append("  panel: \(visible)")
        }
        out.append(contentsOf: errors.isEmpty ? ["  None."] : errors)

        var text = out.joined(separator: "\n")
        // Last stop before the pasteboard: every server's declared secrets are
        // scrubbed from the whole bundle, not just the fields written for it.
        // The clipboard is where text leaves the app.
        for config in servers {
            text = config.redacting(text)
        }
        // Provider keys travel the same road: a rejected key is exactly the
        // error a bundle carries, and exactly the value it must not.
        for value in model.config.providerKeys.values where value.count >= 4 {
            text = text.replacingOccurrences(of: value, with: "[redacted \(model.config.provider) key]")
        }
        let glama = model.config.glamaAPIKey
        if glama.count >= 4 {
            text = text.replacingOccurrences(of: glama, with: "[redacted marketplace key]")
        }
        return text
    }
}

// MARK: - Context budget

/// The breakdown Settings › General shows for what the next request will carry.
///
/// Rows are measured, not estimated, wherever the request is: the tool figures
/// come from serialising the same definitions the request sends, and the prompt
/// and skill figures come from the same strings `ContextCompiler.compile`
/// assembles. Only the token figures are estimated — 4 characters per token, the
/// same deliberately-crude figure `RequestCost` uses to rank rather than bill.
public struct ContextBudget: Sendable {
    public struct Row: Sendable, Identifiable {
        public let label: String
        public let detail: String?
        public let chars: Int
        public let estimatedTokens: Int
        /// Share of the whole, 0…1.
        public let share: Double
        public var id: String { label }

        public init(label: String, chars: Int, share: Double, detail: String? = nil) {
            self.label = label
            self.chars = chars
            self.estimatedTokens = chars / 4
            self.share = share
            self.detail = detail
        }
    }

    public let rows: [Row]
    public let totalChars: Int
    public let estimatedTokens: Int

    /// Measures the next request's prefix plus the conversation it would carry.
    ///
    /// Where each figure comes from, so a reader can verify rather than trust:
    /// - system prompt: `config.systemPrompt` — what `systemMessage()` leads with.
    /// - live context: the time/model/effort lines `systemMessage()` appends.
    /// - memory notes: `BudStore.lessonContext`, ranked against the conversation
    ///   tail exactly as the runtime ranks it.
    /// - skill catalogue: `SkillContext.catalogue(query:)` for the latest user
    ///   message — the same query the runtime passes.
    /// - tool schemas: `env.registry.descriptors().filter { !$0.agentOnly }`,
    ///   filtered exactly as a request is, so delegated servers are absent.
    /// - history: `runtime.historyCharacterCount` — the model-facing conversation
    ///   before the budget trims it.
    @MainActor
    public static func measure(model: AppModel) async -> ContextBudget {
        let config = model.config
        let tools = await model.env.registry.descriptors().filter { !$0.agentOnly }
        let latestUser = model.runtime.modelHistory.last { $0.role == .user }?.content ?? ""
        let notes = BudStore.lessonContext(
            ContextCompiler.conversationTail(of: model.runtime.modelHistory)
        )
        let skills = SkillContext.catalogue(query: latestUser).text
        let cost = RequestMeasurer.measure(
            config: config,
            tools: tools,
            notes: notes,
            liveContext: liveContext(config: config),
            skills: skills
        )

        let history = model.runtime.historyCharacterCount
        let rows = [
            Row(label: "System prompt", chars: cost.systemChars, share: 0),
            Row(label: "Live context", chars: cost.liveContextChars, share: 0),
            Row(
                label: "Memory notes",
                chars: cost.notesChars,
                share: 0,
                detail: cost.notesChars == 0 ? "nothing remembered yet" : nil
            ),
            Row(label: "Skill catalogue", chars: cost.skillChars, share: 0),
            Row(label: "Tool schemas", chars: cost.toolChars, share: 0, detail: "\(cost.toolCount) tools"),
            Row(label: "Conversation history", chars: history, share: 0),
        ]
        let total = rows.reduce(0) { $0 + $1.chars }
        // Shares are of the whole shown, so the six rows add up to the total line.
        let withShares = rows.map { row in
            Row(
                label: row.label,
                chars: row.chars,
                share: total > 0 ? Double(row.chars) / Double(total) : 0,
                detail: row.detail
            )
        }
        return ContextBudget(rows: withShares, totalChars: total, estimatedTokens: total / 4)
    }

    /// The trailing lines the runtime appends to the system prompt — time, model,
    /// reasoning effort. Mirrors `ContextCompiler.compile`; the character
    /// count is order-independent, so where the "Current time" line sits does not
    /// change this figure.
    private static func liveContext(config: BudConfig) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        var text = "\n\nCurrent time: \(stamp.string(from: Date()))."
        text += "\nDefault model for this session: \(config.model)."
        if let effort = config.reasoningEffort { text += " Reasoning effort: \(effort)." }
        return text
    }
}
