import Foundation
import SwiftUI

/// Memory: everything Bud has been asked to keep, and the way to take it back.
///
/// Notes are invisible everywhere else in the app. They ride along on every
/// request, so one that was recorded wrong keeps shaping answers with nothing on
/// screen to explain why — and that is the thing people distrust, because memory
/// you cannot look at is indistinguishable from memory that is wrong. This pane
/// is the look-at, and the delete.
///
/// The three scopes are shown as three groups in their own words rather than as
/// the stored `user` / `project` / `general` values: what a reader needs is where
/// a note belongs, and the store's vocabulary for it is not that.
public struct MemorySettingsView: View {
    /// The note whose removal is waiting to be agreed to.
    ///
    /// The row arms the delete and the dialog performs it, the same shape as
    /// deleting a conversation. A trash icon in a list someone is scanning is not
    /// a place for a permanent delete on one tap.
    @BudState private var pendingForget: Lesson?
    @BudState private var notes: [Lesson] = []
    /// The instruction whose removal is waiting to be agreed to.
    @BudState private var pendingRemove: Directive?
    @BudState private var directives: [Directive] = []
    @BudState private var directiveDraft = ""
    /// Set when the store refused the draft as a duplicate, so the field can
    /// say why nothing happened.
    @BudState private var directiveDuplicate = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            SectionHeader("Memory", subtitle: summary, systemImage: "brain")

