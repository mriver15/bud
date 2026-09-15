import AppKit
import SwiftUI

/// Registry browser: search the public MCP registry and install a server
/// straight into the MCP manager.
///
/// The view owns nothing but its presentation state — the list, the request in
/// flight, and install results all live in `MarketplaceStore` / `MCPManager`, so
/// switching tabs never loses a fetch.
public struct MarketplaceView: View {
    private let store: MarketplaceStore
    private let mcp: MCPManager
    private let model: AppModel

    @BudState private var inspected: RegistryServer?

    public init(store: MarketplaceStore, mcp: MCPManager, model: AppModel) {
        self.store = store
        self.mcp = mcp
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            SectionHeader("MCP Marketplace", subtitle: subtitle, systemImage: "shippingbox")
            searchField
            if let loadError = store.loadError {
                errorBanner(loadError)
            }
            resultsArea
        }
        .padding(Bud.Space.lg)
        .task { await store.loadInitial() }
        .task(id: store.query) { await runSearch() }
        .sheet(item: $inspected) { server in
            RegistryServerInspector(server: server, store: store, mcp: mcp, model: model)
        }
    }

    // MARK: - Pieces

    private var subtitle: String {
        let count = store.totalLoaded
        let servers = count == 1 ? "1 server" : "\(count) servers"
        if store.lastQuery.isEmpty { return "\(servers) loaded from the registry" }
        return "\(servers) matching “\(store.lastQuery)”"
    }

    private var searchField: some View {
        GlassCard(padding: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(
                    "Search the MCP registry",
                    text: Binding(
                        get: { store.query },
                        set: { store.query = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(Bud.Font.body)
                .onSubmit { Task { await store.search(store.query) } }

                if store.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Bud.Palette.warning)
            Text(message)
                .font(Bud.Font.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Bud.Space.xs)
            Button("Retry") { Task { await store.reload() } }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.vertical, Bud.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Bud.Palette.warning.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(Bud.Palette.warning.opacity(0.35), lineWidth: 0.6)
                }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if store.results.isEmpty {
            EmptyStateView(
                systemImage: store.isSearching ? "hourglass" : "shippingbox",
                title: store.isSearching ? "Searching…" : "No servers",
                message: emptyMessage
            )
        } else {
            ScrollView {
                LazyVStack(spacing: Bud.Space.sm) {
                    ForEach(store.results) { server in
                        ServerCard(server: server, isInstalled: store.isInstalled(server)) {
                            inspected = server
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyMessage: String {
        if store.isSearching { return "Querying the MCP registry." }
        if !store.lastQuery.isEmpty {
            return "No registry entry matches “\(store.lastQuery)”. Try a shorter term."
        }
        if store.loadError != nil {
            return "The registry could not be read. Retry above, or check this Mac's network."
        }
        return "The registry returned no servers."
    }

    /// The field is edited per keystroke while the store only answers settled
    /// queries, so the sleep is the debounce; `.task(id:)` cancels it the moment
    /// another character lands.
    private func runSearch() async {
        let pending = store.query
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(for: .milliseconds(280))
            if Task.isCancelled { return }
        }
        await store.search(pending)
    }
}

// MARK: - Result card

private struct ServerCard: View {
    let server: RegistryServer
    let isInstalled: Bool
    let action: () -> Void

    @BudState private var isHovering = false

    var body: some View {
        Button(action: action) {
            GlassCard(tint: isInstalled ? Bud.Palette.success : nil) {
                HStack(alignment: .top, spacing: Bud.Space.md) {
                    icon
                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        HStack(spacing: Bud.Space.xs) {
                            Text(server.displayTitle)
                                .font(Bud.Font.title)
                                .lineLimit(1)
                            Spacer(minLength: Bud.Space.xs)
                            if isInstalled {
                                GlassChip(
                                    "Installed",
                                    systemImage: "checkmark.circle.fill",
                                    tint: Bud.Palette.success,
                                    isActive: true
                                )
                            }
                        }

                        Text(server.name)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !server.summary.isEmpty {
                            Text(server.summary)
                                .font(Bud.Font.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: Bud.Space.xs) {
                            if !server.version.isEmpty { GlassChip(server.version) }
                            ForEach(provenances, id: \.self) { GlassChip($0) }
                            GlassChip(optionCountLabel)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.snappy(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Registry order is already relevance order for a search and publication
    /// order for a browse, so the list is never re-sorted here.
    private var provenances: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for option in server.options {
            let label = provenanceLabel(option)
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels
    }

    private var optionCountLabel: String {
        switch server.options.count {
        case 0: return "no install options"
        case 1: return "1 install option"
        default: return "\(server.options.count) install options"
        }
    }

    private var icon: some View {
        AsyncImage(url: server.iconURL.flatMap { URL(string: $0) }) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .background(Color.white.opacity(0.06))
            case .empty, .failure:
                fallbackIcon
            @unknown default:
                fallbackIcon
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
    }
}

// MARK: - Inspector

private struct RegistryServerInspector: View {
    let server: RegistryServer
    let store: MarketplaceStore
    let mcp: MCPManager
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @BudState private var envValues: [String: String] = [:]
    @BudState private var installingOptionID: String?
    @BudState private var report: InstallReport?

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: Bud.Space.lg) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: Bud.Space.lg) {
                        about
                        links
                        installOptions
                    }
                }
                footer
            }
            .padding(Bud.Space.lg)
            .frame(width: 540, height: 640, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Bud.Space.md) {
            AsyncImage(url: server.iconURL.flatMap { URL(string: $0) }) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .background(Color.white.opacity(0.06))
                case .empty, .failure:
                    fallbackHeaderIcon
                @unknown default:
                    fallbackHeaderIcon
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
            }

            VStack(alignment: .leading, spacing: Bud.Space.xs) {
                HStack(spacing: Bud.Space.xs) {
                    Text(server.displayTitle)
                        .font(Bud.Font.title)
                        .lineLimit(1)
                    if !server.version.isEmpty { GlassChip(server.version) }
                    if store.isInstalled(server) {
                        GlassChip(
                            "Installed",
                            systemImage: "checkmark.circle.fill",
                            tint: Bud.Palette.success,
                            isActive: true
                        )
                    }
                }
                Text(server.name)
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
    }

    private var fallbackHeaderIcon: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
    }

    @ViewBuilder
    private var about: some View {
        if !server.summary.isEmpty {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                SectionHeader("About")
                Text(server.summary)
                    .font(Bud.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var links: some View {
        let items = externalLinks
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                SectionHeader("Links")
                HStack(spacing: Bud.Space.sm) {
                    ForEach(items) { item in
                        Button {
                            _ = NSWorkspace.shared.open(item.url)
                        } label: {
                            Label(item.label, systemImage: item.symbol)
                                .font(Bud.Font.callout)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var externalLinks: [RegistryLink] {
        var items: [RegistryLink] = []
        if let raw = server.repositoryURL, let url = URL(string: raw) {
            items.append(RegistryLink(id: "repo", label: "Repository", symbol: "chevron.left.forwardslash.chevron.right", url: url))
        }
        if let raw = server.websiteURL, let url = URL(string: raw) {
            items.append(RegistryLink(id: "site", label: "Website", symbol: "safari", url: url))
        }
        return items
    }

    @ViewBuilder
    private var installOptions: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Install options", subtitle: "Installing adds a server you can edit later in Settings.")
            if server.options.isEmpty {
                Text("This entry publishes no npm package, PyPI package, or remote endpoint, so Bud cannot configure it automatically.")
                    .font(Bud.Font.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(server.options) { option in
                    optionCard(option)
                }
            }
        }
    }

    private func optionCard(_ option: RegistryInstallOption) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                HStack(spacing: Bud.Space.xs) {
                    Image(systemName: option.transport.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(option.transport.label)
                        .font(Bud.Font.caption)
                        .foregroundStyle(.secondary)
                    GlassChip(provenanceLabel(option))
                    Spacer(minLength: 0)
                }

                Text(option.label)
                    .font(Bud.Font.mono)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ForEach(option.requiredEnv, id: \.self) { name in
                    envField(name)
                }

                HStack(spacing: Bud.Space.sm) {
                    Button {
                        Task { await install(option) }
                    } label: {
                        HStack(spacing: Bud.Space.xs) {
                            if installingOptionID == option.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            Text("Install")
                        }
                        .font(Bud.Font.body)
                    }
                    .buttonStyle(.glass)
                    .disabled(installingOptionID != nil || !isReady(option))

                    if let report, report.optionID == option.id {
                        statusLabel(report.status)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func envField(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
            TextField(
                name,
                text: Binding(
                    get: { envValues[name] ?? "" },
                    set: { envValues[name] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(Bud.Font.mono)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: InstallStatus) -> some View {
        switch status {
        case .ready(let toolCount):
            Label(
                "Ready · \(toolCount) tool\(toolCount == 1 ? "" : "s")",
                systemImage: "checkmark.circle.fill"
            )
            .font(Bud.Font.caption)
            .foregroundStyle(Bud.Palette.success)
        case .added:
            Label(
                "Added as “\(server.displayTitle)” — connect it from Settings → MCP.",
                systemImage: "checkmark.circle"
            )
            .font(Bud.Font.caption)
            .foregroundStyle(Bud.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(Bud.Font.caption)
                .foregroundStyle(Bud.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: Bud.Space.sm) {
            Button("MCP Settings") {
                dismiss()
                model.openSettings(tab: .mcp)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Install

    /// Install is deliberately two steps against the MCP manager — persist the
    /// configuration, then connect — so a server that cannot start is still
    /// listed (and editable) in Settings rather than vanishing.
    private func install(_ option: RegistryInstallOption) async {
        installingOptionID = option.id
        report = nil

        var config = store.makeConfig(from: server, option: option)
        for name in option.requiredEnv {
            config.env[name] = (envValues[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        await mcp.addServer(config)
        await mcp.connect(id: config.id)

        if let status = mcp.statuses[config.id] {
            switch status.state {
            case .ready:
                report = InstallReport(optionID: option.id, status: .ready(toolCount: status.toolCount))
                await model.refreshTools()
            case .failed:
                report = InstallReport(
                    optionID: option.id,
                    status: .failed(status.error ?? "The server did not report why it failed.")
                )
            case .connecting, .stopped:
                report = InstallReport(optionID: option.id, status: .added)
            }
        } else {
            report = InstallReport(optionID: option.id, status: .added)
        }

        installingOptionID = nil
    }

    private func isReady(_ option: RegistryInstallOption) -> Bool {
        option.requiredEnv.allSatisfy { name in
            !(envValues[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Support types

private struct RegistryLink: Identifiable {
    let id: String
    let label: String
    let symbol: String
    let url: URL
}

private struct InstallReport {
    let optionID: String
    let status: InstallStatus
}

private enum InstallStatus {
    case ready(toolCount: Int)
    case added
    case failed(String)
}

/// `RegistryInstallOption` carries the transport rather than the distribution
/// channel, so the provenance chip is derived from the command the mapping
/// produced: `npx` is npm, `uvx` is PyPI.
private func provenanceLabel(_ option: RegistryInstallOption) -> String {
    switch option.transport {
    case .http: return "http"
    case .sse: return "sse"
    case .stdio: return option.command == "uvx" ? "pypi" : "npm"
    }
}
