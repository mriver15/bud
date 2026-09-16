import SwiftUI

/// Bud's resting state: a small glass bubble parked in a screen corner.
///
/// The full panel is 460×660 and wants to be looked at; this is the shape Bud
/// wears when it is only meant to be *available*. It stays visible in the corner
/// without covering anything, shows that work is happening, and expands on a
/// click. Tapping and dragging share one gesture: a press that never travels is
/// a tap, a press that moves drags the bubble to another corner.
struct CollapsedPill: View {
    let model: AppModel
    let onExpand: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    @BudState private var isHovering = false
    @BudState private var isDragging = false

    private static let diameter: CGFloat = 56

    init(
        model: AppModel,
        onExpand: @escaping () -> Void,
        onDrag: @escaping (CGSize) -> Void,
        onDragEnd: @escaping () -> Void
    ) {
        self.model = model
        self.onExpand = onExpand
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(
                    .regular.tint(Bud.Palette.accent.opacity(0.45)).interactive(),
                    in: .circle
                )
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.32), radius: 10, y: 3)

            Image(systemName: "sparkle")
                .font(Bud.Font.hero)
                .foregroundStyle(.white)

            if model.isStreaming {
                StreamingRing()
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(isHovering && !isDragging ? 1.06 : 1)
        .opacity(isDragging ? 1 : (isHovering ? 1 : 0.72))
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.snappy(duration: 0.16), value: isDragging)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .gesture(
            // One gesture for both actions: a click that never travels opens the
            // panel, a click that travels moves the bubble. Two competing
            // gestures would fight over the same press.
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let travelled = abs(value.translation.width) + abs(value.translation.height)
                    guard travelled > 3 else { return }
                    isDragging = true
                    onDrag(value.translation)
                }
                .onEnded { value in
                    let travelled = abs(value.translation.width) + abs(value.translation.height)
                    if isDragging || travelled > 3 {
                        isDragging = false
                        onDragEnd()
                    } else {
                        onExpand()
                    }
                }
        )
        .help(model.isStreaming ? "Bud is working — click to open" : "Open Bud")
    }
}

/// A ring that turns while the model is streaming, so a collapsed Bud still says
/// whether it is busy. Driven by `TimelineView` rather than an animation because
/// a periodic schedule keeps ticking without a display-linked animation, which an
/// offscreen or occluded panel does not get.
private struct StreamingRing: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate * 1.1
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0), .white.opacity(0.95)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees((turns - turns.rounded(.down)) * 360))
                .padding(Bud.Space.xs)
        }
        .allowsHitTesting(false)
    }
}
