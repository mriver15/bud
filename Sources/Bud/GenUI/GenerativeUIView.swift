import AppKit
import SwiftUI
import WebKit

// MARK: - Generative UI

/// Renders a model-authored `UISpec` inside one glass card.
///
/// The spec arrives as raw `JSONValue` rather than a parsed `UISpec` so that a
/// parse failure can show the model's own output back to the user — a malformed
/// surface has to be diagnosable, not a blank box.
public struct GenerativeUIView: View {
    private let raw: JSONValue
    private let spec: UISpec?
    private let onAction: (GenUIAction) -> Void
    private let onPrompt: (String) -> Void

    public init(
        spec: JSONValue,
        onAction: @escaping (GenUIAction) -> Void,
        onPrompt: @escaping (String) -> Void
    ) {
        self.raw = spec
        self.spec = UISpec(json: spec)
        self.onAction = onAction
        self.onPrompt = onPrompt
    }

    public var body: some View {
        if let spec {
            GlassCard {
                VStack(alignment: .leading, spacing: Bud.Space.md) {
                    if let title = spec.title {
                        TitleHeader(title: title)
                    }
                    ForEach(spec.components.indices, id: \.self) { index in
                        UIComponentView(
                            component: spec.components[index],
                            onAction: onAction,
                            onPrompt: onPrompt
                        )
                    }
                }
            }
        } else {
            SpecDiagnosticCard(raw: raw)
        }
    }
}

private struct TitleHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.snug) {
            Text(title)
                .font(Bud.Font.title)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
        }
    }
}

/// Shown when the arguments were not a spec at all. The model's own JSON is
/// printed verbatim so the failure is visible in the panel and in a bug report.
private struct SpecDiagnosticCard: View {
    let raw: JSONValue

    var body: some View {
        GlassCard(tint: Bud.Palette.danger) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                HStack(spacing: Bud.Space.snug) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Bud.Font.caption.weight(.semibold))
                        .foregroundStyle(Bud.Palette.warning)
                    Text("Interface spec could not be parsed")
                        .font(Bud.Font.title)
                }
                Text("Expected an object shaped like {\"title\": \"…\", \"components\": [{\"type\": \"…\"}]}. The value the model produced was:")
                    .font(Bud.Font.callout)
                    .foregroundStyle(.secondary)
                CodeComponent(language: "json", value: raw.encodedString(pretty: true))
            }
        }
    }
}

// MARK: - Dispatch

/// One component in isolation. Every case is a real view; nothing falls through
/// to an empty branch, so a spec that parses renders something for every node.
struct UIComponentView: View {
    let component: UIComponent
    let onAction: (GenUIAction) -> Void
    let onPrompt: (String) -> Void

    var body: some View {
        switch component {
        case .text(let value, let style):
            TextComponent(value: value, style: style)
        case .metrics(let items):
            MetricsComponent(items: items)
        case .row(let children, let gap):
            WrapComponent(children: children, gap: gap, equalWidth: false, onAction: onAction, onPrompt: onPrompt)
        case .columns(let children, let gap):
            WrapComponent(children: children, gap: gap, equalWidth: true, onAction: onAction, onPrompt: onPrompt)
        case .grid(let columns, let children):
            GridComponent(columns: columns, children: children, onAction: onAction, onPrompt: onPrompt)
        case .card(let title, let subtitle, let tint, let children):
            CardComponent(
                title: title, subtitle: subtitle, tint: tint, children: children,
                onAction: onAction, onPrompt: onPrompt
            )
        case .list(let items):
            ListComponent(items: items)
        case .table(let columns, let rows, let align):
            TableComponent(columns: columns, rows: rows, align: align)
        case .chart(let kind, let series, let unit):
            ChartComponent(kind: kind, series: series, unit: unit)
        case .progress(let label, let value, let caption):
            ProgressComponent(label: label, value: value, caption: caption)
        case .keyValue(let items):
            KeyValueComponent(items: items)
        case .code(let language, let value):
            CodeComponent(language: language, value: value)
        case .callout(let kind, let title, let value):
            CalloutComponent(kind: kind, title: title, value: value)
        case .image(let url, let alt):
            ImageComponent(url: url, alt: alt)
        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
        case .button(let label, let symbol, let style, let action):
            ButtonComponent(
                label: label, symbol: symbol, style: style, action: action,
                onAction: onAction, onPrompt: onPrompt
            )
        case .html(let value, let height):
            HTMLComponent(html: value, height: height)
        case .unsupported(let type):
            UnsupportedComponent(type: type)
        }
    }
}

