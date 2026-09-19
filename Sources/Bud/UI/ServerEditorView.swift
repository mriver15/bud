import Foundation
import SwiftUI

/// Full editor for a single MCP server.
///
/// The form is transport-dependent by construction: a stdio server is a command
/// plus arguments and environment, a remote one is a URL plus headers. Showing
/// both at once is how configs end up saved with a stale half that silently
/// outlives the transport switch, so the inactive half is dropped on save.
public struct ServerEditorView: View {
    private let mcp: MCPManager?
    private let onConnect: ((MCPServerConfig) async -> Void)?
    private let onSave: (MCPServerConfig) -> Void
    private let dismiss: () -> Void
    private let registryName: String?
    private let notes: String?
    /// Carried through an edit untouched: these are configured in the expanded
    /// diagnostics panel, not here, and rebuilding the config without them would
    /// silently reset a delegation or a tool allowlist every time the server was
    /// renamed.
    private let delegated: Bool
    private let enabledTools: [String]?

    /// Stable across edits so "Save & Connect" can address the server it just
    /// wrote without waiting for the caller to hand an id back.
    @BudState private var id: String
    @BudState private var name: String
    @BudState private var transport: MCPTransportKind
    @BudState private var command: String
    @BudState private var args: [ArgRow]
    @BudState private var env: [EnvRow]
    @BudState private var url: String
    @BudState private var headers: [HeaderRow]
    @BudState private var enabled: Bool
    @BudState private var autoStart: Bool
    @BudState private var didConnect = false
    @BudState private var isConnecting = false

