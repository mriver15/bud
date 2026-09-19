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

    @BudState private var rowWidth: CGFloat = 0
    @BudState private var isHovering = false
    @BudState private var didCopy = false

    private let isLatest: Bool
    /// The live find query, or nil when nothing is being searched for.
    private let highlight: String?
    /// Whether a search is running and this turn is not one of its results.
    private let isDimmed: Bool

    public init(
        turn: Turn,
        model: AppModel,
        isLatest: Bool = false,
        highlight: String? = nil,
        isDimmed: Bool = false
    ) {
        self.turn = turn
        self.model = model
        self.isLatest = isLatest
        self.highlight = highlight
        self.isDimmed = isDimmed
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
        // Dimmed rather than hidden: a result is easier to place when the turns
        // around it are still there. Only prose is marked inside a matching turn
        // — reasoning and tool output are where a match may be, but they render
        // through their own views, so a hit there is found by reading the turn
        // rather than by the highlight.
        .opacity(isDimmed ? 0.28 : 1)
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

            ForEach(segmentRows) { row in
                switch row {
                case .single(let segment):
                    segmentView(segment)
                case .toolGroup(let segments):
                    ToolRoundGroup(segments: segments, model: model, isTail: { isTail($0) })
                }
            }

            if let error = turn.error, !error.isEmpty {
                TurnErrorNote(message: error)
            }

            if !turn.isStreaming, !turnFooterItems.isEmpty {
                turnFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The segment stream, with each round's concurrent tool calls folded into
    /// one group. Tool segments are the only ones that can run together, so a
    /// run of two or more is exactly one round; a lone tool renders as itself,
    /// because there is nothing to fold it into and nothing concurrent to count.
    private var segmentRows: [SegmentRow] {
        var rows: [SegmentRow] = []
        var toolRun: [Segment] = []

        func flush() {
            if toolRun.count > 1 {
                rows.append(.toolGroup(toolRun))
            } else if let single = toolRun.first {
                rows.append(.single(single))
            }
            toolRun = []
        }

        for segment in turn.segments {
            if case .tool = segment {
                toolRun.append(segment)
            } else {
                flush()
                rows.append(.single(segment))
            }
        }
        flush()
        return rows
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .reasoning(let id, let text):
            // Not drawn at all when it is turned off. A collapsed disclosure is
            // still a line in the transcript saying the model thought, which is a
            // different thing from asking it not to say so.
            if model.config.reasoningVisibility != .hidden {
                ReasoningDisclosure(
                    text: text,
                    isStreaming: isTail(id),
                    duration: Date().timeIntervalSince(turn.createdAt),
                    visibility: model.config.reasoningVisibility
                )
            }

        case .text(let id, let text):
            MarkdownView(text, showsCaret: isTail(id), highlight: highlight)

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

    // MARK: - Footer

    /// The measured facts for a completed turn, in order: prompt tokens in,
    /// completion tokens out, cached tokens, tool calls, wall time. A nil
    /// measurement is left out rather than rendered as "0" — a guess dressed up
    /// as a fact. Restored turns predate the instrumentation, so their token and
    /// wall-time fields are nil and the footer shrinks to whatever is still
    /// knowable.
    private var turnFooterItems: [String] {
        var items: [String] = []
        if let prompt = turn.promptTokens {
            items.append("\(BudFormat.tokens(prompt)) in")
        }
        if let completion = turn.completionTokens {
            items.append("\(BudFormat.tokens(completion)) out")
        }
        if let cached = turn.cachedTokens {
            items.append("\(BudFormat.tokens(cached)) cached")
        }
        let tools = turn.segments.reduce(into: 0) { count, segment in
            if case .tool = segment { count += 1 }
        }
        if tools > 0 {
            items.append(tools == 1 ? "1 tool" : "\(tools) tools")
        }
        if let duration = turn.duration {
            items.append(BudFormat.duration(duration))
        }
        return items
    }

    private var turnFooter: some View {
        Text(turnFooterItems.joined(separator: " · "))
            .font(Bud.Font.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.top, Bud.Space.xs)
    }
}

/// One row of the assistant's segment stream: a single segment (a lone tool, or
/// any non-tool segment), or a run of two or more tool segments that were asked
/// for together and ran concurrently.
private enum SegmentRow: Identifiable {
    case single(Segment)
    case toolGroup([Segment])

    var id: String {
        switch self {
        case .single(let segment): return segment.id
        case .toolGroup(let segments): return segments[0].id
        }
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
    let visibility: ReasoningVisibility

    /// Set the moment the reader opens or closes it, and wins from then on. Before
    /// that the mode decides, which is what lets a turn fold itself away when the
    /// answer lands without fighting anyone who opened it deliberately.
    @BudState private var chosen: Bool?

    private var isExpanded: Bool {
        visibility.isExpanded(isStreaming: isStreaming, chosen: chosen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { chosen = !isExpanded }
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
                    if !isExpanded, !text.isEmpty {
                        Text("· \(text.count > 2_000 ? "long" : "\(text.count) characters")")
                            .foregroundStyle(.tertiary)
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

/// A round of concurrent tool calls: one compact header (how many, how long)
/// above the individual tool rows, which stay one-line summaries that expand to
/// their result. Nothing is hidden by the header — it only names what the block
/// below it already was.
private struct ToolRoundGroup: View {
    let segments: [Segment]
    let model: AppModel
    let isTail: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            roundHeader
            ForEach(segments) { segment in
                if case .tool(let id, let call, let providerName, let state, let resultText, let ui) = segment {
                    ToolActivityRow(
                        call: call,
                        providerName: providerName,
                        state: state,
                        resultText: resultText,
                        ui: ui,
                        model: model,
                        isTail: isTail(id)
                    )
                }
            }
        }
    }

    /// "3 tools · 2.4s", the duration dropped when the round's clock was not
    /// recorded — a restored turn predates the instrumentation, and a missing
    /// span is a missing fact, not a zero.
    private var roundHeader: some View {
        Text(headerText)
            .font(Bud.Font.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.leading, Bud.Space.xs)
    }

    private var headerText: String {
        let count = segments.count
        let tools = count == 1 ? "1 tool" : "\(count) tools"
        guard let duration = roundDuration else { return tools }
        return "\(tools) · \(BudFormat.duration(duration))"
    }

    /// The wall-clock span of the round, from the first call starting to the last
    /// result landing. Calls in a round run concurrently, so summing their
    /// individual times would over-count; the span is the time the round took.
    private var roundDuration: TimeInterval? {
        var firstStart: Date?
        var lastEnd: Date?
        for segment in segments {
            guard case .tool(_, let call, _, _, _, _) = segment else { continue }
            if let started = call.startedAt {
                firstStart = min(firstStart ?? started, started)
            }
            if let ended = call.endedAt {
                lastEnd = max(lastEnd ?? ended, ended)
            }
        }
        guard let firstStart, let lastEnd else { return nil }
        return lastEnd.timeIntervalSince(firstStart)
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
