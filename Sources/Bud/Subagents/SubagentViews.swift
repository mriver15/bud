import SwiftUI

/// The delegation surfaces: what Bud can hand work to, and what it has handed work
/// to.
///
/// It used to be one thing — a feed of runs — which meant the screen was empty
/// until something had run, and said nothing at all about what *could* be
/// delegated to. Two panes, because the two questions are asked at different times:
/// "what is happening" is watched, and "what can I give this to" is looked up.
public struct SubagentPanel: View {
    private let supervisor: SubagentSupervisor
    private let model: AppModel
    @BudState private var expanded: String?
    @BudState private var expandedAgent: String?
    /// Nil until the user picks, so the first view can be the informative one
    /// rather than the empty one.
    @BudState private var chosen: Pane?

    public enum Pane: String, CaseIterable, Identifiable {
        case delegates = "Delegates"
        case activity = "Activity"
        public var id: String { rawValue }
    }

    /// `pane` fixes the opening view. The app leaves it nil so the first one can be
    /// the informative one; the render harness sets it, because a screenshot has to
    /// show a specific pane.
    public init(supervisor: SubagentSupervisor, model: AppModel, pane: Pane? = nil) {
        self.supervisor = supervisor
        self.model = model
        self._chosen = BudState(wrappedValue: pane)
    }

    /// The roster looks best when there is nothing to watch, and the run feed is
    /// the urgent one when there is.
    private var pane: Pane {
        chosen ?? (supervisor.runs.isEmpty ? .delegates : .activity)
    }

