import AppKit
import SwiftUI

/// Marketplace browser: search a catalogue of MCP servers and install one
/// straight into the MCP manager.
///
/// Two sources are offered — the official MCP registry and Glama — and the pane
/// carries whichever attribution the active source requires. Glama's API Data
/// License obliges every view showing its data to credit Glama and to link each
/// record's own listing, so both live on the pane itself rather than in About.
///
/// The view owns nothing but its presentation state — the list, the request in
/// flight, and install results all live in `MarketplaceStore` / `MCPManager`, so
/// switching tabs never loses a fetch.
public struct MarketplaceView: View {
    private let store: MarketplaceStore
    private let mcp: MCPManager
    private let model: AppModel

    /// Where the Glama credit points. Glama's licence is specific that this is a
    /// plain link, so it is opened directly and never marked up.
    private static let glamaURLString = "https://glama.ai"

    @BudState private var inspected: RegistryServer?

    public init(store: MarketplaceStore, mcp: MCPManager, model: AppModel) {
        self.store = store
        self.mcp = mcp
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            SectionHeader("MCP Marketplace", subtitle: subtitle, systemImage: "shippingbox")
            sourcePicker
            if store.source == .glama {
                glamaCredit
            }
            if store.glamaKeyMissing {
                glamaKeyMissingState
            } else {
                searchField
                if let loadError = store.loadError {
                    errorBanner(loadError)
                }
                resultsArea
            }
        }
        .padding(Bud.Space.lg)
        .task {
            // The store does not own the config, so the shell mirrors the key in.
            // Doing it here — rather than once at launch — is what lets a key
            // pasted in Settings take effect on the next visit, with no relaunch.
            store.glamaAPIKey = model.config.glamaAPIKey
            await store.loadInitial()
        }
        .task(id: store.query) { await runSearch() }
        .sheet(item: $inspected) { server in
            RegistryServerInspector(
                server: server,
                source: store.source,
                store: store,
                mcp: mcp,
                model: model
            )
        }
    }

    // MARK: - Pieces

    private var subtitle: String {
        let count = store.totalLoaded
        let servers = count == 1 ? "1 server" : "\(count) servers"
        let origin = store.source == .glama ? "from Glama" : "from the registry"
        if store.lastQuery.isEmpty { return "\(servers) loaded \(origin)" }
        return "\(servers) matching “\(store.lastQuery)”"
    }

    /// The source switcher, styled as the surface picker in the panel header is:
    /// adjacent capsule buttons inside one `GlassEffectContainer`, so the two
    /// controls read as the same kind of thing. The container is not decoration —
    /// it is what gives the capsules correct material bounds; without it the
    /// glass draws over the header above.
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            GlassEffectContainer(spacing: Bud.Space.hairline) {
                HStack(spacing: Bud.Space.hairline) {
                    ForEach(MarketplaceSource.allCases) { option in
                        Button {
                            withAnimation(.snappy(duration: 0.18)) { store.source = option }
                        } label: {
                            HStack(spacing: Bud.Space.xs) {
                                Image(systemName: symbol(for: option))
                                    .font(Bud.Font.micro)
                                Text(option.label)
                                    .font(Bud.Font.caption)
                            }
                            .padding(.horizontal, Bud.Space.sm)
                            .padding(.vertical, Bud.Space.xs)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(store.source == option ? .primary : .secondary)
                        .glassEffect(
                            store.source == option
                                ? .regular.tint(Bud.Palette.accent.opacity(0.45)).interactive()
                                : .identity,
                            in: .capsule
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(store.source.blurb)
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func symbol(for source: MarketplaceSource) -> String {
        switch source {
        case .official: return "shippingbox"
        case .glama: return "circle.hexagongrid"
        }
    }

    /// Glama's API Data License requires a visible credit to Glama, linked to
    /// glama.ai, on every view that shows its data. The link is plain — no
    /// `nofollow`, no `sponsored` — and it sits on the pane itself because that
    /// is where the data is.
    private var glamaCredit: some View {
        Button {
            if let url = URL(string: Self.glamaURLString) {
                _ = NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: Bud.Space.xs) {
                Text("MCP data from Glama")
                Image(systemName: "arrow.up.right")
                    .font(Bud.Font.micro.weight(.semibold))
            }
            .font(Bud.Font.caption)
            .foregroundStyle(Bud.Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Glama's API Data License requires this credit and a link to each record's own listing.")
    }

    /// A missing key is a prompt, not an error: nothing was requested, so it is
    /// shown as an empty state with a way to fix it rather than as a banner.
    private var glamaKeyMissingState: some View {
        VStack(spacing: Bud.Space.md) {
            EmptyStateView(
                systemImage: "key",
                title: "Glama needs an API key",
                message: "Browsing Glama's catalogue requires an API key. Add one in Settings → General and come back — Bud keeps it in ~/.bud/config.json with owner-only permissions.",
                fills: false
            )
            Button {
                model.openSettings(tab: .general)
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .font(Bud.Font.body)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var searchField: some View {
        GlassCard(padding: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(Bud.Font.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField(
                    store.source == .glama ? "Search Glama" : "Search the MCP registry",
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
                            .font(Bud.Font.callout)
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
                .font(Bud.Font.callout.weight(.semibold))
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
                // Adaptive rather than a single column: at the settings window's
                // width a full-width card wastes most of the pane and shows only
                // a handful of results. This yields two columns when there is
                // room and one when there is not.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: Bud.Space.sm)],
                    alignment: .leading,
                    spacing: Bud.Space.sm
                ) {
                    ForEach(store.results) { server in
                        ServerCard(
                            server: server,
                            source: store.source,
                            isInstalled: store.isInstalled(server)
                        ) {
                            inspected = server
                        }
                    }
                }
                .padding(.vertical, Bud.Space.hairline)
            }
        }
    }

    private var emptyMessage: String {
        if store.isSearching {
            return store.source == .glama ? "Querying Glama." : "Querying the MCP registry."
        }
        if !store.lastQuery.isEmpty {
            return store.source == .glama
                ? "No Glama record matches “\(store.lastQuery)”. Try a shorter term."
                : "No registry entry matches “\(store.lastQuery)”. Try a shorter term."
        }
        if store.loadError != nil {
            return store.source == .glama
                ? "Glama could not be read. Retry above, or check the key in Settings → General."
                : "The registry could not be read. Retry above, or check this Mac's network."
        }
        return store.source == .glama ? "Glama returned no records." : "The registry returned no servers."
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
    let source: MarketplaceSource
    let isInstalled: Bool
    let action: () -> Void

    @BudState private var isHovering = false

    var body: some View {
        GlassCard(tint: isInstalled ? Bud.Palette.success : nil) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                content
                if let listing = glamaListing {
                    glamaLink(listing)
                }
            }
        }
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.snappy(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// The record's own Glama listing. Glama's API Data License requires every
    /// record presented to carry this link, visible without hovering, in addition
    /// to whatever else the card links to.
    ///
    /// For a Glama row `websiteURL` *is* the listing — the mapping puts the API's
    /// `url` there and never the endpoint — so this reads the same field the
    /// website link would, which is the point: one URL, one meaning.
    private var glamaListing: URL? {
        guard source == .glama, let raw = server.websiteURL else { return nil }
        return URL(string: raw)
    }

    /// A sibling of the card's button, not a child: a link nested inside a button
    /// is not separately clickable on macOS.
    private func glamaLink(_ url: URL) -> some View {
        Button {
            _ = NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: Bud.Space.xs) {
                Image(systemName: "arrow.up.right.square")
                    .font(Bud.Font.micro.weight(.semibold))
                Text("View on Glama")
                    .font(Bud.Font.caption)
                    .underline()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Bud.Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this record's listing on glama.ai")
    }

    private var content: some View {
        Button(action: action) {
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
            // The label is the hit area, so it is stretched to the card's inner
            // width and given a shape: the row reads as one button, not just the
            // glyphs in it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .font(Bud.Font.title.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
    }
}

// MARK: - Inspector

private struct RegistryServerInspector: View {
    let server: RegistryServer
    let source: MarketplaceSource
    let store: MarketplaceStore
    let mcp: MCPManager
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    /// Credentials the user has typed, keyed by the name the option declares.
    /// Transport-agnostic on purpose: `makeConfig` decides whether they become a
    /// child process's environment or an HTTP header.
    @BudState private var credentials: [String: String] = [:]
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
                    .font(Bud.Font.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
    }

    private var fallbackHeaderIcon: some View {
        Image(systemName: "shippingbox")
            .font(Bud.Font.hero.weight(.medium))
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
            // For a Glama record this is the record's own listing — the link its
            // API Data License requires wherever the record is presented — so it
            // is named as such rather than as a generic website.
            items.append(
                source == .glama
                    ? RegistryLink(id: "glama", label: "Glama listing", symbol: "arrow.up.right.square", url: url)
                    : RegistryLink(id: "site", label: "Website", symbol: "safari", url: url)
            )
        }
        return items
    }

    @ViewBuilder
    private var installOptions: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Install options", subtitle: "Installing adds a server you can edit later in Settings.")
            if server.options.isEmpty {
                Text(browseOnlyExplanation)
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

    /// Why there is nothing to install.
    ///
    /// Glama's worth saying plainly: its directory publishes a server's source,
    /// not a run command, so any install Bud offered would be a guess. The honest
    /// answer is to hand over the repository and let the user wired it up.
    private var browseOnlyExplanation: String {
        guard source == .glama else {
            return "This entry publishes no npm package, PyPI package, or remote endpoint, so Bud cannot configure it automatically."
        }
        return "Glama lists this server for running from source and publishes no package identifier or launch command, so Bud cannot install it automatically. Open the repository or the listing above, then add the command in Settings → MCP."
    }

    private func optionCard(_ option: RegistryInstallOption) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                HStack(spacing: Bud.Space.xs) {
                    Image(systemName: option.transport.symbol)
                        .font(Bud.Font.caption.weight(.semibold))
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
                    credentialField(name)
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

    /// The credential's name is the API's — `Authorization` for a Glama
    /// connector, an environment variable name for a stdio package. Where the
    /// value ends up is `makeConfig`'s call, not this view's: `env` for a child
    /// process, `headers` for an HTTP endpoint.
    private func credentialField(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
            Text(name)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
            TextField(
                name,
                text: Binding(
                    get: { credentials[name] ?? "" },
                    set: { credentials[name] = $0 }
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

        var typed: [String: String] = [:]
        for name in option.requiredEnv {
            typed[name] = (credentials[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // `makeConfig` routes each credential to `env` or `headers` by transport.
        // Writing them here instead is what would put an HTTP server's key
        // somewhere the transport never reads.
        let config = MarketplaceStore.makeConfig(from: server, option: option, credentials: typed)

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
            !(credentials[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