            if notes.isEmpty {
                EmptyStateView(
                    systemImage: "brain",
                    title: "Notes land here",
                    message: "Ask Bud to remember something and it writes it down — a preference, "
                        + "a convention, a fact you are tired of repeating. It files the occasional "
                        + "note of its own as well. Everything it keeps shows up here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Bud.Space.lg) {
                        ForEach(ScopeGroup.allCases) { group in
                            let filed = groupedNotes[group] ?? []
                            if !filed.isEmpty {
                                section(group, filed)
                            }
                        }
                    }
                    .padding(.bottom, Bud.Space.sm)
                }
            }

            directivesSection

            footer
        }
        .onAppear { refresh() }
        .confirmationDialog(
            pendingForget.map { "Forget “\(Self.excerpt($0.text))”?" } ?? "Forget this note?",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForget
        ) { note in
            Button("Forget", role: .destructive) { forget(note) }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: { _ in
            Text("Bud drops it from what it carries into every conversation. It cannot be recovered.")
        }
        .confirmationDialog(
            pendingRemove.map { "Remove “\(Self.excerpt($0.text))”?" } ?? "Remove this instruction?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemove
        ) { directive in
            Button("Remove", role: .destructive) { remove(directive) }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { _ in
            Text("Bud stops carrying the instruction from then on.")
        }
    }

    private var summary: String {
        if notes.isEmpty { return "Nothing kept yet" }
        return notes.count == 1 ? "1 note" : "\(notes.count) notes"
    }

    // MARK: - Groups

    /// The three places a note can be filed, in the order a reader meets them.
    ///
    /// `general` is last because it is the leftovers: it is only meaningful once
    /// the other two have been ruled out, which is also how the model is told to
    /// choose between them.
    private enum ScopeGroup: String, CaseIterable, Identifiable {
        case user, project, general

        var id: String { rawValue }

        /// The group a stored scope belongs to.
        ///
        /// An unrecognised scope is filed under General rather than dropped. Only
        /// the three values are ever written, but a pane whose job is showing
        /// everything must not be the one place something quietly goes missing —
        /// and "everything else" is what General means.
        init(scope: String) {
            self = ScopeGroup(rawValue: scope.lowercased()) ?? .general
        }

        /// The heading, in words rather than in the store's vocabulary.
        var heading: String {
            switch self {
            case .user: return "Who you are"
            case .project: return "Your project"
            case .general: return "Everything else"
            }
        }

        /// What belongs here — the line that answers "why is it filed under this
        /// one and not the others", which is the only question the grouping raises.
        var explanation: String {
            switch self {
            case .user: return "Preferences, interests, and how you like answers."
            case .project: return "Conventions of the codebase you work in."
            case .general: return "Facts and decisions that belong to neither."
            }
        }

        var symbol: String {
            switch self {
            case .user: return "person"
            case .project: return "folder"
            case .general: return "tray"
            }
        }
    }

    /// The notes filed under each group, newest first.
    ///
    /// `BudStore.lessons()` already orders by recency, so a single walk in that
    /// order keeps each group's ordering as it is found.
    private var groupedNotes: [ScopeGroup: [Lesson]] {
        var buckets: [ScopeGroup: [Lesson]] = [:]
        for note in notes {
            buckets[ScopeGroup(scope: note.scope), default: []].append(note)
        }
        return buckets
    }

    private func section(_ group: ScopeGroup, _ filed: [Lesson]) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(group.heading, subtitle: group.explanation, systemImage: group.symbol)
            VStack(spacing: Bud.Space.xs) {
                ForEach(filed) { note in
                    row(note)
                }
            }
        }
    }

    /// One note. The full text, wrapped rather than clipped: this is the one
    /// surface where reading the whole sentence is the point.
    ///
    /// A flat fill rather than the default material, which is the rule for rows
    /// in a list — the store returns up to a hundred of these and a material
    /// re-samples its backdrop for every one of them.
    private func row(_ note: Lesson) -> some View {
        GlassCard(cornerRadius: Bud.Radius.control, padding: Bud.Space.sm, surface: .flat) {
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                VStack(alignment: .leading, spacing: Bud.Space.xs) {
                    Text(note.text)
                        .font(Bud.Font.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(note.createdAt.formatted(.relative(presentation: .named)))
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                        .help(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer(minLength: Bud.Space.sm)

                Button {
                    pendingForget = note
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Forget this note")
            }
        }
    }

    // MARK: - Standing instructions

    /// Durable instructions the person wrote down themselves, admitted into
    /// context whenever the conversation speaks their language. This is the
    /// writer side of the retrieval path — the model has always read these;
    /// the way to write them without asking the model to.
    private var directivesSection: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            SectionHeader(
                "Standing instructions",
                subtitle: "Rules you wrote down. Bud carries the ones a conversation matches into every request.",
                systemImage: "text.badge.checkmark"
            )
            HStack(spacing: Bud.Space.sm) {
                TextField("e.g. Never run destructive commands without asking", text: $directiveDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addDirective() }
                    .onChange(of: directiveDraft) { _, _ in directiveDuplicate = false }
                Button("Add", action: addDirective)
                    .buttonStyle(.bordered)
                    .disabled(trimmedDraft.isEmpty)
            }
            if directiveDuplicate {
                Text("That instruction is already saved.")
                    .font(Bud.Font.caption)
                    .foregroundStyle(Bud.Palette.warning)
            }
            VStack(spacing: Bud.Space.xs) {
                ForEach(directives) { directive in
                    directiveRow(directive)
                }
            }
        }
    }

    private var trimmedDraft: String {
        directiveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func directiveRow(_ directive: Directive) -> some View {
        GlassCard(cornerRadius: Bud.Radius.control, padding: Bud.Space.sm, surface: .flat) {
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                Text(directive.text)
                    .font(Bud.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: Bud.Space.sm)

                Button {
                    pendingRemove = directive
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove this instruction")
            }
        }
    }

    private func addDirective() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        if CognitiveStore.recordDirective(text: text, authority: "user") == nil {
            // Only one failure mode: the store refused a duplicate.
            directiveDuplicate = true
            return
        }
        directiveDraft = ""
        refresh()
    }

    private func remove(_ directive: Directive) {
        CognitiveStore.deleteDirective(id: directive.id)
        pendingRemove = nil
        refresh()
    }

    // MARK: - Footer

    /// What the notes cost and where they live, in two sentences.
    ///
    /// Both facts are otherwise invisible: every request carries them, and the
    /// only other place the file is named is the General tab's config path.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.6)
            Text("Bud draws on these on every request, so a note that is wrong keeps shaping "
                + "answers until it goes. They are stored on this Mac, in ~/.bud.")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// The store is the list. Nothing is cached beyond the render, so a note Bud
    /// records while this pane is open is picked up the next time it appears.
    private func refresh() {
        notes = BudStore.lessons()
        directives = CognitiveStore.directives()
    }

    private func forget(_ note: Lesson) {
        BudStore.forget(id: note.id)
        pendingForget = nil
        refresh()
    }

    /// The note shortened to something that fits in a dialog title: long enough
    /// to recognise it, short enough that the question stays readable.
    private static func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 48 ? flat : String(flat.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
