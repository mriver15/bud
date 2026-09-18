import AppKit
import SwiftUI

/// Server list and per-server diagnostics for the MCP subsystem.
///
/// Everything here reads `MCPManager` directly — the manager is the single
/// owner of the server set and its connection states, so the view never keeps a
/// parallel copy that could drift from what is actually connected.
public struct MCPSettingsView: View {
    private let mcp: MCPManager
    private let onBrowseMarketplace: (() -> Void)?

    @BudState private var editor: EditorTarget?
    @BudState private var pendingDelete: MCPServerConfig?
    @BudState private var expandedDiagnostics: String?

    public init(mcp: MCPManager, onBrowseMarketplace: (() -> Void)? = nil) {
        self.mcp = mcp
        self.onBrowseMarketplace = onBrowseMarketplace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            header
            if mcp.servers.isEmpty {
                EmptyStateView(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "No MCP servers",
                    message: "Add a local command or a remote endpoint, or install one from the marketplace."
                )
            } else {
                serverList
            }
        }
        .sheet(item: $editor) { target in
            editorSheet(target)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete server?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { config in
            Button("Delete", role: .destructive) { remove(config) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { config in
            Text("Bud forgets \(config.name) and stops offering its tools. Any process or endpoint it points at is left running.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader(
                    "MCP servers",
                    subtitle: summary,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                Spacer(minLength: Bud.Space.sm)
                Button {
                    editor = EditorTarget(config: nil)
                } label: {
                    Label("Add server", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let onBrowseMarketplace {
                    Button {
                        onBrowseMarketplace()
                    } label: {
                        Label("Browse marketplace", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            Text("Tools are exposed to the model as mcp__<server>__<tool>. Disabled servers keep their configuration but offer nothing.")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var summary: String {
        let total = mcp.servers.count
        let ready = mcp.statuses.values.count { $0.state == .ready }
        let tools = mcp.allTools.count
        let noun = tools == 1 ? "tool" : "tools"
        return "\(ready) of \(total) connected · \(tools) \(noun)"
    }

    // MARK: - List

    private var serverList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Bud.Space.sm) {
                ForEach(mcp.servers) { config in
                    ServerRow(
                        config: config,
                        mcp: mcp,
                        isExpanded: expandedDiagnostics == config.id,
                        toggleDiagnostics: {
                            expandedDiagnostics = expandedDiagnostics == config.id ? nil : config.id
                        },
                        onEdit: { editor = EditorTarget(config: config) },
                        onDelete: { pendingDelete = config }
                    )
                }
            }
            .padding(.vertical, Bud.Space.hairline)
        }
    }

    // MARK: - Editing

    @ViewBuilder
    private func editorSheet(_ target: EditorTarget) -> some View {
        ServerEditorView(
            config: target.config,
            mcp: mcp,
            onConnect: { config in
                await prepare(config, isNew: target.isNew)
                await mcp.connect(id: config.id)
            },
            onSave: { config in
                Task { await prepare(config, isNew: target.isNew) }
            },
            onCancel: { editor = nil }
        )
    }

    private func prepare(_ config: MCPServerConfig, isNew: Bool) async {
        if isNew {
            await mcp.addServer(config)
        } else {
            await mcp.updateServer(config)
        }
    }

    private func remove(_ config: MCPServerConfig) {
        pendingDelete = nil
        if expandedDiagnostics == config.id { expandedDiagnostics = nil }
        Task { await mcp.removeServer(id: config.id) }
    }

    private struct EditorTarget: Identifiable {
        let config: MCPServerConfig?
        var id: String { config?.id ?? "new" }
        var isNew: Bool { config == nil }
    }
}

// MARK: - Row

private struct ServerRow: View {
    let config: MCPServerConfig
    let mcp: MCPManager
    let isExpanded: Bool
    let toggleDiagnostics: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var status: MCPServerStatus? { mcp.statuses[config.id] }
    private var state: MCPConnectionState { status?.state ?? .stopped }
    private var isLive: Bool { state == .ready || state == .connecting }

    var body: some View {
        GlassCard(cornerRadius: Bud.Radius.card, padding: Bud.Space.md) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                identityLine
                Text(config.summary.isEmpty ? "No command or URL yet." : config.summary)
                    .font(Bud.Font.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                stateLine
                actionLine
                if isExpanded { DiagnosticsPanel(config: config, mcp: mcp) }
            }
        }
    }

    private var identityLine: some View {
        HStack(spacing: Bud.Space.sm) {
            StateDot(color: dotColor, pulsing: state == .connecting)
            Text(config.name)
                .font(Bud.Font.body)
                .fontWeight(.medium)
            GlassChip(config.transport.label, systemImage: config.transport.symbol)
            if config.registryName != nil {
                GlassChip("marketplace", systemImage: "square.grid.2x2", tint: Color.secondary)
            }
            Spacer(minLength: Bud.Space.xs)
            Toggle("Enabled", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(config.enabled ? "Disconnect and stop offering this server's tools" : "Enable and connect this server")
        }
    }

    private var stateLine: some View {
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
            HStack(spacing: Bud.Space.sm) {
                Text(state.label)
                    .font(Bud.Font.caption)
                    .foregroundStyle(state == .failed ? Bud.Palette.danger : Color.secondary)
                if state == .ready {
                    Text(toolCountLabel)
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                if let version = status?.serverVersion, !version.isEmpty {
                    Text("v\(version)")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if let error = status?.error, !error.isEmpty {
                Text(error)
                    .font(Bud.Font.caption)
                    .foregroundStyle(Bud.Palette.danger)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var actionLine: some View {
        HStack(spacing: Bud.Space.md) {
            rowButton(isLive ? "Disconnect" : "Connect",
                      symbol: isLive ? "stop.circle" : "play.circle") {
                Task {
                    if isLive {
                        await mcp.disconnect(id: config.id)
                    } else {
                        await mcp.connect(id: config.id)
                    }
                }
            }
            rowButton("Restart", symbol: "arrow.clockwise") {
                Task { await mcp.restart(id: config.id) }
            }
            rowButton("Edit", symbol: "slider.horizontal.3", action: onEdit)
            rowButton("Delete", symbol: "trash", tint: Bud.Palette.danger, action: onDelete)
            Spacer(minLength: 0)
            Button(action: toggleDiagnostics) {
                HStack(spacing: Bud.Space.xs) {
                    Text(isExpanded ? "Hide tools" : "Tools & log")
                        .font(Bud.Font.caption)
                    Image(systemName: "chevron.right")
                        .font(Bud.Font.micro.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func rowButton(
        _ title: String,
        symbol: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Bud.Space.xs) {
                Image(systemName: symbol).font(Bud.Font.micro.weight(.semibold))
                Text(title).font(Bud.Font.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.enabled },
            set: { newValue in
                var updated = config
                updated.enabled = newValue
                Task {
                    await mcp.updateServer(updated)
                    if newValue {
                        await mcp.connect(id: updated.id)
                    } else {
                        await mcp.disconnect(id: updated.id)
                    }
                }
            }
        )
    }

    /// Sent over discovered, when they differ. "25 tools" and "5 of 25 tools"
    /// are different facts about what a request costs, and only the second one
    /// explains the number `--measure` reports.
    private var toolCountLabel: String {
        let discovered = max(mcp.discoveredTools(id: config.id).count, status?.toolCount ?? 0)
        guard discovered > 0 else { return "" }
        let sent = mcp.serverTools(id: config.id).count
        if sent == discovered { return "\(discovered) \(discovered == 1 ? "tool" : "tools")" }
        return "\(sent) of \(discovered) tools"
    }

    private var dotColor: Color {
        switch state {
        case .ready: return Bud.Palette.success
        case .connecting: return Bud.Palette.warning
        case .failed: return Bud.Palette.danger
        case .stopped: return Color.secondary.opacity(0.5)
        }
    }
}

// MARK: - Diagnostics

/// The expanded row body: what the server said, what it offers, and the tail of
/// its transport log. `stderr` from a crashed stdio server lands in that log,
/// which is usually the only evidence of *why* a handshake failed.
struct DiagnosticsPanel: View {
    let config: MCPServerConfig
    let mcp: MCPManager

    private var status: MCPServerStatus? { mcp.statuses[config.id] }
    private var logs: [String] { mcp.logs(id: config.id) }
    private var tools: [ToolDescriptor] { mcp.serverTools(id: config.id) }
    private var discovered: [ToolDescriptor] { mcp.discoveredTools(id: config.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            // Tools first, diagnostics second. Choosing what a server may send is
            // configuration and the log is troubleshooting; a picker buried under
            // a "Diagnostics" heading reads as a debugging aid rather than the
            // control that decides what every request costs.
            if !discovered.isEmpty {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    // Actions live beside the heading, as they do for the log
                    // below. Placed after the list they sat directly against a
                    // row cut off by the scroll edge, which read as a collision.
                    HStack(spacing: Bud.Space.sm) {
                        SectionHeader("Tools", subtitle: toolSubtitle)
                        Spacer(minLength: Bud.Space.sm)
                        Button("Send all") { setEnabledTools(nil) }
                            .buttonStyle(.plain)
                            .font(Bud.Font.caption)
                            .foregroundStyle(Bud.Palette.accent)
                        Button("Send none") { setEnabledTools([]) }
                            .buttonStyle(.plain)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    toolList
                    delegationRow
                }
            }

            VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader("Diagnostics", subtitle: logSubtitle)
                Spacer(minLength: Bud.Space.sm)
                Button("Copy") { copyDiagnostics() }
                    .buttonStyle(.plain)
                    .font(Bud.Font.caption)
                    .foregroundStyle(Bud.Palette.accent)
                Button("Clear") { mcp.clearLogs(id: config.id) }
                    .buttonStyle(.plain)
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
                    .disabled(logs.isEmpty)
            }

            if let error = status?.error, !error.isEmpty {
                Text(error)
                    .font(Bud.Font.mono)
                    .foregroundStyle(Bud.Palette.danger)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Bud.Space.sm)
                    .background {
                        RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                            .fill(Bud.Palette.danger.opacity(0.12))
                    }
            }

            if logs.isEmpty {
                Text("No log entries yet. Bud records the handshake, every call, and any stderr the server writes.")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    Text(logs.joined(separator: "\n"))
                        .font(Bud.Font.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Bud.Space.sm)
                }
                .frame(height: 170)
                .defaultScrollAnchor(.bottom)
                .background {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .fill(Color.black.opacity(0.20))
                }
            }
            }
        }
        .padding(.top, Bud.Space.xs)
    }

    /// The figure a person needs to decide whether to keep a server switched on:
    /// how much of it reaches the model, and what that costs per request.
    private var toolSubtitle: String {
        let sent = discovered.filter { config.sends(tool: $0.name) }
        guard !sent.isEmpty else {
            return "Nothing sent — connected, but invisible to the model"
        }
        let sizes = requestSizes
        var cost = 0
        for tool in sent { cost += sizes[tool.name] ?? 0 }
        let amount = "\(BudFormat.count(cost)) characters per request"
        guard sent.count < discovered.count else { return "\(sent.count) tools · \(amount)" }
        return "\(sent.count) of \(discovered.count) sent · \(amount)"
    }

    /// The switch that moves a server's schema off every request.
    ///
    /// Placed under the list rather than in a settings pane of its own, because it
    /// is only worth deciding next to the figure it changes: the line above it says
    /// what these tools cost per request, and this is what stops paying it.
    private var delegationRow: some View {
        let agent = ToolNaming.sanitize(config.name.lowercased())
        let sent = discovered.filter { config.sends(tool: $0.name) }
        let cost = sent.reduce(0) { $0 + (requestSizes[$1.name] ?? 0) }

        return VStack(alignment: .leading, spacing: Bud.Space.xs) {
            Toggle(isOn: delegatedBinding) {
                Text("Hand these tools to the \(agent) agent")
                    .font(Bud.Font.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(
                config.delegated
                    ? """
                      The main agent carries none of these \(sent.count) tools. It reaches them \
                      by delegating to the agent, which keeps the full list — so every question \
                      for this server costs one delegation.
                      """
                    : """
                      Keeps \(BudFormat.count(cost)) characters off every request. In exchange, \
                      reaching this server costs a delegation rather than a direct call — worth \
                      it when its answers are bulky, a loss for a single instant lookup.
                      """
            )
            .font(Bud.Font.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Bud.Space.xs)
    }

    private var delegatedBinding: Binding<Bool> {
        Binding(
            get: { config.delegated },
            set: { newValue in
                var updated = config
                updated.delegated = newValue
                Task { await mcp.updateServer(updated) }
            }
        )
    }

    private var logSubtitle: String {
        logs.isEmpty ? "Nothing recorded yet" : "\(logs.count) entries"
    }

    /// Which of this server's tools are sent, and what each one costs.
    ///
    /// The sizes are the serialised request definitions rather than estimates, so
    /// the figure beside a checkbox is exactly what that checkbox buys back on
    /// every request. A server's tool block is charged whether or not any of it
    /// is used, which is the whole reason this exists.
    private var toolList: some View {
        let sizes = requestSizes

        return VStack(alignment: .leading, spacing: Bud.Space.sm) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discovered) { tool in
                        toolRow(tool, size: sizes[tool.name] ?? 0)
                    }
                }
                .padding(.vertical, Bud.Space.xs)
            }
            .frame(height: 190)
            // A list whose height is not a whole number of rows cuts one in half
            // at the edge. Clipped hard and held clear of the controls below it,
            // that reads as a scroll region; unclipped and touching them, it read
            // as a row colliding with the buttons.
            .clipShape(RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(Color.black.opacity(0.14))
            }
        }
    }

    /// The request definition of every tool, serialised once. Encoding them again
    /// per row per reference is the same work for the layout engine three times
    /// over, on a list that can run to a hundred entries.
    private var requestSizes: [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(discovered.count)
        for tool in discovered {
            out[tool.name] = tool.openAIToolDefinition.encodedString().count
        }
        return out
    }

    private func toolRow(_ tool: ToolDescriptor, size: Int) -> some View {
        let on = config.sends(tool: tool.name)
        return Toggle(isOn: sentBinding(for: tool)) {
            HStack(spacing: Bud.Space.sm) {
                Text(tool.name)
                    .font(Bud.Font.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Bud.Space.sm)
                Text(BudFormat.count(size))
                    .font(Bud.Font.mono)
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
        .toggleStyle(.checkbox)
        .foregroundStyle(on ? Color.primary : Color.secondary.opacity(0.55))
    }

    private func sentBinding(for tool: ToolDescriptor) -> Binding<Bool> {
        Binding(
            get: { config.sends(tool: tool.name) },
            set: { setSent(tool.name, $0) }
        )
    }

    private func setEnabledTools(_ selection: [String]?) {
        let id = config.id
        Task { await mcp.setEnabledTools(selection, for: id) }
    }

    /// Switching the last tool on stores `nil` rather than the full list. The two
    /// mean the same thing today; only `nil` still means it after the server
    /// ships a new tool, because a frozen list would hide it without saying so.
    private func setSent(_ name: String, _ on: Bool) {
        let all = discovered.map(\.name)
        var current = Set(all.filter(config.sends(tool:)))
        if on { current.insert(name) } else { current.remove(name) }
        setEnabledTools(current.count == all.count ? nil : all.filter(current.contains))
    }

    private func copyDiagnostics() {
        var lines: [String] = [
            "server:    \(config.name)",
            "id:        \(config.id)",
            "transport: \(config.transport.label)",
            "target:    \(config.summary)",
            "state:     \(status?.state.label ?? MCPConnectionState.stopped.label)",
            "tools:     \(tools.count) of \(discovered.count) sent",
        ]
        if let version = status?.serverVersion, !version.isEmpty {
            lines.append("version:   \(version)")
        }
        if let error = status?.error, !error.isEmpty {
            lines.append("error:     \(error)")
        }
        lines.append("")
        lines.append(contentsOf: logs.isEmpty ? ["(no log entries)"] : logs)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
