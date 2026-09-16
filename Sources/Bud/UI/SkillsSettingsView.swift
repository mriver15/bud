import AppKit
import SwiftUI

/// Skills: what is installed, and what can be.
///
/// One pane rather than a surface of its own. A skill is installed once and then
/// used by the model without anyone thinking about it again, so the screen that
/// manages them belongs with the other things that are configured once — not
/// beside Chat, where it would be a tab nobody opens twice.
struct SkillsSettingsView: View {
    let registry: SkillRegistry

    @BudState private var installed: [Skill] = []
    @BudState private var query = ""
    @BudState private var newSource = ""
    @BudState private var pendingRemoval: Skill?
    @BudState private var busy: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Bud.Space.lg) {
                installedSection
                browseSection
                sourcesSection
            }
            .padding(.bottom, Bud.Space.lg)
        }
        .onAppear { refresh() }
        .onChange(of: registry.installedNames) { _, _ in refresh() }
        .alert(
            pendingRemoval.map { "Remove “\($0.name)”?" } ?? "Remove skill?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { skill in
            Button("Remove", role: .destructive) {
                try? registry.uninstall(skill.name)
                pendingRemoval = nil
                refresh()
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { skill in
            Text("“\(skill.name)” is deleted from \(SkillStore.directory.path). It can be installed again from its source.")
        }
    }

    private func refresh() {
        installed = SkillStore.installed()
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Installed",
                subtitle: installed.isEmpty
                    ? "Nothing yet — browse below"
                    : "\(installed.count) \(installed.count == 1 ? "skill" : "skills")",
                systemImage: "sparkles.rectangle.stack"
            )

            if installed.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        Text("Skills are instructions the model loads when a task calls for them.")
                            .font(Bud.Font.callout)
                        Text("Bud follows the open Agent Skills format, so a skill you already use in another agent works here unchanged — and one you write here works there.")
                            .font(Bud.Font.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(installed) { skill in
                    skillCard(skill)
                }
            }
        }
    }

    private func skillCard(_ skill: Skill) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Bud.Space.xs) {
                HStack(spacing: Bud.Space.sm) {
                    Text(skill.name)
                        .font(Bud.Font.body.weight(.semibold))
                    if let compatibility = skill.compatibility {
                        GlassChip(compatibility, systemImage: "info.circle")
                            .help(compatibility)
                    }
                    Spacer(minLength: Bud.Space.sm)
                    Button("Remove") { pendingRemoval = skill }
                        .buttonStyle(.plain)
                        .font(Bud.Font.caption)
                        .foregroundStyle(Bud.Palette.danger)
                }

                Text(skill.summary)
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Bud.Space.xs) {
                    if let source = skill.source, let url = URL(string: source) {
                        Link(destination: url) {
                            Text(source.replacingOccurrences(of: "https://", with: ""))
                                .font(Bud.Font.micro)
                                .foregroundStyle(Bud.Palette.accent)
                                .lineLimit(1)
                        }
                    } else {
                        Text("written locally")
                            .font(Bud.Font.micro)
                            .foregroundStyle(.tertiary)
                    }
                    if !skill.resources.isEmpty {
                        Text("·")
                            .font(Bud.Font.micro)
                            .foregroundStyle(.tertiary)
                        Text("\(skill.resources.count) file\(skill.resources.count == 1 ? "" : "s")")
                            .font(Bud.Font.micro)
                            .foregroundStyle(.tertiary)
                    }
                    if let license = skill.license {
                        Text("·")
                            .font(Bud.Font.micro)
                            .foregroundStyle(.tertiary)
                        Text(license)
                            .font(Bud.Font.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Browse

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader(
                    "Available",
                    subtitle: registry.isLoading
                        ? "Reading sources…"
                        : (registry.available.isEmpty
                            ? "Not loaded"
                            : "\(filtered.count) of \(registry.available.count)"),
                    systemImage: "square.grid.2x2"
                )
                Spacer(minLength: Bud.Space.sm)
                GlassIconButton(
                    systemImage: "arrow.clockwise",
                    help: registry.available.isEmpty ? "Load from sources" : "Reload"
                ) {
                    Task { await registry.browseAll() }
                }
            }

            if !registry.available.isEmpty {
                searchField
            }

            if let problem = registry.errorMessage {
                Text(problem)
                    .font(Bud.Font.caption)
                    .foregroundStyle(Bud.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if registry.available.isEmpty, !registry.isLoading {
                Text("Load the list to see what is available in your sources.")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(filtered) { entry in
                    availableRow(entry)
                }
                if filtered.isEmpty, !query.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Bud.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(Bud.Font.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter by name or what it does", text: $query)
                .textFieldStyle(.plain)
                .font(Bud.Font.callout)
        }
        .padding(.horizontal, Bud.Space.sm)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }

    private func availableRow(_ entry: AvailableSkill) -> some View {
        GlassCard(padding: Bud.Space.sm) {
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Bud.Space.xs) {
                        Text(entry.name)
                            .font(Bud.Font.callout.weight(.medium))
                        Text(entry.source.title)
                            .font(Bud.Font.micro)
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.summary)
                        .font(Bud.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Bud.Space.sm)

                if entry.isInstalled {
                    Text("Installed")
                        .font(Bud.Font.caption)
                        .foregroundStyle(Bud.Palette.success)
                } else {
                    Button(busy == entry.id ? "Installing…" : "Install") {
                        Task {
                            busy = entry.id
                            try? await registry.install(entry)
                            busy = nil
                            refresh()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy != nil)
                }
            }
        }
    }

    private var filtered: [AvailableSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return registry.available }
        return registry.available.filter {
            $0.name.lowercased().contains(trimmed) || $0.summary.lowercased().contains(trimmed)
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Sources",
                subtitle: "Any GitHub repository with skill folders in it",
                systemImage: "link"
            )

            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    ForEach(registry.sources) { source in
                        HStack(spacing: Bud.Space.sm) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: Bud.Space.xs) {
                                    Text(source.title).font(Bud.Font.callout)
                                    // The path is shown as a qualifier rather than
                                    // appended to the repository: a repo called
                                    // `skills` holding its skills in `skills/`
                                    // renders as `anthropics/skills/skills`, which
                                    // reads like a mistake.
                                    if !source.path.isEmpty {
                                        Text("in \(source.path)/")
                                            .font(Bud.Font.micro)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Text("\(source.owner)/\(source.repo)")
                                    .font(Bud.Font.micro)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: Bud.Space.sm)
                            if registry.sources.count > 1 {
                                Button("Remove") { registry.remove(source: source) }
                                    .buttonStyle(.plain)
                                    .font(Bud.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider().opacity(0.3)

                    HStack(spacing: Bud.Space.xs) {
                        TextField("owner/repo", text: $newSource)
                            .textFieldStyle(.roundedBorder)
                            .font(Bud.Font.mono)
                        Button("Add") { addSource() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(parsedSource == nil)
                    }

                    Text("Skills in a repository are found wherever a SKILL.md sits. Bud installs the whole folder, so scripts and references come with it.")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var parsedSource: SkillSource? {
        let parts = newSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://github.com/", with: "")
            .split(separator: "/")
            .map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return SkillSource(
            owner: parts[0],
            repo: parts[1],
            path: parts.count > 3 ? parts[3...].joined(separator: "/") : "",
            title: parts[0]
        )
    }

    private func addSource() {
        guard let source = parsedSource else { return }
        registry.add(source: source)
        newSource = ""
    }
}
