import SwiftUI

/// The chat surface: transcript, live status strip, error banner, composer.
///
/// Everything here is transparent — the panel's glass is the only background.
public struct ChatView: View {
    private let model: AppModel

    @BudState private var isNearBottom = true
    @BudState private var isUserScrolling = false

    private static let bottomAnchor = "bud.chat.bottom"
    private static let starterPrompts = [
        "What tools do you have right now?",
        "Show me a dashboard of this Mac's health",
        "List what is in my home directory and summarise it",
        "Research two options in parallel and compare them",
    ]

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
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

            Composer(model: model)
                .padding(.horizontal, Bud.Space.md)
                .padding(.top, Bud.Space.xs)
                .padding(.bottom, Bud.Space.md)
                .contentColumn()
        }
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
                    ForEach(model.turns) { turn in
                        TranscriptRow(turn: turn, model: model)
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Tolerance, not equality: content grows between frames while
                // streaming, so an exact bottom test would drop the follow after
                // a single delta.
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 140
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase != .idle
            }
            .onChange(of: streamSignature) { _, _ in
                guard isNearBottom, !isUserScrolling else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.turns.count) { _, _ in
                // A new turn only ever follows the reader's own send, so this
                // one re-engages following even if history was being read.
                isNearBottom = true
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// Only the trailing turn moves while streaming, so hashing it (plus the turn
    /// count) is enough to know the transcript's height changed.
    private var streamSignature: Int {
        guard let last = model.turns.last else { return 0 }
        var total = model.turns.count
        for segment in last.segments {
            switch segment {
            case .reasoning(_, let text), .text(_, let text), .notice(_, let text, _):
                total = total &+ text.count &+ 1
            case .tool(_, _, _, let state, let result, let ui):
                total = total &+ state.rawValue.count &+ (result?.count ?? 0) &+ (ui == nil ? 0 : 1)
            }
        }
        return total
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
                    title: "Bud is ready",
                    message: "Ask anything. Bud can search, call your MCP tools, fan work out to subagents, and render results as a surface instead of prose.",
                    fills: false
                )

                // Two up. Four stacked prompts do not fit the height of a
                // landscape panel, and the extra width is otherwise unused.
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(Self.starterPrompts, id: \.self) { prompt in
                        StarterPromptButton(prompt: prompt) {
                            Task { await model.send(prompt) }
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
}

/// Holds a row to the content measure and centres it in the panel.
private struct ContentColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Bud.contentMeasure, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    fileprivate func contentColumn() -> some View { modifier(ContentColumn()) }
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
