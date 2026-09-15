import AppKit
import Foundation
import SwiftUI

/// The settings surface: a glass tab rail plus one panel per `SettingsTab`.
///
/// The selected tab lives on `AppModel`, not in local state, so a slash command
/// in the composer or the marketplace's "switch to Connections" button can
/// navigate here and this view can never disagree with the model.
public struct SettingsView: View {
    private let model: AppModel
    private let initialTab: SettingsTab

    public init(model: AppModel, initialTab: SettingsTab) {
        self.model = model
        self.initialTab = initialTab
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            tabRail
            Divider().overlay(Color.white.opacity(0.10))
            panel
        }
        .onAppear { model.settingsTab = initialTab }
        .onDisappear { model.persistConfig() }
    }

    // MARK: - Rail

    private var tabRail: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    railButton(tab)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Bud.Space.md)
        .frame(width: 184)
    }

    private func railButton(_ tab: SettingsTab) -> some View {
        let isSelected = model.settingsTab == tab
        return Button {
            model.settingsTab = tab
        } label: {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(tab.label)
                    .font(Bud.Font.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Bud.Space.sm)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .glassEffect(
            isSelected
                ? .regular.tint(Bud.Palette.accent.opacity(0.4)).interactive()
                : .identity,
            in: .rect(cornerRadius: Bud.Radius.control)
        )
    }

    // MARK: - Panel

    @ViewBuilder
    private var panel: some View {
        switch model.settingsTab {
        case .general:
            GeneralSettingsTab(model: model)
        case .mcp:
            MCPSettingsView(
                mcp: model.mcp,
                onBrowseMarketplace: { model.openSettings(tab: .marketplace) }
            )
        case .marketplace:
            MarketplaceView(store: model.marketplace, mcp: model.mcp, model: model)
        case .subagents:
            SubagentPanel(supervisor: model.subagents, model: model)
        case .tools:
            ToolBrowserView(model: model)
        case .about:
            AboutTab(model: model)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let model: AppModel

    @BudState private var probe: Probe = .idle
    @BudState private var ompLine = "checking…"
    @BudState private var environmentLine = "checking…"

    private static let presetModels = ["deepseek-v4-flash", "deepseek-v4-pro"]
    private static let knownEfforts = ["low", "medium", "high", "max"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bud.Space.lg) {
                credentialsSection
                endpointSection
                modelSection
                limitsSection
                promptSection
            }
            .padding(.trailing, Bud.Space.xs)
        }
        .task {
            // Read the fallback sources once: they are disk and environment
            // probes, and a form re-renders on every keystroke.
            if let role = BudConfigLoader.readOMPModelRole() {
                let effort = role.effort.map { " · effort \($0)" } ?? ""
                ompLine = "\(role.model)\(effort)  (~/.omp/agent/config.yml)"
            } else {
                ompLine = "no modelRoles.default in ~/.omp/agent/config.yml"
            }
            let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            environmentLine = (env?.isEmpty == false)
                ? "DEEPSEEK_API_KEY is set in the launch environment"
                : "DEEPSEEK_API_KEY is not set"
        }
    }

    // MARK: Credentials

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Credentials",
                subtitle: "Kept in ~/.bud/config.json with owner-only permissions.",
                systemImage: "key"
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    Text("DeepSeek API key")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.secondary)
                    SecureField("sk-…", text: apiKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(Bud.Font.mono)
                        .onSubmit { model.persistConfig() }
                    if !model.hasAPIKey {
                        HStack(spacing: Bud.Space.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Bud.Palette.warning)
                            Text("No key yet — requests will fail with HTTP 401.")
                                .font(Bud.Font.caption)
                                .foregroundStyle(Bud.Palette.warning)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        provenanceRow("Resolved from", BudConfigLoader.configURL.path)
                        provenanceRow("DeepSeek key", environmentLine)
                        provenanceRow("oh-my-pi model", ompLine)
                    }
                    .padding(.top, Bud.Space.xs)
                }
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { model.config.apiKey },
            set: { model.config.apiKey = $0 }
        )
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Text(label)
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 116, alignment: .leading)
            Text(value)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Endpoint

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Endpoint", systemImage: "network")
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    TextField("https://api.deepseek.com/v1", text: baseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(Bud.Font.mono)
                        .onSubmit { model.persistConfig() }
                    HStack(spacing: Bud.Space.sm) {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            Label("Test connection", systemImage: "bolt.horizontal")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(probe == .running)
                        probeView
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { model.config.baseURL },
            set: { model.config.baseURL = $0 }
        )
    }

    @ViewBuilder
    private var probeView: some View {
        switch probe {
        case .idle:
            Text("Sends one token to \(model.config.host).")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
        case .running:
            HStack(spacing: Bud.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(Bud.Font.caption).foregroundStyle(.secondary)
            }
        case .ok(let message):
            probeLabel(message, symbol: "checkmark.circle.fill", color: Bud.Palette.success)
        case .failed(let message):
            probeLabel(message, symbol: "exclamationmark.octagon.fill", color: Bud.Palette.danger)
        }
    }

    private func probeLabel(_ message: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Bud.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(message)
                .font(Bud.Font.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A real round trip, not a URL check: the only evidence that a key, base URL
    /// and model name work together is the API accepting a request. One token is
    /// the cheapest possible proof.
    private func testConnection() async {
        probe = .running
        guard !model.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            probe = .failed("No API key to test with.")
            return
        }

        var base = model.config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            probe = .failed("“\(model.config.baseURL)” is not a usable URL.")
            return
        }

        let payload = JSONValue.object([
            "model": .string(model.config.model),
            "messages": .array([.object(["role": "user", "content": "ping"])]),
            "max_tokens": .number(1),
            "stream": .bool(false),
        ])
        guard let body = payload.encodedString().data(using: .utf8) else {
            probe = .failed("Could not encode the probe request.")
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(model.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                probe = .failed("The server did not answer with HTTP.")
                return
            }
            if (200..<300).contains(http.statusCode) {
                probe = .ok("Connected to \(model.config.host) — \(model.config.model) answered in \(elapsed) ms.")
            } else {
                probe = .failed("HTTP \(http.statusCode): \(Self.errorSnippet(from: data))")
            }
        } catch {
            probe = .failed(error.localizedDescription)
        }
    }

    /// DeepSeek reports failures as `{"error":{"message":…}}`; showing that
    /// sentence beats showing a raw body or a generic status code.
    private static func errorSnippet(from data: Data) -> String {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let message = value["error"]?["message"]?.stringValue, !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "no response body" }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Model", systemImage: "cpu")
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.md) {
                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        Text("Preset")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                        Picker("Preset", selection: modelPresetBinding) {
                            Text("Flash · fast").tag("deepseek-v4-flash")
                            Text("Pro · strong").tag("deepseek-v4-pro")
                            if !Self.presetModels.contains(model.config.model) {
                                Text("Custom").tag(model.config.model)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        Text("Model ID")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                        TextField("deepseek-v4-flash", text: modelIDBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(Bud.Font.mono)
                            .onSubmit { model.persistConfig() }
                        Text("Sent verbatim to the API. Unknown names are served as flash.")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        Text("Reasoning effort")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                        Picker("Reasoning effort", selection: effortBinding) {
                            Text("None").tag(String?.none)
                            ForEach(effortOptions, id: \.self) { effort in
                                Text(effort.capitalized).tag(String?.some(effort))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        Toggle("Override temperature", isOn: temperatureEnabledBinding)
                            .toggleStyle(.switch)
                        if let temperature = model.config.temperature {
                            HStack(spacing: Bud.Space.sm) {
                                Slider(
                                    value: temperatureBinding,
                                    in: 0...1.5,
                                    step: 0.05,
                                    onEditingChanged: { editing in
                                        if !editing { model.persistConfig() }
                                    }
                                )
                                Text(String(format: "%.2f", temperature))
                                    .font(Bud.Font.mono)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        } else {
                            Text("DeepSeek's own default applies.")
                                .font(Bud.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var modelPresetBinding: Binding<String> {
        Binding(
            get: { model.config.model },
            set: { newValue in
                guard newValue != model.config.model else { return }
                model.setModel(newValue)
            }
        )
    }

    private var modelIDBinding: Binding<String> {
        Binding(
            get: { model.config.model },
            set: { model.config.model = $0 }
        )
    }

    /// The picker must always have a valid selection, so an effort that came from
    /// oh-my-pi and is not one of ours is appended rather than silently dropped.
    private var effortOptions: [String] {
        var options = Self.knownEfforts
        if let current = model.config.reasoningEffort, !options.contains(current) {
            options.append(current)
        }
        return options
    }

    private var effortBinding: Binding<String?> {
        Binding(
            get: { model.config.reasoningEffort },
            set: { newValue in
                model.config.reasoningEffort = newValue
                model.persistConfig()
            }
        )
    }

    private var temperatureEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.config.temperature != nil },
            set: { enabled in
                model.config.temperature = enabled ? 1.0 : nil
                model.persistConfig()
            }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { model.config.temperature ?? 1.0 },
            set: { model.config.temperature = $0 }
        )
    }

    // MARK: Limits

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Limits", systemImage: "gauge.with.dots.needle.33percent")
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    Stepper(value: maxToolRoundsBinding, in: 1...64) {
                        limitRow("Tool rounds per turn", "\(model.config.maxToolRounds)")
                    }
                    Stepper(value: subagentConcurrencyBinding, in: 1...32) {
                        limitRow("Subagents in parallel", "\(model.config.allowParallelSubagents)")
                    }
                    Text("Tool rounds cap how many times the model may call tools before it must answer. Parallel subagents bound how many slices run at once.")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func limitRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: Bud.Space.sm) {
            Text(title).font(Bud.Font.callout)
            Spacer(minLength: Bud.Space.sm)
            Text(value).font(Bud.Font.mono).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var maxToolRoundsBinding: Binding<Int> {
        Binding(
            get: { model.config.maxToolRounds },
            set: { newValue in
                model.config.maxToolRounds = newValue
                model.persistConfig()
            }
        )
    }

    private var subagentConcurrencyBinding: Binding<Int> {
        Binding(
            get: { model.config.allowParallelSubagents },
            set: { newValue in
                model.config.allowParallelSubagents = newValue
                model.persistConfig()
            }
        )
    }

    // MARK: System prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader("System prompt", systemImage: "text.alignleft")
                Spacer(minLength: Bud.Space.sm)
                Button("Restore default") {
                    model.config.systemPrompt = BudConfig.defaultSystemPrompt
                    model.persistConfig()
                }
                .buttonStyle(.plain)
                .font(Bud.Font.caption)
                .foregroundStyle(Bud.Palette.accent)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    TextEditor(text: systemPromptBinding)
                        .font(Bud.Font.mono)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .padding(Bud.Space.xs)
                        .background {
                            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                                .fill(Color.black.opacity(0.18))
                        }
                    Text("Sent as the first message of every request. Saved when you leave Settings.")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { model.config.systemPrompt },
            set: { model.config.systemPrompt = $0 }
        )
    }

    private enum Probe: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }
}

// MARK: - About

private struct AboutTab: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bud.Space.lg) {
                masthead
                stats
                sourceCard
                architectureCard
            }
            .padding(.trailing, Bud.Space.xs)
        }
    }

    private var masthead: some View {
        HStack(spacing: Bud.Space.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Bud.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bud")
                    .font(.system(size: 20, weight: .semibold))
                Text("Version \(Self.version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var stats: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                statRow("Model", model.config.model)
                statRow("Endpoint", model.config.host)
                statRow("Tools", "\(model.availableTools.count) across \(providerCount) provider\(providerCount == 1 ? "" : "s")")
                statRow("MCP servers", "\(model.readyServerCount) of \(model.mcp.servers.count) connected")
                statRow("Subagents", model.runningSubagentCount == 0
                    ? "\(model.subagents.runs.count) run\(model.subagents.runs.count == 1 ? "" : "s")"
                    : "\(model.runningSubagentCount) working")
                statRow("Usage", model.usageSummary)
            }
        }
    }

    private var providerCount: Int {
        Set(model.availableTools.map(\.providerID)).count
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Text(label)
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(Bud.Font.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// There is no canonical remote for a local checkout, so the honest answer to
    /// "where does this come from" is the tree the binary was compiled in.
    private var sourceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                SectionHeader("Source", subtitle: "The tree this build was compiled from.", systemImage: "shippingbox")
                Text(Self.sourceRoot?.path ?? "Unknown — build path unavailable.")
                    .font(Bud.Font.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: Bud.Space.sm) {
                    Button("Reveal in Finder") {
                        if let root = Self.sourceRoot {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(Self.sourceRoot == nil)
                    Button("Open config folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([BudConfigLoader.budDirectory])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var architectureCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                SectionHeader("How it is put together", systemImage: "point.3.filled.connected.trianglepath.dotted")
                explainer(
                    "Panel",
                    "A single Liquid Glass window. The transcript, composer and settings are all the same glass surface, so nothing floats inside anything else."
                )
                explainer(
                    "Turn",
                    "AppModel hands your message to AgentRuntime, which streams from DeepSeek, executes tool calls, and appends each result to the transcript as it arrives."
                )
                explainer(
                    "Tools",
                    "ToolRegistry aggregates four providers: native local tools, connected MCP servers, the subagent supervisor, and the generative-UI renderer. Names collide safely because every MCP tool is namespaced mcp__<server>__<tool>."
                )
                explainer(
                    "MCP",
                    "Servers are JSON-RPC 2.0 peers over stdio, streamable HTTP, or SSE. The marketplace reads registry.modelcontextprotocol.io and installs a server with one click."
                )
                explainer(
                    "Subagents",
                    "Independent slices run concurrently in fresh contexts on the same transport, each with its own tool budget, and report back into the turn that spawned them."
                )
            }
        }
    }

    private func explainer(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Bud.Font.caption)
                .foregroundStyle(Bud.Palette.accent)
            Text(body)
                .font(Bud.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let version: String = {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "1.0 (dev)"
    }()

    private static let sourceRoot: URL? = {
        // …/Sources/Bud/UI/SettingsView.swift -> the repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }()
}
