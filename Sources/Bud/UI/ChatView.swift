import SwiftUI
import UniformTypeIdentifiers

/// The chat surface: transcript, live status strip, error banner, composer.
///
/// Everything here is transparent — the panel's glass is the only background.
public struct ChatView: View {
    private let model: AppModel

    @BudState private var isDropTargeted = false
    @BudState private var isFinding = false
    @BudState private var findQuery = ""
    @BudState private var findCursor = 0
    @FocusState private var isFindFocused: Bool
    /// The report a context compact returned, shown in place of the budget banner
    /// until the next turn or a new chat clears it.
    @BudState private var compactSummary: String?

    private static let bottomAnchor = "bud.chat.bottom"

    /// What a starter prompt needs before it can be kept. `always` needs nothing
    /// beyond the model; `files` and `browser` are built in, so only `mcp` and
    /// `skills` gate on what the user has actually set up.
    enum StarterCapability: Hashable {
        case always, files, browser, mcp, skills
    }

    struct StarterPrompt {
        let text: String
        let capability: StarterCapability
    }

    /// What the panel offers before you have thought of anything.
    ///
    /// Each entry is a real task that happens to need a different part of the
    /// tool set, so the range is shown by use rather than by advertisement; the
    /// tag decides only whether it is shown, never how it is phrased. Ordered so
    /// the `always` prompt leads, then the built-ins, then the gated ones — a
    /// fresh install fills its four slots from the built-ins, and a gated prompt
    /// takes a slot when its capability exists. With four slots and everything
    /// installed, the last gated prompt can lose its slot to pool order; the
    /// promise is never to offer what cannot be satisfied, not to show everything
    /// that could be.
    private static let starterPool: [StarterPrompt] = [
        StarterPrompt(text: "Compare two options and tell me which to pick", capability: .always),
        StarterPrompt(text: "What's actually eating my disk?", capability: .files),
        StarterPrompt(text: "Find out what changed and give me the short version", capability: .browser),
        StarterPrompt(text: "Use my connected services to check something for me", capability: .mcp),
        StarterPrompt(text: "Put my installed skills to work on this task", capability: .skills),
        StarterPrompt(text: "Read this folder and tell me what it's for", capability: .files),
        StarterPrompt(text: "Look up what's new and tell me if it matters", capability: .browser),
        StarterPrompt(text: "Make a dashboard of this project", capability: .files),
    ]

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        // The reader wraps the whole column so the find bar can scroll the
        // transcript to a match. `transcriptScroll` keeps its own reader for
        // following the stream; both address the same scroll view.
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if isFinding {
                    findBar
                        .contentColumn()
                }

                transcript

            if model.isStreaming {
                statusStrip
                    .contentColumn()
            }

            if let message = model.errorMessage, !message.isEmpty {
                ErrorBanner(message: message) { model.errorMessage = nil }
                    .padding(.horizontal, Bud.Space.md)
                    .padding(.bottom, Bud.Space.xs)
                    .contentColumn()
            }

            if let summary = compactSummary, !summary.isEmpty {
                CompactSummaryBanner(summary: summary) { compactSummary = nil }
                    .padding(.horizontal, Bud.Space.md)
                    .padding(.bottom, Bud.Space.xs)
                    .contentColumn()
            } else if showsBudgetBanner, let budget = model.conversationBudget {
                BudgetBanner(
                    spent: model.conversationTokens,
                    budget: budget,
                    onNewChat: { startNewChat() },
                    onCompact: {
                        Task {
                            compactSummary = await model.runtime.compactConversationNow()
                        }
                    },
                    onRaiseBudget: { model.openSettings(tab: .general) }
                )
                .padding(.horizontal, Bud.Space.md)
                .padding(.bottom, Bud.Space.xs)
                .contentColumn()
            }