// MARK: - Text

private struct TextComponent: View {
    let value: String
    let style: UITextStyle

    var body: some View {
        switch style {
        case .title:
            Text(value).font(Bud.Font.title).textSelection(.enabled)
        case .heading:
            Text(value).font(Bud.Font.body.weight(.semibold)).textSelection(.enabled)
        case .body:
            Text(value).font(Bud.Font.body).textSelection(.enabled)
        case .caption:
            Text(value).font(Bud.Font.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case .mono:
            Text(value).font(Bud.Font.mono).textSelection(.enabled)
        case .quote:
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                Capsule()
                    .fill(Bud.Palette.accent.opacity(0.7))
                    .frame(width: 2)
                Text(value)
                    .font(Bud.Font.body)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Metrics

private struct MetricsComponent: View {
    let items: [UIMetric]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 118), spacing: Bud.Space.sm, alignment: .leading)],
            alignment: .leading,
            spacing: Bud.Space.sm
        ) {
            ForEach(items.indices, id: \.self) { index in
                MetricCell(metric: items[index])
            }
        }
    }
}

private struct MetricCell: View {
    let metric: UIMetric

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.hairline) {
            Text(metric.value)
                .font(Bud.Font.metric)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .textSelection(.enabled)
            HStack(spacing: Bud.Space.xs) {
                Text(metric.label)
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let delta = metric.delta, let trend = metric.trend {
                    TrendBadge(delta: delta, trend: trend)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrendBadge: View {
    let delta: String
    let trend: UITrend

    var body: some View {
        HStack(spacing: Bud.Space.hairline) {
            Image(systemName: trend.symbolName)
                .font(Bud.Font.micro.weight(.bold))
            Text(delta).font(Bud.Font.caption)
        }
        .foregroundStyle(trend.tint)
        .lineLimit(1)
    }
}

// MARK: - Layout

private struct WrapComponent: View {
    let children: [UIComponent]
    let gap: Double?
    let equalWidth: Bool
    let onAction: (GenUIAction) -> Void
    let onPrompt: (String) -> Void

    /// The width this row was actually given, measured rather than assumed.
    /// `Layout.sizeThatFits` and `Layout.placeSubviews` are handed different
    /// proposals — the first may see an unspecified width while the second sees
    /// the real bounds — so if the layout decides wrapping from each of them
    /// independently it can measure one line and place three, drawing the pills
    /// on top of one another.
    @BudState private var measuredWidth: CGFloat = 0

    var body: some View {
        WrapLayout(
            spacing: CGFloat(gap ?? Double(Bud.Space.sm)),
            equalWidth: equalWidth,
            available: measuredWidth
        ) {
            ForEach(children.indices, id: \.self) { index in
                UIComponentView(
                    component: children[index],
                    onAction: onAction,
                    onPrompt: onPrompt
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measuredWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in measuredWidth = width }
            }
        }
    }
}

private struct GridComponent: View {
    let columns: Int
    let children: [UIComponent]
    let onAction: (GenUIAction) -> Void
    let onPrompt: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Bud.Space.sm, alignment: .leading),
                count: max(1, columns)
            ),
            alignment: .leading,
            spacing: Bud.Space.sm
        ) {
            ForEach(children.indices, id: \.self) { index in
                UIComponentView(
                    component: children[index],
                    onAction: onAction,
                    onPrompt: onPrompt
                )
            }
        }
    }
}

/// Left-to-right layout that wraps instead of overflowing. `HStack` cannot wrap
/// and the panel is a fixed 460pt, so any generated row long enough to be
/// useful would otherwise be clipped.
private struct WrapLayout: Layout {
    var spacing: CGFloat
    /// `columns` shares the line equally; `row` keeps each child at its
    /// intrinsic width.
    var equalWidth: Bool
    /// Width measured by the enclosing view, or 0 before the first layout pass.
    var available: CGFloat

    private static let minimumColumnWidth: CGFloat = 120
    /// Stand-in for "unbounded" so the arithmetic stays finite.
    private static let unbounded: CGFloat = 10_000