    private var binding: Binding<Pane> {
        Binding(get: { pane }, set: { chosen = $0 })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Bud.Space.md)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.6)

            switch pane {
            case .delegates: delegates
            case .activity: activity
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The roster is built from the installed skills and the connected servers,
        // so it is rebuilt when either changes rather than on a timer.
        .task(id: rosterKey) { model.agents.refresh() }
    }

    private var rosterKey: String {
        let servers = model.mcp.servers.map { "\($0.name):\($0.enabled)" }.sorted().joined(separator: ",")
        return servers + "|" + model.skills.installedNames.sorted().joined(separator: ",")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Bud.Space.sm) {
            SectionHeader("Agents", subtitle: subtitle, systemImage: "person.3.sequence")
            Spacer(minLength: Bud.Space.sm)

            Picker("", selection: binding) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            if pane == .activity, supervisor.runs.contains(where: { $0.state.isTerminal }) {
                Button("Clear finished") {
                    withAnimation(.snappy(duration: 0.18)) { supervisor.clearFinished() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .font(Bud.Font.caption)
            }
        }
    }

    /// The cap is read from the live config rather than remembered here: the user
    /// can change it in Settings while the panel is open.
    private var subtitle: String {
        switch pane {
        case .delegates:
            let count = model.agents.agents.count
            return count == 1 ? "1 thing to hand work to" : "\(count) things to hand work to"
        case .activity:
            let capacity = max(1, model.config.allowParallelSubagents)
            guard !supervisor.runs.isEmpty else {
                return "Up to \(capacity) workstreams at once"
            }
            let running = supervisor.runs.count { $0.state == .running }
            let queued = supervisor.runs.count { $0.state == .queued }
            var parts = ["\(running) of \(capacity) running"]
            if queued > 0 { parts.append("\(queued) queued") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Delegates

    private var delegates: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Bud.Space.md) {
                ForEach(model.agents.grouped, id: \.group) { group in
                    VStack(alignment: .leading, spacing: Bud.Space.sm) {
                        Text(group.group.uppercased())
                            .font(Bud.Font.micro.weight(.bold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                        ForEach(group.agents) { agent in
                            delegate(agent)
                        }
                    }
                }
            }
            .padding(.horizontal, Bud.Space.lg)
            .padding(.vertical, Bud.Space.md)
        }
    }

    private func delegate(_ agent: AgentDefinition) -> some View {
        let isExpanded = expandedAgent == agent.id
        return GlassCard(padding: Bud.Space.sm) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        expandedAgent = isExpanded ? nil : agent.id
                    }
                } label: {
                    HStack(alignment: .top, spacing: Bud.Space.sm) {
                        Image(systemName: agent.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Bud.Palette.accent)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: Bud.Space.xs) {
                            Text(agent.name)
                                .font(Bud.Font.body)
                                .lineLimit(1)
                            Text(agent.summary)
                                .font(Bud.Font.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: Bud.Space.xs) {
                            GlassChip(agent.toolSummary, systemImage: "wrench.and.screwdriver")
                            if let model = agent.model {
                                GlassChip(model, systemImage: "cpu")
                            }
                        }
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: Bud.Space.sm) {
                        HStack(spacing: Bud.Space.xs) {
                            GlassChip(agent.origin.label, systemImage: agent.origin.symbol)
                            if agent.isReadOnly {
                                GlassChip("Read only", systemImage: "eye")
                            }
                        }
                        field("What it is told") {
                            Text(agent.instructions)
                                .font(Bud.Font.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: Activity

    private var activity: some View {
        Group {
            if supervisor.runs.isEmpty {
                EmptyStateView(
                    systemImage: "person.3.sequence",
                    title: "Nothing delegated yet",
                    message: """
                    When Bud splits a request into independent workstreams, each one \
                    appears here with its own progress, reasoning and findings. The \
                    Delegates tab lists what it can hand work to.
                    """
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: Bud.Space.sm) {
                        ForEach(orderedRuns, id: \.run.id) { entry in
                            row(entry.run, isChild: entry.isChild)
                        }
                    }
                    .padding(.horizontal, Bud.Space.lg)
                    .padding(.vertical, Bud.Space.md)
                }
            }
        }
    }

    /// Roots in their own order, each followed by whatever it delegated.
    ///
    /// A child is inserted at the front when it starts, so it would otherwise
    /// appear *above* the run that asked for it — a tree drawn upside down, and one
    /// where an indented row's parent is somewhere below.
    private var orderedRuns: [(run: SubagentRun, isChild: Bool)] {
        let known = Set(supervisor.runs.map(\.id))
        var ordered: [(SubagentRun, Bool)] = []
        for run in supervisor.runs where run.parentID == nil || !known.contains(run.parentID!) {
            ordered.append((run, false))
            for child in supervisor.runs where child.parentID == run.id {
                ordered.append((child, true))
            }
        }
        return ordered
    }

    private func row(_ run: SubagentRun, isChild: Bool) -> some View {
        let isExpanded = expanded == run.id
        return GlassCard(padding: Bud.Space.sm) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        expanded = isExpanded ? nil : run.id
                    }
                } label: {
                    summary(run, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)

                if run.state == .running {
                    ShimmerBar()
                }
                if isExpanded {
                    detail(run)
                }
            }
        }
        // Indented rather than filed elsewhere: which run asked for this one is
        // the first thing worth knowing about it.
        .padding(.leading, isChild ? Bud.Space.lg : 0)
    }

    private func summary(_ run: SubagentRun, isExpanded: Bool) -> some View {
        HStack(spacing: Bud.Space.sm) {
            StateDot(color: color(for: run.state), pulsing: run.state == .running)

            VStack(alignment: .leading, spacing: Bud.Space.xs) {
                HStack(spacing: Bud.Space.xs) {
                    if let agent = run.agent {
                        Image(systemName: "person.crop.square.filled.and.at.rectangle")
                            .font(.system(size: 10))
                            .foregroundStyle(Bud.Palette.accent)
                        Text(agent)
                            .font(Bud.Font.caption.weight(.semibold))
                            .foregroundStyle(Bud.Palette.accent)
                    }
                    Text(run.title)
                        .font(Bud.Font.body)
                        .lineLimit(1)
                }

                HStack(spacing: Bud.Space.xs) {
                    GlassChip(run.model, systemImage: "cpu")
                    GlassChip(
                        run.state.label,
                        tint: color(for: run.state),
                        isActive: run.state == .running
                    )
                    if run.state != .queued {
                        elapsedChip(run)
                    }
                    if run.toolCallCount > 0 {
                        GlassChip(
                            run.toolCallCount == 1 ? "1 tool call" : "\(run.toolCallCount) tool calls",
                            systemImage: "wrench.and.screwdriver"
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(Bud.Font.micro.weight(.bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
    }

    /// Elapsed time has to keep ticking between stream events, so the clock chip
    /// runs its own timeline instead of recomputing only when the run changes.
    private func elapsedChip(_ run: SubagentRun) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GlassChip(BudFormat.duration(elapsed(run, at: context.date)), systemImage: "clock")
        }
    }

    private func elapsed(_ run: SubagentRun, at now: Date) -> TimeInterval {
        max(0, (run.finishedAt ?? now).timeIntervalSince(run.startedAt))
    }

    // MARK: Detail

    private func detail(_ run: SubagentRun) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            field("Prompt") {
                Text(run.prompt)
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !run.reasoning.isEmpty {
                DisclosureGroup {
                    Text(run.reasoning)
                        .font(Bud.Font.caption.weight(.regular))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Bud.Space.xs)
                } label: {
                    Text("Reasoning")
                        .font(Bud.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = run.error, !error.isEmpty {
                field("Failed") {
                    Text(error)
                        .font(Bud.Font.callout)
                        .foregroundStyle(Bud.Palette.danger)
                        .textSelection(.enabled)
                }
            }

            if !run.toolCalls.isEmpty {
                field("Tool calls") {
                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        ForEach(run.toolCalls) { call in
                            HStack(alignment: .firstTextBaseline, spacing: Bud.Space.xs) {
                                Image(systemName: call.succeeded ? "checkmark.circle" : "xmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(call.succeeded ? Bud.Palette.success : Bud.Palette.danger)
                                Text(call.name)
                                    .font(Bud.Font.caption.weight(.semibold))
                                    .lineLimit(1)
                                if !call.preview.isEmpty {
                                    Text(call.preview)
                                        .font(Bud.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }

            field("Findings") {
                if run.output.isEmpty {
                    Text(run.state == .running ? "Still working…" : "No output.")
                        .font(Bud.Font.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    // Findings are markdown in practice (headings, lists, fenced
                    // code), and the caret keeps a live run reading as live text.
                    MarkdownView(run.output, showsCaret: run.state == .running)
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            Text(label.uppercased())
                .font(Bud.Font.micro.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for state: SubagentState) -> Color {
        switch state {
        case .queued: return .secondary
        case .running: return Bud.Palette.accent
        case .done: return Bud.Palette.success
        case .failed: return Bud.Palette.danger
        case .cancelled: return Bud.Palette.warning
        }
    }
}

// MARK: - Shimmer

/// Indeterminate progress for a live run: a highlight that sweeps the track
/// while the model works. `ProgressView` is deliberately not used — a spinner
/// says "waiting", and this says "working".
struct ShimmerBar: View {
    @BudState private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Bud.Palette.accent.opacity(0.55),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: phase * geo.size.width)
                )
                .clipShape(Capsule())
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        phase = 1.2
                    }
                }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
