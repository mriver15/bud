import SwiftUI

/// Renders one transcript turn: a tinted bubble for the user, and the ordered
/// segment stream — reasoning, prose, tool activity, generated surfaces — for
/// the assistant. Segments are rendered in arrival order because that is the
/// order the model produced them, and reordering (say, prose then tools) would
/// misrepresent how the answer was reached.
public struct TranscriptRow: View {
    private let turn: Turn
    private let model: AppModel
    /// The newest turn in the transcript. Its actions are always on show, because
    /// the answer just received is the one anyone copies or retries, and a control
    /// that only exists once the pointer happens to cross it does not exist.
    private let isLatest: Bool

    @BudState private var rowWidth: CGFloat = 0
    @BudState private var isHovering = false
    @BudState private var didCopy = false

    public init(turn: Turn, model: AppModel, isLatest: Bool = false) {
        self.turn = turn
        self.model = model
        self.isLatest = isLatest
    }

    public var body: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: Bud.Space.xs) {
            Group {
                if turn.role == .user {
                    userBubble
                } else {
                    assistantBody
                }
            }

            // In flow rather than overlaid: an overlay would have to sit on top
            // of the text it acts on, and a fixed reserved strip under every turn
            // would cost more empty space than the transcript has to give.
            if showsActions {
                actions
            }
        }
        // The bubble's 78% cap is a fraction of the row, not of the panel, so it
        // stays correct if the panel is ever resized.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
        .onHover { isHovering = $0 }
        // The same actions on right-click. Hover is invisible until you happen to
        // pass over a turn, and the actions people most want on a bad answer are
        // the ones they go looking for.
        .contextMenu { menu }
    }

    // MARK: - Actions

    /// Nothing to offer means nothing is drawn. A turn that is only a notice has
    /// no prose to copy and, once the session ends, no exchange to retry — an
    /// empty strip under it would be spacing pretending to be a control.
    private var showsActions: Bool {
        (isHovering || isLatest) && (!copyableText.isEmpty || model.canRewind(from: turn))
    }

    private var actions: some View {
        HStack(spacing: Bud.Space.hairline) {
            if turn.role == .user { Spacer(minLength: 0) }
            if !copyableText.isEmpty {
                RowAction(symbol: didCopy ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
            }
            if model.canRewind(from: turn) {
                RowAction(symbol: "arrow.clockwise", help: "Retry") { model.retry(turn) }
            }
            if turn.role != .user { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !copyableText.isEmpty {
            Button("Copy") { copy() }
        }
        if model.canRewind(from: turn) {
            Button("Retry") { model.retry(turn) }
            Divider()
            Button("Delete from here", role: .destructive) { model.deleteFrom(turn) }
        }
    }

    /// What copying a turn means: the prose, in arrival order.
    ///
    /// Reasoning and tool activity are how the answer was reached, not the answer
    /// — pasting either is never what was wanted, and a copy button that included
    /// them would be one nobody trusted.
    private var copyableText: String {
        if turn.role == .user { return userText }
        return turn.segments.compactMap { segment in
            if case .text(_, let text) = segment { return text }
            return nil
        }
        .joined(separator: "\n\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }

    // MARK: - User

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(userText)
                .font(Bud.Font.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Bud.Space.md)
                .padding(.vertical, Bud.Space.sm)
                // A material fill, not glass. Apple's rule is that Liquid Glass
                // belongs to the navigation layer that floats above content —
                // a message bubble *is* content, and putting glass on it both
                // breaks that rule and makes the transcript shimmer as the
                // desktop moves behind the panel while you are reading it.
                .background {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                                .fill(Bud.Palette.accent.opacity(0.20))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                                .strokeBorder(Bud.Palette.accent.opacity(0.28), lineWidth: 0.6)
                        }
                }
                .frame(maxWidth: max(160, rowWidth * 0.78), alignment: .trailing)
        }
    }

    private var userText: String {
        turn.segments.compactMap { segment in
            if case .text(_, let text) = segment { return text }
            return nil
        }
        .joined(separator: "\n\n")
    }

    // MARK: - Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            if turn.segments.isEmpty, turn.isStreaming {
                StreamingIndicator("Thinking…")
            }

            ForEach(turn.segments) { segment in
                segmentView(segment)
            }

            if let error = turn.error, !error.isEmpty {
                TurnErrorNote(message: error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .reasoning(let id, let text):
            ReasoningDisclosure(
                text: text,
                isStreaming: isTail(id),
                duration: Date().timeIntervalSince(turn.createdAt)
            )

        case .text(let id, let text):
            MarkdownView(text, showsCaret: isTail(id))

        case .tool(let id, let call, let providerName, let state, let resultText, let ui):
            ToolActivityRow(
                call: call,
                providerName: providerName,
                state: state,
                resultText: resultText,
                ui: ui,
                model: model,
                isTail: isTail(id)
            )

        case .notice(_, let text, let kind):
            NoticeBanner(text: text, kind: kind)
        }
    }

    /// A segment is "in flight" when it is the last one in a still-streaming
    /// turn. Only that one gets a caret, a shimmer, or a pulse.
    private func isTail(_ id: String) -> Bool {
        turn.isStreaming && turn.segments.last?.id == id
    }
}

