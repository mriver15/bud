import SwiftUI
import UniformTypeIdentifiers

/// The chat surface: transcript, live status strip, error banner, composer.
///
/// Everything here is transparent — the panel's glass is the only background.
public struct ChatView: View {
    private let model: AppModel

    @BudState private var isNearBottom = true
    @BudState private var isUserScrolling = false
    @BudState private var isDropTargeted = false

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
        .animation(.snappy(duration: 0.14), value: isDropTargeted)
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
                        TranscriptRow(
                            turn: turn,
                            model: model,
                            isLatest: turn.id == model.turns.last?.id
                        )
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
            model.compose(Self.stagingText(for: dropped), appending: true)
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
    private static func stagingText(for urls: [URL]) -> String {
        var paths: [String] = []
        var images: [String] = []
        for url in urls {
            if isImage(url) {
                images.append(url.lastPathComponent)
            } else {
                paths.append(url.path)
            }
        }
        if !images.isEmpty {
            let noun = images.count == 1 ? "image" : "images"
            paths.append("(\(images.count) \(noun) dropped — Bud cannot read image files yet: \(images.joined(separator: ", ")))")
        }
        return paths.joined(separator: "\n")
    }

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