    /// `onSave` persists an edit. `onConnect` persists *and* connects, in that
    /// order — the manager's `connect` needs the config stored first, so the two
    /// steps have to be sequenced by the caller rather than fired independently.
    /// `Save & Connect` is only offered when that sequencing is available.
    public init(
        config: MCPServerConfig?,
        mcp: MCPManager? = nil,
        onConnect: ((MCPServerConfig) async -> Void)? = nil,
        onSave: @escaping (MCPServerConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mcp = mcp
        self.onConnect = onConnect
        self.onSave = onSave
        self.dismiss = onCancel
        self.registryName = config?.registryName
        self.notes = config?.notes
        self.delegated = config?.delegated ?? false
        self.enabledTools = config?.enabledTools
        _id = BudState(initialValue: config?.id ?? UUID().uuidString)
        _name = BudState(initialValue: config?.name ?? "")
        _transport = BudState(initialValue: config?.transport ?? .stdio)
        _command = BudState(initialValue: config?.command ?? "")
        _args = BudState(initialValue: (config?.args ?? []).map { ArgRow(value: $0) })
        _env = BudState(initialValue: (config?.env ?? [:])
            .sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) })
        _url = BudState(initialValue: config?.url ?? "")
        _headers = BudState(initialValue: (config?.headers ?? [:])
            .sorted { $0.key < $1.key }
            .map { HeaderRow(key: $0.key, value: $0.value) })
        _enabled = BudState(initialValue: config?.enabled ?? true)
        _autoStart = BudState(initialValue: config?.autoStart ?? true)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Bud.Space.lg) {
                    if let registryName {
                        GlassChip(
                            "From marketplace · \(registryName)",
                            systemImage: "square.grid.2x2",
                            tint: Bud.Palette.accent,
                            isActive: true
                        )
                    }
                    identitySection
                    transportSection
                    behaviourSection
                    if didConnect { connectionBanner }
                }
                .padding(Bud.Space.lg)
            }
            footer
        }
        .frame(width: 560, height: 520)
        .background(.regularMaterial)
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Identity", systemImage: "tag")
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    labeledField("Name") {
                        TextField("github", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let notes, !notes.isEmpty {
                        Text(notes)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Transport",
                subtitle: transport == .stdio
                    ? "Bud launches this process and speaks JSON-RPC over its stdin/stdout."
                    : "Bud connects to a remote endpoint you host.",
                systemImage: transport.symbol
            )
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.md) {
                    Picker("Transport", selection: $transport) {
                        ForEach(MCPTransportKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch transport {
                    case .stdio: stdioFields
                    case .http, .sse: remoteFields
                    }
                }
            }
        }
    }

    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            labeledField("Command") {
                TextField("npx", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(Bud.Font.mono)
            }

            rowEditorHeader("Arguments", add: { args.append(ArgRow(value: "")) })
            if args.isEmpty {
                caption("No arguments. Each row is passed as one argv entry — quoting is not needed.")
            } else {
                VStack(spacing: Bud.Space.xs) {
                    ForEach(Array(args.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: Bud.Space.xs) {
                            TextField("argument", text: argBinding(row.id))
                                .textFieldStyle(.roundedBorder)
                                .font(Bud.Font.mono)
                            RowControls(
                                index: index,
                                count: args.count,
                                move: { move(row, by: $0) },
                                remove: { args.removeAll { $0.id == row.id } }
                            )
                        }
                    }
                }
            }

            rowEditorHeader("Environment", add: { env.append(EnvRow(key: "", value: "")) })
            if env.isEmpty {
                caption("Optional. Values whose name looks like a credential are masked here.")
            } else {
                VStack(spacing: Bud.Space.xs) {
                    ForEach(env) { row in
                        HStack(spacing: Bud.Space.xs) {
                            TextField("NAME", text: envKeyBinding(row.id))
                                .textFieldStyle(.roundedBorder)
                                .font(Bud.Font.mono)
                                .frame(width: 220)
                            valueField(
                                secret: ServerEditorView.looksSecret(row.key),
                                text: envValueBinding(row.id),
                                placeholder: "value"
                            )
                            RowControls(remove: { env.removeAll { $0.id == row.id } })
                        }
                    }
                }
            }
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            labeledField("URL") {
                TextField(transport == .sse ? "https://example.com/sse" : "https://example.com/mcp", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(Bud.Font.mono)
            }
            rowEditorHeader("Headers", add: { headers.append(HeaderRow(key: "", value: "")) })
            if headers.isEmpty {
                caption("Optional. Added to every request, including the initial handshake.")
            } else {
                VStack(spacing: Bud.Space.xs) {
                    ForEach(headers) { row in
                        HStack(spacing: Bud.Space.xs) {
                            TextField("Header", text: headerKeyBinding(row.id))
                                .textFieldStyle(.roundedBorder)
                                .font(Bud.Font.mono)
                                .frame(width: 220)
                            valueField(
                                secret: ServerEditorView.looksSecret(row.key),
                                text: headerValueBinding(row.id),
                                placeholder: "value"
                            )
                            RowControls(remove: { headers.removeAll { $0.id == row.id } })
                        }
                    }
                }
            }
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader("Behaviour", systemImage: "gearshape.2")
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.switch)
                    Toggle("Connect at launch", isOn: $autoStart)
                        .toggleStyle(.switch)
                    caption("Disabled servers keep their configuration but expose no tools.")
                }
            }
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        let status = mcp?.statuses[id]
        GlassCard(tint: bannerColor(status)) {
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: bannerSymbol(status))
                        .foregroundStyle(bannerColor(status) ?? .secondary)
                }
                VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                    Text(status?.state.label ?? "Connecting…")
                        .font(Bud.Font.callout)
                    if let error = status?.error, !error.isEmpty {
                        Text(error)
                            .font(Bud.Font.caption)
                            .foregroundStyle(Bud.Palette.danger)
                            .textSelection(.enabled)
                    } else if let status {
                        Text(toolLine(status))
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let version = status?.serverVersion, !version.isEmpty {
                        Text("Server version \(version)")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            if let message = validationMessage {
                HStack(alignment: .top, spacing: Bud.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Bud.Font.micro.weight(.regular))
                        .foregroundStyle(Bud.Palette.warning)
                    Text(message)
                        .font(Bud.Font.caption)
                        .foregroundStyle(Bud.Palette.warning)
                }
            }
            HStack(spacing: Bud.Space.sm) {
                if didConnect {
                    // The config is already written; the sheet stays open only so
                    // the user can watch the handshake resolve. Further edits stay
                    // saveable rather than stranding them behind a Done button.
                    Spacer(minLength: 0)
                    Button("Save") { onSave(makeConfig()) }
                        .buttonStyle(.bordered)
                        .disabled(!canSave)
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                    Button("Save") {
                        onSave(makeConfig())
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                    if let onConnect {
                        Button("Save & Connect") { saveAndConnect(onConnect) }
                            .buttonStyle(.glass)
                            .disabled(!canSave || isConnecting)
                    }
                }
            }
        }
        .padding(Bud.Space.lg)
        .background(.thinMaterial)
    }

    // MARK: - Small pieces

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            Text(title)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func rowEditorHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack(spacing: Bud.Space.sm) {
            Text(title)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: add) {
                Label("Add", systemImage: "plus")
                    .font(Bud.Font.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Bud.Palette.accent)
        }
    }

    @ViewBuilder
    private func valueField(secret: Bool, text: Binding<String>, placeholder: String) -> some View {
        if secret {
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Bud.Font.mono)
        } else {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Bud.Font.mono)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Bud.Font.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Row state

    private struct ArgRow: Identifiable {
        let id = UUID()
        var value: String
    }

    private struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    private struct HeaderRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    private func argBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { args.first { $0.id == id }?.value ?? "" },
            set: { newValue in
                guard let index = args.firstIndex(where: { $0.id == id }) else { return }
                args[index].value = newValue
            }
        )
    }

    private func envKeyBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { env.first { $0.id == id }?.key ?? "" },
            set: { newValue in
                guard let index = env.firstIndex(where: { $0.id == id }) else { return }
                env[index].key = newValue
            }
        )
    }

    private func envValueBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { env.first { $0.id == id }?.value ?? "" },
            set: { newValue in
                guard let index = env.firstIndex(where: { $0.id == id }) else { return }
                env[index].value = newValue
            }
        )
    }

    private func headerKeyBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { headers.first { $0.id == id }?.key ?? "" },
            set: { newValue in
                guard let index = headers.firstIndex(where: { $0.id == id }) else { return }
                headers[index].key = newValue
            }
        )
    }

    private func headerValueBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { headers.first { $0.id == id }?.value ?? "" },
            set: { newValue in
                guard let index = headers.firstIndex(where: { $0.id == id }) else { return }
                headers[index].value = newValue
            }
        )
    }

    /// Arguments are positional, so reordering is a real edit: swapping two rows
    /// changes the command line the server is launched with.
    private func move(_ row: ArgRow, by offset: Int) {
        guard let index = args.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard args.indices.contains(target) else { return }
        args.swapAt(index, target)
    }

    /// Values are masked when the *name* looks like a credential — that is the
    /// only signal available, and getting it wrong in the safe direction costs a
    /// click while getting it wrong the other way leaks a token on screen.
    private static func looksSecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { upper.contains($0) }
    }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if trimmedName.isEmpty { return "Give the server a name." }
        if let mcp,
           mcp.servers.contains(where: {
               $0.id != id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
           }) {
            return "Another server is already named “\(trimmedName)”."
        }
        switch transport {
        case .stdio:
            if trimmedCommand.isEmpty { return "A local server needs a command to run, such as npx." }
            if let duplicate = firstDuplicate(env.map(\.key)) {
                return "Environment variable \(duplicate) is listed twice."
            }
        case .http, .sse:
            guard let parsed = URL(string: trimmedURL),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  parsed.host != nil else {
                return "Enter a full http:// or https:// URL."
            }
            if let duplicate = firstDuplicate(headers.map(\.key)) {
                return "Header \(duplicate) is listed twice."
            }
        }
        return nil
    }

    private var canSave: Bool { validationMessage == nil }

    private func firstDuplicate(_ keys: [String]) -> String? {
        var seen: Set<String> = []
        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.insert(trimmed).inserted { return trimmed }
        }
        return nil
    }

    // MARK: - Commit

    private func makeConfig() -> MCPServerConfig {
        switch transport {
        case .stdio:
            return MCPServerConfig(
                id: id,
                name: trimmedName,
                transport: .stdio,
                command: trimmedCommand,
                args: args
                    .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                env: dictionary(from: env.map { ($0.key, $0.value) }),
                url: nil,
                headers: [:],
                enabled: enabled,
                autoStart: autoStart,
                enabledTools: enabledTools,
                delegated: delegated,
                registryName: registryName,
                notes: notes
            )
        case .http, .sse:
            return MCPServerConfig(
                id: id,
                name: trimmedName,
                transport: transport,
                command: nil,
                args: [],
                env: [:],
                url: trimmedURL,
                headers: dictionary(from: headers.map { ($0.key, $0.value) }),
                enabled: enabled,
                autoStart: autoStart,
                enabledTools: enabledTools,
                delegated: delegated,
                registryName: registryName,
                notes: notes
            )
        }
    }

    private func dictionary(from pairs: [(String, String)]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in pairs {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out[trimmed] = value
        }
        return out
    }

    private func saveAndConnect(_ connect: @escaping (MCPServerConfig) async -> Void) {
        let config = makeConfig()
        didConnect = true
        isConnecting = true
        Task {
            await connect(config)
            isConnecting = false
        }
    }

    // MARK: - Status presentation

    private func toolLine(_ status: MCPServerStatus) -> String {
        if status.state == .ready {
            let noun = status.toolCount == 1 ? "tool" : "tools"
            return "\(status.toolCount) \(noun) available"
        }
        return status.state == .stopped ? "Not connected" : "Waiting for the handshake…"
    }

    private func bannerColor(_ status: MCPServerStatus?) -> Color? {
        switch status?.state {
        case .ready: return Bud.Palette.success
        case .connecting: return Bud.Palette.warning
        case .failed: return Bud.Palette.danger
        case .stopped, .none: return nil
        }
    }

    private func bannerSymbol(_ status: MCPServerStatus?) -> String {
        switch status?.state {
        case .ready: return "checkmark.circle.fill"
        case .connecting: return "clock"
        case .failed: return "exclamationmark.octagon.fill"
        case .stopped, .none: return "circle.dashed"
        }
    }
}

/// Up/down/remove controls for one editable row. The move buttons only appear
/// where order carries meaning (argument lists); environment and header rows are
/// keyed, so they offer removal alone rather than two buttons that do nothing.
private struct RowControls: View {
    var index: Int?
    var count: Int = 0
    var move: ((Int) -> Void)?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Bud.Space.hairline) {
            if let move, let index {
                iconButton("chevron.up", enabled: index > 0) { move(-1) }
                iconButton("chevron.down", enabled: index < count - 1) { move(1) }
            }
            iconButton("trash", enabled: true, action: remove)
        }
    }

    private func iconButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Bud.Font.micro.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
    }
}