/// A transcript action: plain, small, and unlit until hovered.
///
/// Deliberately not `GlassIconButton`. Apple's rule puts Liquid Glass on the
/// navigation layer that floats above content, and these sit on the content they
/// act on — the same reason the message bubble is a material fill rather than
/// glass.
private struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @BudState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Reasoning

private struct ReasoningDisclosure: View {
    let text: String
    let isStreaming: Bool
    let duration: TimeInterval

    @BudState private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    if isStreaming {
                        ShimmerLabel("Thinking…")
                    } else {
                        Text("Thought for \(BudFormat.duration(duration))")
                    }
                    Spacer(minLength: 0)
                }
                .font(Bud.Font.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(Bud.Font.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(Bud.Space.sm)
                .background {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .fill(Bud.Palette.reasoning.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                                .strokeBorder(Bud.Palette.reasoning.opacity(0.22), lineWidth: 0.6)
                        }
                }
            }
        }
    }
}

// MARK: - Tool activity

private struct ToolActivityRow: View {
    let call: ToolCall
    let providerName: String
    let state: ToolRunState
    let resultText: String?
    let ui: JSONValue?
    let model: AppModel
    let isTail: Bool

    @BudState private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            header

            if let ui {
                GenerativeUIView(
                    spec: ui,
                    onAction: { action in Task { await model.submit(action: action) } },
                    onPrompt: { prompt in Task { await model.send(prompt) } }
                )
            } else if showsResult {
                resultBody
            }
        }
        .padding(Bud.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(state == .failed ? Bud.Palette.danger.opacity(0.10) : Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(
                            state == .failed ? Bud.Palette.danger.opacity(0.32) : Color.white.opacity(0.10),
                            lineWidth: 0.6
                        )
                }
        }
    }

    private var header: some View {
        Group {
            if canExpand {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    headerContent
                }
                .buttonStyle(.plain)
            } else {
                headerContent
            }
        }
    }

    private var headerContent: some View {
        HStack(alignment: .center, spacing: Bud.Space.sm) {
            stateIndicator

            VStack(alignment: .leading, spacing: Bud.Space.xs) {
                HStack(spacing: 6) {
                    Text(call.name)
                        .font(Bud.Font.mono)
                        .foregroundStyle(state == .failed ? Bud.Palette.danger : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    GlassChip(providerName)
                }
                if !argumentSummary.isEmpty {
                    Text(argumentSummary)
                        .font(Bud.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            switch state {
            case .queued, .running:
                Text(state == .queued ? "Queued" : "Running")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
            case .succeeded, .failed:
                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var stateIndicator: some View {
        ZStack {
            Circle()
                .fill(stateColor.opacity(0.18))
                .frame(width: 22, height: 22)
            Image(systemName: stateSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(stateColor)
                .symbolEffect(.pulse, options: .repeating, isActive: state == .running)
        }
    }

    private var resultBody: some View {
        ScrollView {
            Text(resultText ?? "")
                .font(Bud.Font.mono)
                .foregroundStyle(state == .failed ? Bud.Palette.danger : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(Bud.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Color.black.opacity(0.20))
        }
    }

    /// A failed call always shows its error text; a successful one waits for the
    /// reader to ask, so a long payload does not bury the conversation.
    private var showsResult: Bool {
        hasResult && (isExpanded || state == .failed)
    }

    private var canExpand: Bool {
        hasResult && ui == nil
    }

    private var hasResult: Bool {
        !(resultText ?? "").isEmpty
    }

    private var stateColor: Color {
        switch state {
        case .queued: return .secondary
        case .running: return Bud.Palette.accent
        case .succeeded: return Bud.Palette.success
        case .failed: return Bud.Palette.danger
        }
    }

    private var stateSymbol: String {
        switch state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Argument summary

    private var argumentSummary: String {
        guard let object = call.parsedArguments.objectValue, !object.isEmpty else { return "" }
        return object.keys.sorted()
            .map { "\($0)=\(summarize(object[$0] ?? .null))" }
            .joined(separator: "  ")
    }

    private func summarize(_ value: JSONValue) -> String {
        switch value {
        case .string(let text):
            return "\"\(flatten(text, limit: 40))\""
        case .null:
            return "null"
        case .bool, .number:
            return value.stringValue ?? ""
        case .array, .object:
            return flatten(value.encodedString(), limit: 48)
        }
    }

    private func flatten(_ text: String, limit: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count <= limit ? single : String(single.prefix(limit)) + "…"
    }
}

// MARK: - Notices

private struct NoticeBanner: View {
    let text: String
    let kind: NoticeKind

    var body: some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Bud.Font.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(tint.opacity(0.30), lineWidth: 0.6)
                }
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return Bud.Palette.accent
        case .warning: return Bud.Palette.warning
        case .error: return Bud.Palette.danger
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// A turn's own failure. Unlike `ErrorBanner` this is part of the transcript, so
/// it has no dismiss control — the failure is history, not a live alert.
private struct TurnErrorNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Bud.Palette.danger)
            Text(message)
                .font(Bud.Font.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Bud.Palette.danger.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(Bud.Palette.danger.opacity(0.30), lineWidth: 0.6)
                }
        }
    }
}