    private struct Placement {
        var size: CGSize
        var origin: CGPoint
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = available > 0
            ? available
            : min(proposal.width ?? Self.unbounded, Self.unbounded)
        let placements = placements(subviews: subviews, available: width)
        let measured = placements.map { $0.origin.x + $0.size.width }.max() ?? 0
        let height = placements.map { $0.origin.y + $0.size.height }.max() ?? 0
        return CGSize(width: min(measured, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // Same width as `sizeThatFits` used, so the reported height always
        // matches the layout that is actually drawn.
        let width = available > 0 ? available : bounds.width
        for (index, placement) in placements(subviews: subviews, available: width).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func placements(subviews: Subviews, available: CGFloat) -> [Placement] {
        guard !subviews.isEmpty, available > 0 else { return [] }
        let perLine = equalWidth ? max(1, itemsPerLine(count: subviews.count, available: available)) : subviews.count
        let equalItemWidth = equalWidth
            ? max(0, (available - spacing * CGFloat(perLine - 1)) / CGFloat(perLine))
            : 0

        var result: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var inLine = 0

        for subview in subviews {
            let proposal: ProposedViewSize = equalWidth
                ? ProposedViewSize(width: equalItemWidth, height: nil)
                : .unspecified
            var size = subview.sizeThatFits(proposal)
            if size.width > available {
                // Re-measure at the clamped width. A Text narrowed to fit grows
                // taller, so keeping the pre-clamp height would under-report the
                // line and overlap whatever comes next.
                size = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
                size.width = min(size.width, available)
            }

            if inLine >= perLine || (inLine > 0 && x + size.width > available) {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
                inLine = 0
            }
            result.append(Placement(size: size, origin: CGPoint(x: x, y: y)))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            inLine += 1
        }
        return result
    }

    private func itemsPerLine(count: Int, available: CGFloat) -> Int {
        let fitting = Int((available + spacing) / (Self.minimumColumnWidth + spacing))
        return min(count, max(1, fitting))
    }
}

// MARK: - Card

private struct CardComponent: View {
    let title: String?
    let subtitle: String?
    let tint: String?
    let children: [UIComponent]
    let onAction: (GenUIAction) -> Void
    let onPrompt: (String) -> Void

    var body: some View {
        GlassCard(padding: Bud.Space.md, tint: tintColor(tint)) {
            VStack(alignment: .leading, spacing: Bud.Space.sm) {
                if title != nil || subtitle != nil {
                    VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                        if let title {
                            Text(title).font(Bud.Font.title).textSelection(.enabled)
                        }
                        if let subtitle {
                            Text(subtitle).font(Bud.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(children.indices, id: \.self) { index in
                    UIComponentView(
                        component: children[index],
                        onAction: onAction,
                        onPrompt: onPrompt
                    )
                }
            }
        }
    }
}

// MARK: - List

private struct ListComponent: View {
    let items: [UIListItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                ListRow(item: items[index])
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.leading, items[index].symbol == nil ? 0 : 22)
                }
            }
        }
    }
}

private struct ListRow: View {
    let item: UIListItem

    var body: some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            if item.symbol != nil {
                SymbolIcon(name: item.symbol)
                    .font(Bud.Font.caption)
                    .foregroundStyle(Bud.Palette.accent)
                    .frame(width: 14)
                    .padding(.top, Bud.Space.hairline)
            }
            VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                Text(item.title).font(Bud.Font.body).textSelection(.enabled)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(Bud.Font.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: Bud.Space.sm)
            if let badge = item.badge {
                GlassChip(badge, tint: Bud.Palette.accent, isActive: true)
            }
        }
        .padding(.vertical, Bud.Space.snug)
    }
}

// MARK: - Table

private struct TableComponent: View {
    let columns: [String]
    let rows: [[String]]
    let align: [UITableAlignment]

