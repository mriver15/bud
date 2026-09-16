import Foundation
import SwiftUI

/// The whole conversation archive: everything Bud has saved, with the search and
/// the actions that a dropdown of five cannot carry.
///
/// The menu bar is a shortcut into the last few conversations, so this is the
/// surface for the rest of them — the conversation from last week that no
/// five-row menu will ever show. It is deliberately uncapped for that reason: a
/// browser that stopped at five would just be the menu bar with a different
/// frame, and the search field is what narrows a long archive rather than a
/// truncated list quietly hiding things.
struct ConversationHistoryView: View {
    private let model: AppModel

    /// The conversation whose delete is waiting to be confirmed.
    ///
    /// Deleting is permanent and the trash button sits in a list the user is
    /// scanning rather than aiming at, so the click arms the delete and the
    /// dialog is what performs it — the same shape as removing an MCP server.
    @BudState private var pendingDelete: ConversationSummary?

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Bud.Space.md)

            // A hairline rather than `Divider`: the panel's rule is 0.6pt and
            // this one has to match the separation every other surface draws.
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.6)

            content
        }
        .padding(Bud.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)”?" } ?? "Delete conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { conversation in
            Button("Delete", role: .destructive) {
                delete(conversation)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Bud drops this conversation and everything said in it. It cannot be recovered.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.sm) {
                SectionHeader("History", subtitle: summary, systemImage: "clock.arrow.circlepath")
                Spacer(minLength: Bud.Space.sm)
                Button {
                    startNewConversation()
                } label: {
                    Label("New chat", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            searchField
        }
    }

    /// The search box, bound straight to the model's query rather than to a copy
    /// held here.
    ///
    /// The model is what actually narrows the list, and a local mirror could end
    /// up displaying a query the list was not filtered by — starting a new chat
    /// clears the query behind the panel's back, to name the one that happens.
    private var searchField: some View {
        HStack(spacing: Bud.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(Bud.Font.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField(
                "Search titles and everything said",
                text: Binding(
                    get: { model.conversationQuery },
                    set: { model.searchConversations($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(Bud.Font.callout)
            if !model.conversationQuery.isEmpty {
                Button {
                    model.searchConversations("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Bud.Font.caption.weight(.regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
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

    private var summary: String {
        let count = model.conversations.count
        if isSearching {
            return count == 1 ? "1 match" : "\(count) matches"
        }
        if count == 0 { return "Nothing saved yet" }
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.conversations.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Bud.Space.sm) {
                ForEach(model.conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isCurrent: conversation.id == model.currentConversationID,
                        open: { open(conversation) },
                        confirmDelete: { pendingDelete = conversation }
                    )
                }
            }
            .padding(.vertical, Bud.Space.md)
        }
    }

    /// Two empty cases, kept apart because they call for different things.
    ///
    /// "Nothing saved yet" means the archive is empty and the answer is to go and
    /// have a conversation. "No matches" means the archive is fine and the query
    /// is too narrow, so the answer is to loosen it. One shared message would be
    /// wrong for one of them either way.
    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Nothing saved matches “\(trimmedQuery)”."
            )
        } else {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: "No conversations yet",
                message: "Bud files a conversation away once there is something in it to keep, and it appears here from then on."
            )
        }
    }

    // MARK: - Actions

    /// Opening a row also puts the panel back on the transcript.
    ///
    /// The click is a request to read that conversation, and a history list that
    /// stayed on screen afterwards would have answered it with nothing visible.
    private func open(_ conversation: ConversationSummary) {
        model.openConversation(id: conversation.id)
        NotificationCenter.default.post(name: .budShowChat, object: nil)
    }

    /// A new chat is only useful on the composer, so the panel goes there too.
    private func startNewConversation() {
        model.newConversation()
        NotificationCenter.default.post(name: .budShowChat, object: nil)
    }

    /// Deleting the conversation that is currently open leaves the panel with
    /// none, and a transcript with no conversation behind it is a transcript
    /// that silently stops being saved — the model has nothing to write the next
    /// turn into, and the session is lost at quit. Starting a fresh one is what
    /// mints an id, so it happens here rather than on the next launch. Deleting
    /// any other conversation changes nothing but the list.
    private func delete(_ conversation: ConversationSummary) {
        let wasOpen = conversation.id == model.currentConversationID
        // Read before the delete: minting the replacement conversation below
        // resets the query as part of its own reset, and deleting a row out of a
        // filtered list should not also undo the filter.
        let query = model.conversationQuery
        model.deleteConversation(id: conversation.id)
        if wasOpen {
            model.newConversation()
            model.searchConversations(query)
        }
        pendingDelete = nil
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var trimmedQuery: String {
        model.conversationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Row

/// One saved conversation. The whole row is the open action; the trash is the
/// only thing on it that does something else, which is why it is a button of its
/// own rather than a hover affordance hidden in the row.
private struct ConversationRow: View {
    let conversation: ConversationSummary
    let isCurrent: Bool
    let open: () -> Void
    let confirmDelete: () -> Void

    @BudState private var isHovering = false

    var body: some View {
        GlassCard(
            cornerRadius: Bud.Radius.control,
            padding: Bud.Space.sm,
            tint: isHovering ? Bud.Palette.accent : nil
        ) {
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                Button(action: open) {
                    summary
                }
                .buttonStyle(.plain)
                .help("Open this conversation")

                Button(action: confirmDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this conversation")
            }
        }
        .onHover { isHovering = $0 }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            HStack(spacing: Bud.Space.xs) {
                Text(conversation.title)
                    .font(Bud.Font.body)
                    .lineLimit(1)
                if isCurrent {
                    GlassChip(
                        "Current",
                        systemImage: "bubble.left.fill",
                        tint: Bud.Palette.accent,
                        isActive: true
                    )
                }
            }

            if !conversation.preview.isEmpty {
                Text(conversation.preview)
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: Bud.Space.xs) {
                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                Text("·")
                Text(conversation.turnCount == 1 ? "1 turn" : "\(conversation.turnCount) turns")
            }
            .font(Bud.Font.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
