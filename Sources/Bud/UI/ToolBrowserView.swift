import SwiftUI

/// Browses every tool the model can currently call, grouped by the provider that
/// declared it.
///
/// The schema is shown as raw JSON rather than a prettified summary: that object
/// is byte-for-byte what the model receives, so a summarised view would hide the
/// exact contract the user is here to inspect.
public struct ToolBrowserView: View {
    private let model: AppModel

    @BudState private var query = ""
    @BudState private var expanded: Set<String> = []
    @BudState private var isRefreshing = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            controls
            if model.availableTools.isEmpty {
                EmptyStateView(
                    systemImage: "puzzlepiece.extension",
                    title: "No tools available",
                    message: "Connect an MCP server in Settings › MCP, or install one from the marketplace."
                )
            } else if groups.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No tool matches “\(query)”."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Bud.Space.lg) {
                        ForEach(groups) { group in
                            providerSection(group)
                        }
                    }
                }
            }
        }
        .task { await model.refreshTools() }
    }

    // MARK: - Header

    private var controls: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader(
                    "Tools",
                    subtitle: summaryLine,
                    systemImage: "wrench.and.screwdriver"
                )
                Spacer(minLength: Bud.Space.sm)
                if isRefreshing {
                    ProgressView().controlSize(.small)
                }
                GlassIconButton(systemImage: "arrow.clockwise", help: "Re-scan every provider") {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await model.refreshTools()
                        isRefreshing = false
                    }
                }
            }

            HStack(spacing: Bud.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(Bud.Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                TextField("Filter by name or description", text: $query)
                    .textFieldStyle(.plain)
                    .font(Bud.Font.callout)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Bud.Font.caption.weight(.regular))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Bud.Space.sm)
            .padding(.vertical, Bud.Space.snug)
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                    }
            }
        }
    }

    private var summaryLine: String {
        let total = model.availableTools.count
        let providers = groups.count
        if total == 0 { return "No providers registered" }
        let noun = total == 1 ? "tool" : "tools"
        let providerNoun = providers == 1 ? "provider" : "providers"
        return "\(total) \(noun) across \(providers) \(providerNoun)"
    }

    // MARK: - Content

    private func providerSection(_ group: ToolGroup) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader(group.title, subtitle: group.subtitle)
                Spacer(minLength: Bud.Space.xs)
                GlassChip(
                    "\(group.tools.count)",
                    systemImage: "wrench.and.screwdriver",
                    isActive: true
                )
            }
            VStack(spacing: Bud.Space.xs) {
                ForEach(group.tools) { tool in
                    ToolRow(
                        tool: tool,
                        isExpanded: expanded.contains(tool.id),
                        toggle: { toggle(tool.id) }
                    )
                }
            }
        }
    }

    // MARK: - Grouping

    private struct ToolGroup: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var tools: [ToolDescriptor]
    }

    /// Grouped by provider *display* name so the user sees "MCP · github", not the
    /// internal provider id. Groups keep the registry's declaration order, which
    /// the registry already sorts natively before MCP servers.
    private var groups: [ToolGroup] {
        let matching = model.availableTools.filter { tool in
            guard !query.isEmpty else { return true }
            let needle = query.lowercased()
            return tool.name.lowercased().contains(needle)
                || tool.description.lowercased().contains(needle)
        }
        var order: [String] = []
        var buckets: [String: [ToolDescriptor]] = [:]
        for tool in matching {
            if buckets[tool.providerID] == nil {
                buckets[tool.providerID] = []
                order.append(tool.providerID)
            }
            buckets[tool.providerID]?.append(tool)
        }
        return order.compactMap { pid in
            guard let tools = buckets[pid], let first = tools.first else { return nil }
            return ToolGroup(
                id: pid,
                title: first.providerName,
                subtitle: pid,
                tools: tools
            )
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

// MARK: - Row

private struct ToolRow: View {
    let tool: ToolDescriptor
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        GlassCard(cornerRadius: Bud.Radius.control, padding: Bud.Space.sm) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                Button(action: toggle) {
                    HStack(alignment: .top, spacing: Bud.Space.sm) {
                        Image(systemName: "chevron.right")
                            .font(Bud.Font.micro.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .padding(.top, Bud.Space.xs)
                        VStack(alignment: .leading, spacing: Bud.Space.xs) {
                            Text(tool.name)
                                .font(Bud.Font.mono)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(Bud.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(isExpanded ? nil : 2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(tool.schema.encodedString(pretty: true))
                        .font(Bud.Font.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Bud.Space.sm)
                        .background {
                            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                                .fill(Color.black.opacity(0.18))
                        }
                }
            }
        }
        .animation(.snappy(duration: 0.16), value: isExpanded)
    }
}