                Composer(model: model)
                    .padding(.horizontal, Bud.Space.md)
                    .padding(.top, Bud.Space.xs)
                    .padding(.bottom, Bud.Space.md)
                    .contentColumn()
            }
            .onChange(of: findCursor) { _, _ in scrollToCurrentMatch(proxy) }
            .onChange(of: model.isStreaming) { _, streaming in
                // A compact report is about the context that just existed; once a
                // new turn starts, the banner should reflect the live figures
                // rather than a stale summary.
                if streaming { compactSummary = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .budFindInChat)) { _ in
            openFind()
        }
        // The drop is taken by the surface rather than by the transcript: a file
        // has no target inside a conversation, so wherever the user lets go of it
        // is the panel, and the only question left is what Bud does with it.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: { receiveDrop($0) })
        .overlay {
            // Wide enough to be unmissable, translucent enough that the
            // transcript stays readable under it — a drag the user abandons must
            // not have cost them their place in the conversation.
            if isDropTargeted {
                DropAffordance()
            }
        }
        .animation(Bud.motionReduced ? nil : .snappy(duration: 0.14), value: isDropTargeted)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if model.turns.isEmpty {
            // Deliberately outside the ScrollView. A ScrollView proposes an
            // unbounded height and lays its content out at its intrinsic size,
            // so an empty state placed inside one cannot centre itself — the
            // leftover height collects as a gap above the composer.
            emptyState
        } else {
            transcriptScroll
        }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Bud.Space.md) {
                    // Resolved once per pass rather than per row: filtering the
                    // turns inside the loop would walk the whole transcript once
                    // for every turn in it.
                    let found = Set(matches)
                    ForEach(model.turns) { turn in
                        TranscriptRow(
                            turn: turn,
                            model: model,
                            isLatest: turn.id == model.turns.last?.id,
                            highlight: isFinding ? findQuery : nil,
                            isDimmed: isFinding && !found.contains(turn.id)
                        )
                        .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Bud.Space.md)
                .padding(.vertical, Bud.Space.md)
                // The column is centred inside a full-width ScrollView rather
                // than the ScrollView being narrowed, so the scroll bar stays at
                // the panel edge instead of floating in the middle of it.
                .frame(maxWidth: Bud.contentMeasure, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            // The native bottom anchor keeps the transcript pinned while content
            // grows — streamed text and, crucially, an MCP app whose frame grows
            // when the app reports its size. The manual per-token follow it
            // replaces read a stale offset once an app resized asynchronously,
            // which is what overscrolled the transcript.
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.turns.count) { _, _ in
                // A new turn only ever follows the reader's own send, so this
                // one re-engages following even if history was being read.
                Bud.animate(.snappy(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Find

    private var findBar: some View {
        HStack(spacing: Bud.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(Bud.Font.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            TextField("Find in this chat", text: $findQuery)
                .textFieldStyle(.plain)
                .font(Bud.Font.callout)
                .focused($isFindFocused)
                .onSubmit { advance() }

            Text(matchSummary)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            findStep(symbol: "chevron.up", help: "Previous", by: -1)
            findStep(symbol: "chevron.down", help: "Next", by: 1)

            Button { closeFind() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close find")
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.vertical, Bud.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.bottom, Bud.Space.xs)
        .onExitCommand { closeFind() }
        .onChange(of: findQuery) { _, _ in
            // A new query is a new result set, so the cursor starts at the top of
            // it rather than holding a position that no longer means anything.
            findCursor = 0
        }
    }

    private func findStep(symbol: String, help: String, by step: Int) -> some View {
        Button { advance(by: step) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(matches.isEmpty ? Color.secondary.opacity(0.4) : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(matches.isEmpty)
        .help(help)
    }

    /// Turn ids containing the query, in transcript order.
    private var matches: [String] {
        guard isFinding, !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return model.turns.filter { $0.matches(findQuery) }.map(\.id)
    }

    private var currentMatchIndex: Int? {
        let count = matches.count
        guard count > 0 else { return nil }
        return min(max(findCursor, 0), count - 1)
    }

    private var matchSummary: String {
        guard !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let index = currentMatchIndex else { return "No matches" }
        return "\(index + 1) of \(matches.count)"
    }

    private func advance(by step: Int = 1) {
        let count = matches.count
        guard count > 0 else { return }
        // Wraps, so holding Return walks the results rather than dead-ending.
        findCursor = ((currentMatchIndex ?? 0) + step + count) % count
    }

    private func openFind() {
        isFinding = true
        isFindFocused = true
    }

    private func closeFind() {
        isFinding = false
        findQuery = ""
        findCursor = 0
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let index = currentMatchIndex else { return }
        Bud.animate(.snappy(duration: 0.2)) {
            proxy.scrollTo(matches[index], anchor: .center)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: Bud.Space.sm) {
            StreamingIndicator()
            Text(model.statusText.isEmpty ? "Working…" : model.statusText)
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.bottom, Bud.Space.xs)
    }

    // MARK: - Drop

    /// Stages the paths of whatever was dropped.
    ///
    /// A drop is a way of pointing at something, not a way of asking about it, so
    /// nothing is sent: the paths land in the composer and stay there until the
    /// user says what they want done with them. The whole drop is staged as one
    /// string because staging each path on its own would leave the caret on
    /// whichever load finished last.
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }

        let model = model
        Task {
            var dropped: [URL] = []
            for provider in files {
                // Loading an item hands back an `NSSecureCoding` that is not
                // sendable, so it is reduced to a URL here and only that crosses
                // back to the main actor.
                let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil)
                if let url = Self.fileURL(from: item) { dropped.append(url) }
            }
            guard !dropped.isEmpty else { return }
            let files = dropped.map {
                DroppedFile(path: $0.path, name: $0.lastPathComponent, isImage: Self.isImage($0))
            }
            model.compose(model.stage(files: files), appending: true)
        }
        return true
    }

    /// A file URL arrives as an `NSURL` from some sources and as the UTF-8 bytes
    /// of the URL from others; both are file URLs by the time they are used. The
    /// check matters because a provider can hand back a plain web URL, which is
    /// nothing Bud could read.
    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL? = switch item {
        case let url as URL: url
        case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
        default: nil
        }
        return url?.isFileURL == true ? url : nil
    }

    /// The dropped paths, in the order they were dropped, plus a note for
    /// anything Bud cannot read.
    ///
    /// A picture is named rather than staged. Bud has no image input, so the path
    /// of a PNG would reach the model as a file no tool can turn into anything it
    /// can look at — the user would get an answer about a filename. Saying so is
    /// the one useful thing to do with it.
    /// Reads the content type rather than the extension: a file with no suffix, or
    /// the wrong one, still has to be recognised. This is a metadata-only query,
    /// which is what makes it cheap enough to run on the drop itself.
    private static func isImage(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // Hero and starter prompts centre together as one column, held between
        // two Spacers so the leftover height is split evenly. `.frame(alignment:
        // .center)` relies on the group reporting an honest intrinsic height and
        // came out visibly low; equal Spacers do not depend on that.
        VStack(spacing: 0) {
            Spacer(minLength: Bud.Space.lg)

            VStack(spacing: Bud.Space.lg) {
                EmptyStateView(
                    systemImage: "sparkles",
                    title: greeting.title,
                    message: greeting.message,
                    fills: false
                )

                // Two up. Four stacked prompts do not fit the height of a
                // landscape panel, and the extra width is otherwise unused.
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(starterPrompts, id: \.text) { prompt in
                        StarterPromptButton(prompt: prompt.text) {
                            Task { await model.send(prompt.text) }
                        }
                    }
                }
                // EmptyStateView already carries `Bud.Space.xl` of padding on
                // every side. Without matching padding below the prompts the
                // group's *visible* content is inset at the top but flush at the
                // bottom, which biases the optical centre low by half that
                // padding even though the frame itself is centred.
                .padding(.bottom, Bud.Space.xl)
            }

            Spacer(minLength: Bud.Space.lg)
        }
        .frame(maxWidth: Bud.contentMeasure)
        .frame(maxWidth: .infinity)
    }

    /// What the panel says before anyone has typed anything.
    private var greeting: ChatGreeting { ChatGreeting.make(from: model.conversations) }

    // MARK: - Starter prompt selection

    /// The capabilities this install can actually satisfy. Files and the browser
    /// ship with Bud; MCP and skills only count once something is set up.
    /// The prompts worth offering, `always` first, capped at four. A prompt whose
    /// capability is absent is dropped rather than offered and then failed.
    ///
    /// Pure so the promise — a fresh install is never offered a prompt it cannot
    /// satisfy — is a check rather than a hope.
    static func selectablePrompts(
        hasMCP: Bool,
        hasSkills: Bool,
        pool: [StarterPrompt] = starterPool
    ) -> [StarterPrompt] {
        var caps: Set<StarterCapability> = [.always, .files, .browser]
        if hasMCP { caps.insert(.mcp) }
        if hasSkills { caps.insert(.skills) }
        return Array(
            pool.filter { $0.capability == .always || caps.contains($0.capability) }.prefix(4)
        )
    }

    private var starterPrompts: [StarterPrompt] {
        Self.selectablePrompts(
            hasMCP: !model.mcp.servers.isEmpty,
            hasSkills: !model.skills.installedNames.isEmpty
        )
    }

    // MARK: - Budget banner

    /// The banner is a warning, not a streamer: mid-turn it would flicker as the
    /// budget climbs, and a suggestion to compact is nonsense while the model is
    /// still answering.
    private var showsBudgetBanner: Bool {
        !model.isStreaming && model.isNearBudget
    }

    private func startNewChat() {
        compactSummary = nil
        model.newConversation()
    }
}

/// The line above the starter prompts.
///
/// Two states, and the interesting one is not the first. An install that has been
/// used says where you left off, which is the difference between a tool and
/// someone who was there: you do not have to re-explain yourself to something that
/// was paying attention. A fresh install has nothing to remember and introduces
/// itself instead — one sentence about what it can do and one about what it will
/// not pretend to, rather than a list of features, which nobody reads and which
/// reads as a boast.
///
/// Separate from the view because it is the only part of the empty state with a
/// decision in it, and the decision has an edge: the newest conversation is not
/// always one that can be named.
struct ChatGreeting: Equatable {
    let title: String
    let message: String

    static func make(from conversations: [ConversationSummary]) -> ChatGreeting {
        // The newest conversation may be one nobody said anything in — a chat that
        // was opened and abandoned has no title to quote, and naming it would
        // produce "you were on """ rather than a sentence. The next one down is
        // the most recent thing actually worth resuming.
        guard let last = conversations.first(where: { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return introduction }

        return ChatGreeting(
            title: "Where you left off",
            message: "You were on \u{201C}\(last.title)\u{201D} "
                + "\(last.updatedAt.formatted(.relative(presentation: .named))). "
                + "Carry on in History, or start something new."
        )
    }

    /// What a fresh install sees. Not a feature list: what it can do, and the one
    /// thing about it that is worth knowing before you trust an answer.
    static let introduction = ChatGreeting(
        title: "Ask me something",
        message: "I can run things on this Mac, read your files, and go and find out. "
            + "I'll say so when I'm guessing."
    )
}

// MARK: - Empty-state prompt

private struct StarterPromptButton: View {
    let prompt: String
    let action: () -> Void

    @BudState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Bud.Palette.accent)
                Text(prompt)
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Bud.Space.md)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.12 : 0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovering ? 0.24 : 0.12), lineWidth: 0.6)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Drop affordance

/// The panel's answer to a drag that is over it.
///
/// It sits on top of the content instead of replacing it, and it takes no hit
/// testing: a drag that passes over Bud on its way somewhere else must leave the
/// composer exactly as the user left it, with their caret where they put it.
private struct DropAffordance: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Bud.Radius.card, style: .continuous)
                .fill(Bud.Palette.accent.opacity(0.08))

            RoundedRectangle(cornerRadius: Bud.Radius.card, style: .continuous)
                .strokeBorder(
                    Bud.Palette.accent.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )

            VStack(spacing: Bud.Space.sm) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 18, weight: .semibold))
                Text("Drop to add paths to your question")
                    .font(Bud.Font.callout)
            }
            .foregroundStyle(Bud.Palette.accent)
            .padding(.horizontal, Bud.Space.lg)
            .padding(.vertical, Bud.Space.md)
            .glassEffect(.regular, in: .rect(cornerRadius: Bud.Radius.control))
        }
        .padding(Bud.Space.sm)
        .allowsHitTesting(false)
    }
}
