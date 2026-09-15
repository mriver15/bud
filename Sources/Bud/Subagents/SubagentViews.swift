import SwiftUI

/// The subagent roster: what Bud has delegated, what each workstream is doing
/// right now, and what it came back with.
///
/// The rows are driven by the supervisor's published `runs`, so the panel is a
/// live view of the pool rather than a log: reasoning and output stream into a
/// row while its model is still talking.
public struct SubagentPanel: View {
    private let supervisor: SubagentSupervisor
    private let model: AppModel
    @BudState private var expanded: String?

    public init(supervisor: SubagentSupervisor, model: AppModel) {
        self.supervisor = supervisor
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Bud.Space.lg)
                .padding(.top, Bud.Space.lg)
                .padding(.bottom, Bud.Space.md)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.6)

            if supervisor.runs.isEmpty {
                EmptyStateView(
                    systemImage: "person.3.sequence",
                    title: "No subagents yet",
                    message: """
                    When Bud splits a request into independent workstreams, each one \
                    appears here with its own progress, reasoning and findings.
                    """
                )
            } else {
                roster
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Bud.Space.sm) {
            SectionHeader("Subagents", subtitle: poolSummary, systemImage: "person.3.sequence")
            Spacer(minLength: Bud.Space.sm)
            if supervisor.runs.contains(where: { $0.state.isTerminal }) {
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
    private var poolSummary: String {
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

    // MARK: Roster

    private var roster: some View {
        ScrollView {
            LazyVStack(spacing: Bud.Space.sm) {
                ForEach(supervisor.runs) { run in
                    row(run)
                }
            }
            .padding(.horizontal, Bud.Space.lg)
            .padding(.vertical, Bud.Space.md)
        }
    }

    private func row(_ run: SubagentRun) -> some View {
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
    }

    private func summary(_ run: SubagentRun, isExpanded: Bool) -> some View {
        HStack(spacing: Bud.Space.sm) {
            StateDot(color: color(for: run.state), pulsing: run.state == .running)

            VStack(alignment: .leading, spacing: 3) {
                Text(run.title)
                    .font(Bud.Font.body)
                    .lineLimit(1)

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
                .font(.system(size: 9, weight: .bold))
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
                        .font(.system(size: 11.5))
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
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
/// inside a glass card reads as noise, and this row already has a state dot.
private struct ShimmerBar: View {
    @BudState private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Bud.Palette.accent.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Bud.Palette.accent.opacity(0),
                                    Bud.Palette.accent.opacity(0.85),
                                    Bud.Palette.accent.opacity(0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(24, proxy.size.width * 0.35))
                        .offset(x: phase * proxy.size.width)
                }
                .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1.35
            }
        }
        .accessibilityHidden(true)
    }
}