    private var columnCount: Int {
        max(columns.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Bud.Space.sm) {
                ForEach(0..<columnCount, id: \.self) { index in
                    cell(index < columns.count ? columns[index] : "", at: index, isHeader: true)
                }
            }
            .padding(.vertical, Bud.Space.snug)
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(alignment: .top, spacing: Bud.Space.sm) {
                    ForEach(0..<columnCount, id: \.self) { index in
                        cell(cellText(rowIndex, index), at: index, isHeader: false)
                    }
                }
                .padding(.vertical, Bud.Space.snug)
                if rowIndex < rows.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func cellText(_ row: Int, _ index: Int) -> String {
        guard rows.indices.contains(row) else { return "" }
        let cells = rows[row]
        return cells.indices.contains(index) ? cells[index] : ""
    }

    private func cell(_ text: String, at index: Int, isHeader: Bool) -> some View {
        Text(text)
            .font(isHeader ? Bud.Font.caption : Bud.Font.callout)
            .foregroundStyle(isHeader ? Color.secondary : Color.primary)
            .multilineTextAlignment(textAlignment(at: index))
            .frame(maxWidth: .infinity, alignment: frameAlignment(at: index))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func frameAlignment(at index: Int) -> Alignment {
        switch alignment(at: index) {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func textAlignment(at index: Int) -> TextAlignment {
        switch alignment(at: index) {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func alignment(at index: Int) -> UITableAlignment {
        align.indices.contains(index) ? align[index] : .left
    }
}

// MARK: - Chart

/// Hand-drawn with `Canvas`: the panel must stay dependency-free, and a chart
/// this small does not justify a plotting library.
private struct ChartComponent: View {
    let kind: UIChartKind
    let series: [UIChartPoint]
    let unit: String?

    private let plotHeight: CGFloat = 128
    private let labelBand: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            if let unit, !unit.isEmpty {
                Text("Values in \(unit)")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: plotHeight + labelBand)
            .accessibilityElement()
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !series.isEmpty, size.width > 0 else { return }
        let peak = series.map { max($0.value, 0) }.max() ?? 0
        let scale = peak > 0 ? peak : 1
        let slot = size.width / CGFloat(series.count)
        let accent = Bud.Palette.accent

        for step in 0...4 {
            let y = plotHeight * CGFloat(step) / 4
            var gridline = Path()
            gridline.move(to: CGPoint(x: 0, y: y))
            gridline.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                gridline,
                with: .color(.white.opacity(step == 4 ? 0.16 : 0.06)),
                lineWidth: 0.6
            )
        }

        let anchors = series.indices.map { index in
            CGPoint(
                x: slot * (CGFloat(index) + 0.5),
                y: plotHeight - plotHeight * CGFloat(max(series[index].value, 0) / scale)
            )
        }

        switch kind {
        case .bar:
            let barWidth = min(slot * 0.62, 44)
            for (index, anchor) in anchors.enumerated() {
                let rect = CGRect(
                    x: anchor.x - barWidth / 2,
                    y: anchor.y,
                    width: barWidth,
                    height: max(plotHeight - anchor.y, series[index].value > 0 ? 2 : 0)
                )
                let bar = Path(roundedRect: rect, cornerRadius: min(4, barWidth / 2))
                context.fill(
                    bar,
                    with: .linearGradient(
                        Gradient(colors: [accent.opacity(0.95), accent.opacity(0.45)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: plotHeight)
                    )
                )
            }

        case .line, .area:
            if let first = anchors.first {
                var path = Path()
                path.move(to: first)
                for anchor in anchors.dropFirst() { path.addLine(to: anchor) }

                if kind == .area, let last = anchors.last {
                    var fill = path
                    fill.addLine(to: CGPoint(x: last.x, y: plotHeight))
                    fill.addLine(to: CGPoint(x: first.x, y: plotHeight))
                    fill.closeSubpath()
                    context.fill(
                        fill,
                        with: .linearGradient(
                            Gradient(colors: [accent.opacity(0.40), accent.opacity(0.02)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: plotHeight)
                        )
                    )
                }

                context.stroke(
                    path,
                    with: .color(accent),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                if kind == .line {
                    for anchor in anchors {
                        let dot = Path(ellipseIn: CGRect(x: anchor.x - 2.5, y: anchor.y - 2.5, width: 5, height: 5))
                        context.fill(dot, with: .color(accent))
                    }
                }
            }
        }

        // Value labels crowd out the bars past a handful of points, so they are
        // dropped rather than overlapped.
        let showValues = series.count <= 8
        for (index, point) in series.enumerated() {
            let label = context.resolve(
                Text(point.label)
                    .font(Bud.Font.micro.weight(.regular))
                    .foregroundStyle(Color.white.opacity(0.55))
            )
            context.draw(label, at: CGPoint(x: anchors[index].x, y: plotHeight + 3), anchor: .top)

            guard showValues else { continue }
            let value = context.resolve(
                Text(formatted(point.value) + (unit ?? ""))
                    .font(Bud.Font.micro.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            )
            context.draw(value, at: CGPoint(x: anchors[index].x, y: max(anchors[index].y - 4, 0)), anchor: .bottom)
        }
    }

    private func formatted(_ value: Double) -> String {
        if abs(value) >= 10_000 { return String(format: "%.0fk", value / 1000) }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    private var accessibilitySummary: String {
        let points = series.map { "\($0.label) \(formatted($0.value))\(unit ?? "")" }
        return "\(kind.rawValue) chart: " + points.joined(separator: ", ")
    }
}

// MARK: - Progress

private struct ProgressComponent: View {
    let label: String?
    let value: Double
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.snug) {
            HStack(spacing: Bud.Space.sm) {
                if let label {
                    Text(label).font(Bud.Font.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(Int((value * 100).rounded()))%")
                    .font(Bud.Font.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Bud.Palette.accent, Bud.Palette.reasoning],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geometry.size.width * CGFloat(value)))
                }
            }
            .frame(height: 7)
            if let caption {
                Text(caption).font(Bud.Font.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(label ?? "Progress"): \(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Key/value

private struct KeyValueComponent: View {
    let items: [UIKeyValuePair]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Bud.Space.md, verticalSpacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                GridRow {
                    Text(items[index].key)
                        .font(Bud.Font.callout)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(items[index].value)
                        .font(Bud.Font.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridColumnAlignment(.leading)
                }
            }
        }
    }
}

// MARK: - Code

private struct CodeComponent: View {
    let language: String?
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            if let language {
                GlassChip(language)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value)
                    .font(Bud.Font.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Bud.Space.sm)
            }
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
            }
        }
    }
}

// MARK: - Callout

private struct CalloutComponent: View {
    let kind: UICalloutKind
    let title: String?
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: Bud.Space.sm) {
            Image(systemName: kind.symbolName)
                .font(Bud.Font.caption.weight(.semibold))
                .foregroundStyle(kind.tint)
            VStack(alignment: .leading, spacing: Bud.Space.hairline) {
                if let title {
                    Text(title).font(Bud.Font.body.weight(.semibold)).textSelection(.enabled)
                }
                Text(value).font(Bud.Font.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(Bud.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(kind.tint.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.35), lineWidth: 0.6)
        }
    }
}

// MARK: - Image

private struct ImageComponent: View {
    let url: String
    let alt: String?

    private var link: URL? {
        guard let link = URL(string: url), let scheme = link.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return link
        case "file":
            // Only from Bud's own directory. The browser tools write their page
            // screenshots there, and a `render_ui` spec is model-authored — a spec
            // allowed to name any path on disk would turn a UI surface into a
            // way to probe the filesystem for what exists.
            let allowed = BudConfigLoader.budDirectory.standardizedFileURL.path
            let target = link.standardizedFileURL.path
            return target.hasPrefix(allowed + "/") ? link : nil
        default:
            return nil
        }
    }

    var body: some View {
        Group {
            if let link {
                AsyncImage(url: link) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    case .failure:
                        unavailable
                    @unknown default:
                        unavailable
                    }
                }
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
    }

    private var altText: String {
        guard let alt, !alt.isEmpty else { return "Image unavailable" }
        return alt
    }

    private var unavailable: some View {
        VStack(spacing: Bud.Space.xs) {
            Image(systemName: "photo")
                .font(Bud.Font.hero.weight(.light))
                .foregroundStyle(.tertiary)
            Text(altText)
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(Bud.Space.sm)
        .background(Color.white.opacity(0.04))
    }
}

// MARK: - Button

private struct ButtonComponent: View {
    let label: String
    let symbol: String?
    let style: UIButtonStyle
    let action: UIAction
    let onAction: (GenUIAction) -> Void
    let onPrompt: (String) -> Void

    var body: some View {
        switch style {
        case .primary:
            Button(action: fire) { labelView }
                .buttonStyle(.glassProminent)
        case .secondary:
            Button(action: fire) { labelView }
                .buttonStyle(.glass)
        case .destructive:
            Button(action: fire) { labelView }
                .buttonStyle(.glass)
                .tint(Bud.Palette.danger)
                .foregroundStyle(Bud.Palette.danger)
        }
    }

    private var labelView: some View {
        HStack(spacing: Bud.Space.snug) {
            SymbolIcon(name: symbol)
            Text(label)
        }
    }

    /// The host gets the action either way; `prompt` additionally seeds a
    /// follow-up user message, which is how a generated button continues the
    /// conversation rather than only firing a callback.
    private func fire() {
        onAction(GenUIAction(id: action.id, payload: action.raw))
        if let prompt = action.prompt, !prompt.isEmpty {
            onPrompt(prompt)
        }
    }
}

// MARK: - HTML

private struct HTMLComponent: View {
    let html: String
    let height: Double

    var body: some View {
        HTMLWebView(html: html)
            .frame(height: CGFloat(height))
            .clipShape(RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
            }
    }
}

/// The `html` escape hatch: inline markup the DSL cannot express.
///
/// Treated as untrusted input, because it is model output that has usually been
/// shaped by whatever the model just read. JavaScript is disabled, only the
/// initial `loadHTMLString` may commit a navigation, and link clicks are
/// cancelled — inline CSS and SVG, which is all the schema promises, still
/// render. That closes the prompt-injection path where a page drives the host.
private struct HTMLWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // `NSView.isOpaque` is read-only on macOS, so transparency comes from the
        // page colour below plus the private background key.
        webView.underPageBackgroundColor = .clear
        // WebKit still paints an opaque page underneath the content; the
        // `drawsBackground` key is the only switch that clears it, and it is
        // private, so probe for it instead of assuming it exists.
        if webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: String?

        func load(_ html: String, in webView: WKWebView) {
            guard loaded != html else { return }
            loaded = html
            webView.loadHTMLString(HTMLWebView.shell(html), baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // `loadHTMLString` against a nil base URL arrives as `about:blank`.
            // Everything else — clicked links, meta refreshes, form posts — is a
            // request the model is trying to make on the user's behalf.
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            return scheme == nil || scheme == "about" ? .allow : .cancel
        }
    }

    /// The model supplies a body fragment; this shell supplies the document it
    /// lives in. `background: transparent` plus the `color-scheme` hint are what
    /// let the page sit invisibly on top of the glass card in either appearance.
    ///
    /// `overscroll-behavior: none` is how bounce is suppressed: a `WKWebView` on
    /// this OS contains no `NSScrollView` to configure — its only subview is a
    /// `WKFlippedView` — so scrolling belongs entirely to the web process and CSS
    /// is the only lever.
    private static func shell(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="dark light">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark light; }
          html { overscroll-behavior: none; }
          html, body { margin: 0; padding: 0; background: transparent; }
          body {
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 13px;
            line-height: 1.45;
            color: CanvasText;
            padding: 10px 12px;
            overflow-wrap: break-word;
            -webkit-text-size-adjust: 100%;
          }
          img, svg, table, pre { max-width: 100%; }
          a { color: LinkText; }
          pre, code { font-family: ui-monospace, monospace; }
        </style>
        </head><body>\(body)</body></html>
        """
    }
}

// MARK: - Unsupported

private struct UnsupportedComponent: View {
    let type: String

    var body: some View {
        HStack(spacing: Bud.Space.xs) {
            Image(systemName: "questionmark.square.dashed")
                .font(Bud.Font.micro)
            Text("unsupported: \(type)")
                .font(Bud.Font.caption)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Bud.Space.sm)
        .padding(.vertical, Bud.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.14),
                    style: StrokeStyle(lineWidth: 0.6, dash: [3, 3])
                )
        }
    }
}

// MARK: - Shared bits

/// A symbol name invented by the model must not draw a "?" glyph in the middle
/// of the surface, so names are resolved through AppKit first.
private struct SymbolIcon: View {
    let name: String?

    var body: some View {
        if let name, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            Image(nsImage: image)
        }
    }
}

private extension UITrend {
    var symbolName: String {
        switch self {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    var tint: Color {
        switch self {
        case .up: return Bud.Palette.success
        case .down: return Bud.Palette.danger
        case .flat: return .secondary
        }
    }
}

private extension UICalloutKind {
    var symbolName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return Bud.Palette.accent
        case .success: return Bud.Palette.success
        case .warning: return Bud.Palette.warning
        case .error: return Bud.Palette.danger
        }
    }
}

/// Named colors cover what models reach for; hex covers everything else.
private func tintColor(_ raw: String?) -> Color? {
    guard let raw else { return nil }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch name {
    case "": return nil
    case "accent": return Bud.Palette.accent
    case "success", "green": return Bud.Palette.success
    case "warning", "orange", "yellow": return Bud.Palette.warning
    case "danger", "error", "red": return Bud.Palette.danger
    case "blue": return .blue
    case "purple", "indigo": return .purple
    case "pink": return .pink
    case "teal", "cyan": return .teal
    case "gray", "grey", "neutral": return .gray
    default: return Color(budHex: name)
    }
}

private extension Color {
    /// Failable so an unparseable tint degrades to no tint rather than to black.
    init?(budHex raw: String) {
        var digits = raw
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(digits, radix: 16)
        else { return nil }
        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
