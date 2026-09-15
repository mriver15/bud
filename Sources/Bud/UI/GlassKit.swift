import SwiftUI

// MARK: - Tokens

/// Spacing, radii and type tokens shared by every surface so the panel reads as
/// one object rather than a stack of independently-styled views.
public enum Bud {
    public enum Radius {
        /// The floating panel itself.
        public static let panel: CGFloat = 26
        /// Contained cards inside a panel.
        public static let card: CGFloat = 18
        /// Controls: fields, buttons, list rows.
        public static let control: CGFloat = 12
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    public enum Font {
        public static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        public static let body = SwiftUI.Font.system(size: 13.5)
        public static let callout = SwiftUI.Font.system(size: 12.5)
        public static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        public static let metric = SwiftUI.Font.system(size: 26, weight: .semibold, design: .rounded)
    }

    public enum Palette {
        public static let accent = Color(red: 0.44, green: 0.42, blue: 0.98)
        public static let success = Color(red: 0.24, green: 0.72, blue: 0.45)
        public static let warning = Color(red: 0.95, green: 0.68, blue: 0.20)
        public static let danger = Color(red: 0.94, green: 0.35, blue: 0.36)
        public static let reasoning = Color(red: 0.60, green: 0.58, blue: 0.98)
    }

    public static let panelWidth: CGFloat = 460
    public static let panelHeight: CGFloat = 660
}

// MARK: - Panel surface

/// The root Liquid Glass surface. Wraps content in the floating panel treatment:
/// a regular glass layer, a bright top specular edge, and a soft outer shadow so
/// the panel separates from whatever is behind it.
public struct GlassPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = Bud.Radius.panel, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .background {
                // Two stacked layers: the glass itself, then a very subtle
                // vertical wash that keeps text legible over bright desktops
                // where the bare backdrop would otherwise wash out.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.10),
                                        Color.white.opacity(0.02),
                                        Color.black.opacity(0.06),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.45), Color.white.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.30), radius: 28, y: 12)
            }
    }
}

// MARK: - Card

/// A contained region *inside* the panel. Cards deliberately do not nest glass
/// within glass — the panel already provides the backdrop, so a card is a
/// tinted, hairline-bordered fill. Nesting real glass here would double the
/// blur cost for no visual gain.
public struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let tint: Color?
    private let content: Content

    public init(
        cornerRadius: CGFloat = Bud.Radius.card,
        padding: CGFloat = Bud.Space.md,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((tint ?? .clear).opacity(tint == nil ? 0 : 0.14))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                    }
            }
    }
}

// MARK: - Chip

public struct GlassChip: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color?
    private let isActive: Bool

    public init(_ text: String, systemImage: String? = nil, tint: Color? = nil, isActive: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(Bud.Font.caption)
        }
        .foregroundStyle(tint ?? (isActive ? .primary : .secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill((tint ?? Bud.Palette.accent).opacity(isActive ? 0.20 : 0.10))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder((tint ?? Bud.Palette.accent).opacity(isActive ? 0.45 : 0.22), lineWidth: 0.6)
                }
        }
    }
}

// MARK: - Icon button

/// Circular glass control used in toolbars. `GlassEffectContainer` at the call
/// site lets adjacent buttons blend into one another.
public struct GlassIconButton: View {
    private let systemImage: String
    private let help: String
    private let tint: Color?
    private let action: () -> Void
    @BudState private var isHovering = false

    public init(
        systemImage: String,
        help: String = "",
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
        .glassEffect(.regular.tint(tint?.opacity(0.3)).interactive(), in: .circle)
        .scaleEffect(isHovering ? 1.05 : 1)
        .animation(.snappy(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - State badge

public struct StateDot: View {
    private let color: Color
    private let pulsing: Bool

    public init(color: Color, pulsing: Bool = false) {
        self.color = color
        self.pulsing = pulsing
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 1)
                        .scaleEffect(2.1)
                        .opacity(0.35)
                }
            }
            .shadow(color: color.opacity(0.7), radius: 3)
    }
}

// MARK: - Empty state

public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let fills: Bool

    /// - Parameter fills: when true the view expands to absorb the whole
    ///   available area and centres itself inside it, which is what a pane-level
    ///   empty state wants. Pass false to embed it in a larger column — such as
    ///   a hero plus starter prompts — where an expanding block would push
    ///   everything below it to the bottom edge and leave an orphan gap.
    public init(systemImage: String, title: String, message: String, fills: Bool = true) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.fills = fills
    }

    public var body: some View {
        VStack(spacing: Bud.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(Bud.Font.title).foregroundStyle(.secondary)
            Text(message)
                // Secondary rather than tertiary: the panel is glass over an
                // arbitrary desktop, so the effective contrast varies and this
                // copy has to stay readable over a bright wallpaper.
                .font(Bud.Font.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: fills ? .infinity : nil)
        .padding(Bud.Space.xl)
    }
}

// MARK: - Shared formatters

public enum BudFormat {
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }

    public static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        return String(format: "%.1fk", Double(count) / 1000)
    }
}
