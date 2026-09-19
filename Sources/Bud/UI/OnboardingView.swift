import SwiftUI

/// The first-run flow, shown as a sheet over the panel.
///
/// Three steps: pick a provider, prove the connection works, finish with a first
/// response. The copy is plain — this is the one time the panel has to explain
/// itself to someone who has never seen it, and cheer or apology would read as
/// filler next to a credential field.
struct OnboardingView: View {
    @Bindable var state: OnboardingState
    let onDismiss: () -> Void

    var body: some View {
        GlassPanel(cornerRadius: Bud.Radius.panel) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.25)
                ScrollView {
                    stepContent
                        .padding(Bud.Space.lg)
                }
                Divider().opacity(0.25)
                footer
            }
        }
        .frame(width: 520, height: 520)
        .padding(Bud.Space.md)
        .background(Color.clear)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            HStack(spacing: Bud.Space.md) {
                Text("Set up Bud")
                    .font(Bud.Font.hero)
                Spacer(minLength: 0)
                stepDots
            }
            Text(subtitle)
                .font(Bud.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Bud.Space.lg)
    }

    private var subtitle: String {
        switch state.step {
        case .choose:
            return "Bud needs a provider to talk to before it can answer anything. Pick one."
        case .test:
            if let provider = state.chosenProvider {
                return "Make sure \(provider.name) answers before you rely on it."
            }
            return "Check the connection."
        case .done:
            return "That's it. Bud will ask its first question now."
        }
    }

    private var stepDots: some View {
        HStack(spacing: Bud.Space.xs) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == currentStepIndex ? Bud.Palette.accent : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var currentStepIndex: Int {
        switch state.step {
        case .choose: return 0
        case .test: return 1
        case .done: return 2
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        switch state.step {
        case .choose: chooseStep
        case .test: testStep
        case .done: doneStep
        }
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: Bud.Space.lg) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                SectionHeader(
                    "On this Mac",
                    subtitle: "Runs locally. No key, no account.",
                    systemImage: "desktopcomputer"
                )
                GlassCard {
                    if state.detectedLocalRuntimes.isEmpty {
                        Text(
                            "Nothing found — Ollama and LM Studio aren't running. "
                                + "Your first answer will come from a hosted provider; "
                                + "you can switch to a local one later in Settings."
                        )
                        .font(Bud.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: Bud.Space.xs) {
                            ForEach(state.detectedLocalRuntimes) { provider in
                                providerRow(
                                    title: provider.name,
                                    subtitle: detectedModelLine(for: provider.id),
                                    systemImage: "checkmark.circle.fill"
                                ) {
                                    state.chooseLocal(provider.id)
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                SectionHeader(
                    "Hosted",
                    subtitle: "Needs an API key from the provider.",
                    systemImage: "cloud"
                )
                GlassCard {
                    VStack(alignment: .leading, spacing: Bud.Space.xs) {
                        ForEach(state.hostedProviders) { provider in
                            providerRow(
                                title: provider.name,
                                subtitle: provider.defaultModel,
                                systemImage: "link"
                            ) {
                                state.chooseHosted(provider.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func detectedModelLine(for providerID: String) -> String? {
        let model: String? = switch providerID {
        case "ollama": state.detection?.ollamaModel
        case "lmstudio": state.detection?.lmStudioModel
        default: nil
        }
        guard let model else { return nil }
        return "Detected — model \(model)"
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: Bud.Space.lg) {
            if let provider = state.chosenProvider {
                VStack(alignment: .leading, spacing: Bud.Space.sm) {
                    SectionHeader(
                        state.needsKey
                            ? "\(provider.name) credentials"
                            : provider.name,
                        subtitle: state.needsKey
                            ? "Kept in ~/.bud/config.json with owner-only permissions."
                            : "Running on this Mac. No key needed.",
                        systemImage: state.needsKey ? "key" : "desktopcomputer"
                    )
                    GlassCard {
                        VStack(alignment: .leading, spacing: Bud.Space.md) {
                            if state.needsKey {
                                VStack(alignment: .leading, spacing: Bud.Space.xs) {
                                    Text("API key")
                                        .font(Bud.Font.caption)
                                        .foregroundStyle(.secondary)
                                    SecureField(
                                        "Paste the key for \(provider.name)",
                                        text: $state.apiKeyInput
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(Bud.Font.mono)
                                    if state.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        missingKeyNote
                                    }
                                }
                            } else {
                                Text("\(provider.name) answered on this Mac. Test it below.")
                                    .font(Bud.Font.callout)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: Bud.Space.xs) {
                                Text("Model")
                                    .font(Bud.Font.caption)
                                    .foregroundStyle(.secondary)
                                TextField("model-id", text: $state.modelIDInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Bud.Font.mono)
                                Text("Sent verbatim to \(provider.name).")
                                    .font(Bud.Font.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            testResult
        }
    }

    /// Where Bud looked for a key, and why a Finder launch sees less than a
    /// terminal — the one thing that makes "I already exported it" and "Bud
    /// cannot see it" different.
    private var missingKeyNote: some View {
        Text(
            "Bud looked in ~/.bud/config.json, then the process environment, then your "
                + "shell profile (~/.zshrc, ~/.zprofile, ~/.bash_profile, ~/.profile). "
                + "A Finder launch inherits none of a terminal's environment, so a key "
                + "you exported in a shell only shows up if it's in one of those."
        )
        .font(Bud.Font.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var testResult: some View {
        switch state.testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: Bud.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
            }
        case .passed:
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Bud.Palette.success)
                Text("Connected. \(state.chosenProvider?.name ?? "The provider") answered.")
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Bud.Palette.warning)
                Text(message)
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Bud.Space.md) {
            if let provider = state.chosenProvider {
                GlassCard {
                    VStack(alignment: .leading, spacing: Bud.Space.sm) {
                        Text("\(provider.name) is set up.")
                            .font(Bud.Font.title)
                        Text(
                            "Bud will ask “What can you do on this Mac?” and you'll watch "
                                + "the answer come back. Everything here can be changed "
                                + "later in Settings."
                        )
                        .font(Bud.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func providerRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Bud.Space.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Bud.Palette.accent)
                VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                    Text(title)
                        .font(Bud.Font.body)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Bud.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Bud.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Bud.Space.sm) {
            if state.step != .choose {
                Button("Back") { goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button("Skip — use Bud locally later") { skip() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            primaryButton
        }
        .padding(Bud.Space.lg)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state.step {
        case .choose:
            EmptyView()
        case .test:
            if state.testState == .passed {
                Button("Continue") { state.step = .done }
                    .buttonStyle(.borderedProminent)
                    .tint(Bud.Palette.accent)
            } else {
                Button("Test connection") {
                    Task { await state.testConnection() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Bud.Palette.accent)
                .disabled(state.testState == .testing)
            }
        case .done:
            Button("Finish") {
                onDismiss()
                Task { await state.finish() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Bud.Palette.accent)
        }
    }

    private func goBack() {
        switch state.step {
        case .choose: break
        case .test: state.step = .choose
        case .done: state.step = .test
        }
    }

    private func skip() {
        state.skip()
        onDismiss()
    }
}
