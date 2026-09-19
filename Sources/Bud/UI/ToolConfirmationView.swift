import SwiftUI

/// The surface that stands between the agent and the machine.
///
/// It covers the panel rather than sitting beside it, because the answer is the
/// only thing that can happen next: anything else on screen is a distraction from
/// a decision that has a command paused behind it. It cannot be dismissed without
/// an answer either — a stray click that silently means "no" is indistinguishable
/// from a bug, and a stray click that silently means "yes" is worse.
struct ToolConfirmationView: View {
    let request: ToolConfirmation
    let onAnswer: (ToolConfirmation.Decision) -> Void

    var body: some View {
        ZStack {
            // Held below full opacity so the transcript stays legible: the command
            // is often worth reading in the context of what the model said it was
            // doing.
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: Bud.Space.md) {
                heading
                detail
                actions
            }
            .padding(Bud.Space.lg)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: Bud.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Bud.Radius.card)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .padding(Bud.Space.lg)
        }
        // Return allows and Escape denies, because a dialog in front of a keystroke
        // is one that should answer to the keyboard.
        .onKeyPress(.return) {
            onAnswer(.allow)
            return .handled
        }
        .onKeyPress(.escape) {
            onAnswer(.deny)
            return .handled
        }
    }

    private var heading: some View {
        HStack(spacing: Bud.Space.sm) {
            Image(systemName: request.risk.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(request.headline)
                .font(Bud.Font.title)
            // The class, not the tool: "running a command" and "writing a file"
            // are different decisions, and the label is what keeps them apart.
            GlassChip(request.risk.label, tint: riskTint, isActive: true)
            Spacer(minLength: 0)
            if let note = request.note {
                Text(note)
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The class's colour, so a command reads as dangerous at a glance while a
    /// write reads as routine.
    private var riskTint: Color {
        switch request.risk {
        case .read, .externalRead: return Color.secondary
        case .localWrite: return Bud.Palette.accent
        case .execution: return Bud.Palette.danger
        case .externalMutation: return Bud.Palette.warning
        }
    }

    /// Whether the dialog may offer the directory scope. Only a class with a
    /// meaningful directory — a write's parent, a command's working directory —
    /// offers it; a provider-side mutation has no such place.
    private var supportsDirectoryScope: Bool {
        request.risk == .execution || request.risk == .localWrite
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Bud.Space.sm) {
            // Verbatim and selectable: the point of showing a command is that it
            // can be read for what it actually does, and copied elsewhere to check.
            Text(request.detail)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Bud.Space.sm)
                .background(.black.opacity(0.22), in: .rect(cornerRadius: Bud.Radius.control))

            if let preview = request.preview {
                VStack(alignment: .leading, spacing: Bud.Space.xs) {
                    Text("Starts with")
                        .font(Bud.Font.callout)
                        .foregroundStyle(.secondary)
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Bud.Space.sm) {
            Button("Deny") { onAnswer(.deny) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)

            if supportsDirectoryScope {
                Button("Allow for this directory") { onAnswer(.allowForDirectory) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button("Allow for session") { onAnswer(.allowForSession) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Button("Allow") { onAnswer(.allow) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
