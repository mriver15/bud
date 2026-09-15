import Foundation
import SwiftUI

/// Three travelling dots used wherever Bud is waiting on the model.
///
/// Driven by a `.periodic` timeline rather than `withAnimation`: a periodic
/// schedule produces its own first frame and keeps ticking even when the panel
/// is hosting without a display-linked animation, which is the case for a
/// non-activating panel that has just been shown.
public struct StreamingIndicator: View {
    private let label: String?

    public init(_ label: String? = nil) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: Bud.Space.snug) {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                HStack(spacing: Bud.Space.xs) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Bud.Palette.accent)
                            .frame(width: 4.5, height: 4.5)
                            .opacity(opacity(index, at: context.date))
                            .scaleEffect(scale(index, at: context.date))
                    }
                }
            }

            if let label {
                Text(label).font(Bud.Font.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A sine rather than a sawtooth so each dot fades in and out smoothly and
    /// the cycle has no visible jump.
    private func wave(_ index: Int, at date: Date) -> Double {
        let cycles = date.timeIntervalSinceReferenceDate / 1.2
        return 0.5 + 0.5 * sin(2 * .pi * (cycles - Double(index) / 3))
    }

    private func opacity(_ index: Int, at date: Date) -> Double {
        0.28 + 0.72 * wave(index, at: date)
    }

    private func scale(_ index: Int, at date: Date) -> CGFloat {
        0.8 + 0.2 * wave(index, at: date)
    }
}

/// A label with a travelling highlight. Used for "Thinking…" so the reasoning
/// header itself signals that tokens are still arriving.
public struct ShimmerLabel: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Bud.Palette.reasoning.opacity(0.45),
                            Bud.Palette.reasoning,
                            Bud.Palette.reasoning.opacity(0.45),
                        ],
                        // The span stays wider than the text at every phase, so
                        // the label is legible on the first frame and at any
                        // point in the sweep. A narrower band could slide clear
                        // of the glyphs and leave an empty gap.
                        startPoint: UnitPoint(x: sweep(at: context.date) - 0.9, y: 0.5),
                        endPoint: UnitPoint(x: sweep(at: context.date) + 0.9, y: 0.5)
                    )
                )
        }
    }

    private func sweep(at date: Date) -> CGFloat {
        CGFloat((date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)) / 1.6)
    }
}

/// Compact count of the tools the model can currently call.
public struct ToolCountBadge: View {
    private let count: Int
    private let isActive: Bool

    public init(count: Int, isActive: Bool = false) {
        self.count = count
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: Bud.Space.snug) {
            Image(systemName: "wrench.and.screwdriver")
                .font(Bud.Font.micro.weight(.semibold))
            // The noun matters: a bare numeral next to an icon leaves the reader
            // guessing whether it counts tools, tokens or messages.
            Text(count == 1 ? "1 tool" : "\(count) tools").font(Bud.Font.caption)
        }
        .foregroundStyle(isActive ? Bud.Palette.accent : Color.secondary)
        .padding(.horizontal, Bud.Space.sm)
        .padding(.vertical, Bud.Space.xs)
        .background {
            Capsule(style: .continuous)
                .fill((isActive ? Bud.Palette.accent : Color.white).opacity(isActive ? 0.18 : 0.08))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            (isActive ? Bud.Palette.accent : Color.white).opacity(isActive ? 0.45 : 0.16),
                            lineWidth: 0.6
                        )
                }
        }
        .help("\(count) tools available")
    }
}

/// Dismissible failure banner for the top-level error surface.
public struct ErrorBanner: View {
    private let message: String
    private let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Bud.Font.caption.weight(.semibold))
                .foregroundStyle(Bud.Palette.danger)
            Text(message)
                .font(Bud.Font.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            GlassIconButton(systemImage: "xmark", help: "Dismiss", action: onDismiss)
        }
        .padding(Bud.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Bud.Palette.danger.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(Bud.Palette.danger.opacity(0.34), lineWidth: 0.6)
                }
        }
    }
}

/// Shown in place of the composer when Bud has no credential to talk to the model.
public struct KeyMissingBanner: View {
    private let onOpenSettings: () -> Void

    public init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Bud.Space.sm) {
            Image(systemName: "key.fill")
                .font(Bud.Font.caption.weight(.semibold))
                .foregroundStyle(Bud.Palette.warning)
            VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                Text("DeepSeek API key required")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.primary)
                Text("Bud needs a key before it can reach the model.")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button("Add your DeepSeek API key in Settings") {
                onOpenSettings()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .tint(Bud.Palette.accent)
        }
        .padding(Bud.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Bud.Palette.warning.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                        .strokeBorder(Bud.Palette.warning.opacity(0.30), lineWidth: 0.6)
                }
        }
    }
}
