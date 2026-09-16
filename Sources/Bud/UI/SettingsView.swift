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
        GlassEffectContainer(spacing: Bud.Space.snug) {
            VStack(alignment: .leading, spacing: Bud.Space.snug) {
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
                    .font(Bud.Font.callout.weight(.medium))
                    .frame(width: 16)
                Text(tab.label)
                    .font(Bud.Font.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Bud.Space.sm)
            .padding(.vertical, Bud.Space.sm)
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

    /// Every pane gets its margin here rather than supplying its own.
    ///
    /// Two of the six did and four did not, so most panes sat flush against the
    /// rail while the leftover width collected on the right — 40pt of it in
    /// General, 127pt in Connections. A margin that each pane is individually
    /// responsible for is a margin that most panes will not have, and the four
    /// that forgot were not distinguishable from the two that remembered until
    /// they were measured.
    private var panel: some View {
        Group {
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
        .padding(Bud.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let model: AppModel

    @BudState private var probe: Probe = .idle
    @BudState private var ompLine = "checking…"

    private static let knownEfforts = ["low", "medium", "high", "max"]
    private static let glamaKeysURLString = "https://glama.ai/settings/api-keys"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bud.Space.lg) {
                providerSection
                credentialsSection
                glamaSection
                endpointSection
                modelSection
                limitsSection
                promptSection
            }
            // Cap the measure. A text field stretched across the whole pane is
            // hard to scan, and a label stops reading as paired with its value
            // once the two are most of a screen apart.
            // Capped for readability, then centred. Left-aligning the capped
            // column pushed every spare point to the right of it, so the pane
            // read as 35pt of margin on one side and 40 on the other — the two
            // numbers a person notices without being able to say why.
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
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
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Provider",
                subtitle: "Anything speaking the OpenAI, Anthropic or Google dialect.",
                systemImage: "cpu"
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    Picker("Provider", selection: providerBinding) {
                        ForEach(ProviderRegistry.groups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.providers) { descriptor in
                                    Text(descriptor.name).tag(descriptor.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()

                    if model.config.activeProvider.regions.count > 1 {
                        HStack(spacing: Bud.Space.sm) {
                            Text("Region")
                                .font(Bud.Font.caption)
                                .foregroundStyle(.secondary)
                            Picker("Region", selection: regionBinding) {
                                ForEach(model.config.activeProvider.regions, id: \.self) { region in
                                    Text(region).tag(region)
                                }
                            }
                            .labelsHidden()
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: Bud.Space.sm) {
                        GlassChip(
                            model.config.activeProvider.wireFormat.label,
                            systemImage: "arrow.left.arrow.right"
                        )
                        if let saved = model.config.providerKeys[model.config.provider], !saved.isEmpty {
                            GlassChip("Key saved", systemImage: "key.fill", tint: Bud.Palette.success, isActive: true)
                        } else if let source = environmentVariableName(for: model.config.activeProvider) {
                            GlassChip("Using $\(source)", systemImage: "terminal", tint: Bud.Palette.warning, isActive: true)
                        }
                        Spacer(minLength: 0)
                        if let doc = model.config.activeProvider.docURL, let url = URL(string: doc) {
                            Button("Docs") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link)
                                .font(Bud.Font.caption)
                        }
                    }

                    if let note = model.config.activeProvider.note {
                        Text(note)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { model.config.provider },
            set: { newValue in
                guard newValue != model.config.provider else { return }
                model.config.provider = newValue
                // The model is stored per provider, so switching lands on that
                // provider's own last choice — or its suggested default — rather
                // than carrying a model id the new API has never heard of.
                model.persistConfig()
            }
        )
    }

    /// The region, defaulting to the provider's first so the popup never shows
    /// blank. Storing the default explicitly would be harmless but noise: an
    /// empty region already resolves to the same endpoint.
    private var regionBinding: Binding<String> {
        Binding(
            get: {
                let stored = model.config.region
                if !stored.isEmpty { return stored }
                return model.config.activeProvider.regions.first ?? ""
            },
            set: { newValue in
                guard newValue != model.config.region else { return }
                model.config.region = newValue
                model.persistConfig()
            }
        )
    }

    /// The variable a key is being read from, when it is not stored in Bud.
    ///
    /// Shown because "I already exported this" and "Bud cannot see it" look
    /// identical otherwise — the difference is whether the app was launched from
    /// Finder, which inherits no shell environment.
    private func environmentVariableName(for provider: ProviderDescriptor) -> String? {
        for variable in provider.envKeys where !BudConfigLoader.resolveKey(named: variable).isEmpty {
            return variable
        }
        return nil
    }

    /// Where the active provider's key is coming from — or that there is none.
    ///
    /// Worth showing explicitly: a key exported in a shell profile and a key Bud
    /// cannot see look identical from the outside, and the difference matters
    /// because an app launched from Finder inherits no shell environment.
    private func environmentLine(for provider: ProviderDescriptor) -> String {
        if provider.envKeys.isEmpty { return "no key needed" }
        if model.config.resolvedKey(for: provider).isEmpty {
            return "not set — add a key above"
        }
        if let variable = environmentVariableName(for: provider) {
            return "\(variable) (environment or shell profile)"
        }
        return "saved in Bud"
    }

    // MARK: Credentials

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "\(model.config.activeProvider.name) credentials",
                subtitle: "Kept in ~/.bud/config.json with owner-only permissions.",
                systemImage: "key"
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    if model.config.activeProvider.requiresKey {
                        Text("API key")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Paste the key for \(model.config.activeProvider.name)", text: apiKeyBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(Bud.Font.mono)
                            .onSubmit { model.persistConfig() }
                        if model.config.activeProviderNeedsKey {
                            HStack(spacing: Bud.Space.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(Bud.Font.micro.weight(.regular))
                                    .foregroundStyle(Bud.Palette.warning)
                                Text("No key yet — requests will fail with HTTP 401.")
                                    .font(Bud.Font.caption)
                                    .foregroundStyle(Bud.Palette.warning)
                            }
                        }
                    } else {
                        HStack(spacing: Bud.Space.xs) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(Bud.Font.micro.weight(.regular))
                                .foregroundStyle(Bud.Palette.success)
                            Text("\(model.config.activeProvider.name) runs on this Mac and needs no key.")
                                .font(Bud.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                        provenanceRow("Resolved from", BudConfigLoader.configURL.path)
                        if !model.config.activeProvider.envKeys.isEmpty {
                            provenanceRow(
                                model.config.activeProvider.name,
                                environmentLine(for: model.config.activeProvider)
                            )
                        }
                        provenanceRow("oh-my-pi model", ompLine)
                    }
                    .padding(.top, Bud.Space.xs)
                }
            }
        }
    }

    // MARK: Glama

    /// Glama's key, alongside the DeepSeek one rather than on the marketplace
    /// pane: a pane that browses is not where a credential is configured, and the
    /// licence notice that makes the pane work belongs next to the field that
    /// unlocks it.
    private var glamaSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Glama marketplace",
                subtitle: "Required to browse Glama in Settings → Marketplace.",
                systemImage: "square.grid.2x2"
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    Text("Glama API key")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.secondary)
                    SecureField("glm_…", text: glamaKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(Bud.Font.mono)
                        // Committed on submit, never per keystroke: the config file
                        // is rewritten whole, and a half-typed credential should
                        // not be what lands on disk.
                        .onSubmit { model.persistConfig() }
                    HStack(spacing: Bud.Space.sm) {
                        Button {
                            if let url = URL(string: Self.glamaKeysURLString) {
                                _ = NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Create a key at glama.ai", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    Text("Glama's API Data License requires Bud to credit Glama on every view that shows its data and to link each record back to its Glama listing. The marketplace pane does both; that is the price of the catalogue, not a setting.")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                        provenanceRow(
                            "Glama key",
                            model.config.glamaAPIKey.isEmpty
                                ? "not set — the marketplace will prompt for one"
                                : "set"
                        )
                    }
                    .padding(.top, Bud.Space.xs)
                }
            }
        }
    }

    private var glamaKeyBinding: Binding<String> {
        Binding(
            get: { model.config.glamaAPIKey },
            set: { model.config.glamaAPIKey = $0 }
        )
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
                    TextField(
                        model.config.baseURL.isEmpty
                            ? "https://your-endpoint/v1"
                            : model.config.baseURL,
                        text: baseURLBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(Bud.Font.mono)
                    .onSubmit { model.persistConfig() }
                    if model.config.customProviderNeedsBaseURL {
                        HStack(spacing: Bud.Space.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(Bud.Font.micro.weight(.regular))
                                .foregroundStyle(Bud.Palette.warning)
                            Text("The custom provider needs a base URL before it can be used.")
                                .font(Bud.Font.caption)
                                .foregroundStyle(Bud.Palette.warning)
                        }
                    }
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
                .font(Bud.Font.micro.weight(.semibold))
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
    ///
    /// Sent through the provider's actual backend rather than a hand-rolled
    /// request. A hand-rolled probe can only ever confirm the dialect it was
    /// written for — it would report success or failure for the wrong reasons on
    /// the other two, which is worse than not testing at all.
    private func testConnection() async {
        probe = .running

        let provider = model.config.activeProvider
        if provider.requiresKey, model.config.resolvedKey(for: provider).isEmpty {
            probe = .failed("No key for \(provider.name) to test with.")
            return
        }
        if model.config.customProviderNeedsBaseURL {
            probe = .failed("The custom provider needs a base URL first.")
            return
        }
        if model.config.model.isEmpty {
            probe = .failed("No model set for \(provider.name).")
            return
        }

        let backend = ProviderBackendFactory.make(
            provider: provider,
            credentials: model.config.activeCredentials
        )
        let request = ChatRequest(
            model: model.config.model,
            messages: [ChatMessage(role: .user, content: "ping")],
            maxTokens: 1
        )

        let started = Date()
        do {
            var sawAnything = false
            for try await event in backend.stream(request) {
                // Any event at all means the request was accepted and parsed —
                // a one-token reply may contain only a finish or a usage frame.
                switch event {
                case .contentDelta, .reasoningDelta, .finish, .usage, .toolCallDelta:
                    sawAnything = true
                }
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            probe = sawAnything
                ? .ok("\(provider.name) answered in \(elapsed) ms using \(model.config.model).")
                : .failed("\(provider.name) accepted the request but sent nothing back.")
        } catch {
            probe = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// DeepSeek reports failures as `{"error":{"message":…}}`; showing that
    /// sentence beats showing a raw body or a generic status code.
    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Model", systemImage: "cpu")
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.md) {
                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        HStack(spacing: Bud.Space.sm) {
                            Text("Model ID")
                                .font(Bud.Font.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            // Replaces the old hard-coded Flash/Pro segmented
                            // control, which only ever made sense for one
                            // provider. This works for all of them.
                            if let suggested = model.config.activeProvider.defaultModel,
                               !suggested.isEmpty,
                               suggested != model.config.model {
                                Button("Use \(suggested)") {
                                    model.config.model = suggested
                                    model.persistConfig()
                                }
                                .buttonStyle(.link)
                                .font(Bud.Font.caption)
                            }
                        }
                        TextField(
                            model.config.activeProvider.defaultModel ?? "model-id",
                            text: modelIDBinding
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(Bud.Font.mono)
                        .onSubmit { model.persistConfig() }
                        Text("Sent verbatim to \(model.config.activeProvider.name).")
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
                UpdateSettingsSection(model: model)
                sourceCard
                architectureCard
            }
            // Capped for readability, then centred. Left-aligning the capped
            // column pushed every spare point to the right of it, so the pane
            // read as 35pt of margin on one side and 40 on the other — the two
            // numbers a person notices without being able to say why.
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private var masthead: some View {
        HStack(spacing: Bud.Space.md) {
            Image(systemName: "sparkles")
                .font(Bud.Font.metric.weight(.light))
                .foregroundStyle(Bud.Palette.accent)
            VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                Text("Bud")
                    .font(Bud.Font.hero)
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
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
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
