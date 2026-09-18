import Foundation

// MARK: - Spec

/// A model-authored interface, decoded from the `render_ui` tool arguments.
///
/// Decoding is total by design. This surface *is* the answer the user reads, so
/// a model that misspells a component type or omits a required field has to
/// produce a placeholder that names the problem — never a crash, and never a
/// silently blank panel that reads as "Bud did nothing".
public struct UISpec: Sendable, Hashable {
    public var title: String?
    public var components: [UIComponent]

    /// The component types the parser accepts, in the order they are documented
    /// to the model. The tool schema is built from this list, so the parser and
    /// the documentation cannot drift apart.
    public static let knownComponentTypes: [String] = [
        "text", "metrics", "row", "columns", "grid", "card", "list", "table",
        "chart", "progress", "keyvalue", "code", "callout", "image", "divider",
        "button", "html",
    ]

    /// Height used by `html` when the spec does not ask for one.
    public static let defaultHTMLHeight: Double = 220

    /// Fails only when there is no `components` array to render at all; every
    /// problem *inside* that array becomes a placeholder component instead.
    public init?(json: JSONValue) {
        guard let object = json.objectValue,
              let raw = object["components"]?.arrayValue
        else { return nil }
        self.title = object["title"]?.stringValue.flatMap(nonEmpty)
        self.components = raw.map(UIComponent.init(json:))
    }

    /// Names of component types that degraded to placeholders, deduplicated in
    /// tree order. Reported back to the model so it can correct itself.
    public var unsupportedTypes: [String] {
        var found: [String] = []
        for component in components { collectUnsupported(component, into: &found) }
        return found
    }
}

private func collectUnsupported(_ component: UIComponent, into found: inout [String]) {
    if case .unsupported(let type) = component, !found.contains(type) {
        found.append(type)
    }
    for child in component.children { collectUnsupported(child, into: &found) }
}

// MARK: - Components

/// One node of the generated interface.
///
/// A value tree rather than a class hierarchy: specs are re-parsed and
/// re-rendered on every streamed update, so nodes must be cheap to copy and
/// trivially `Sendable`.
public enum UIComponent: Sendable, Hashable {
    case text(value: String, style: UITextStyle)
    case metrics(items: [UIMetric])
    case row(children: [UIComponent], gap: Double?)
    case columns(children: [UIComponent], gap: Double?)
    case grid(columns: Int, children: [UIComponent])
    case card(title: String?, subtitle: String?, tint: String?, children: [UIComponent])
    case list(items: [UIListItem])
    case table(columns: [String], rows: [[String]], align: [UITableAlignment])
    case chart(kind: UIChartKind, series: [UIChartPoint], unit: String?)
    case progress(label: String?, value: Double, caption: String?)
    case keyValue(items: [UIKeyValuePair])
    case code(language: String?, value: String)
    case callout(kind: UICalloutKind, title: String?, value: String)
    case image(url: String, alt: String?, box: UIImageBox, action: UIAction?)
    case divider
    case button(label: String, symbol: String?, style: UIButtonStyle, action: UIAction)
    case html(value: String, height: Double)
    /// An unknown or malformed node. Rendered as a muted placeholder so the
    /// failure is visible instead of swallowing the whole surface.
    case unsupported(type: String)

    /// Direct children, for the recursive walks in `UISpec`.
    var children: [UIComponent] {
        switch self {
        case .row(let children, _), .columns(let children, _),
             .grid(_, let children), .card(_, _, _, let children):
            return children
        default:
            return []
        }
    }
}

// MARK: - Component payloads

public enum UITextStyle: String, Sendable, Hashable {
    case title, heading, body, caption, mono, quote

    init(raw: String?) {
        self = UITextStyle(rawValue: token(raw)) ?? .body
    }
}

public struct UIMetric: Sendable, Hashable {
    public var label: String
    public var value: String
    public var delta: String?
    public var trend: UITrend?

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let value = object["value"]?.stringValue.flatMap(nonEmpty)
        else { return nil }
        self.label = object["label"]?.stringValue.flatMap(nonEmpty) ?? ""
        self.value = value
        self.delta = object["delta"]?.stringValue.flatMap(nonEmpty)
        self.trend = object["trend"]?.stringValue.flatMap { UITrend(raw: $0) }
    }
}

public enum UITrend: String, Sendable, Hashable {
    case up, down, flat

    init?(raw: String) {
        self.init(rawValue: token(raw))
    }
}

public struct UIListItem: Sendable, Hashable {
    public var title: String
    public var subtitle: String?
    public var badge: String?
    public var symbol: String?

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let title = object["title"]?.stringValue.flatMap(nonEmpty)
        else { return nil }
        self.title = title
        self.subtitle = object["subtitle"]?.stringValue.flatMap(nonEmpty)
        self.badge = object["badge"]?.stringValue.flatMap(nonEmpty)
        self.symbol = object["symbol"]?.stringValue.flatMap(nonEmpty)
    }
}

public enum UITableAlignment: String, Sendable, Hashable {
    case left, right, center

    init(raw: String?) {
        self = UITableAlignment(rawValue: token(raw)) ?? .left
    }
}

public enum UIChartKind: String, Sendable, Hashable {
    case bar, line, area

    init(raw: String?) {
        self = UIChartKind(rawValue: token(raw)) ?? .bar
    }
}

public struct UIChartPoint: Sendable, Hashable {
    public var label: String
    public var value: Double

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let value = object["value"]?.doubleValue
        else { return nil }
        self.label = object["label"]?.stringValue.flatMap(nonEmpty) ?? ""
        self.value = value
    }
}

public struct UIKeyValuePair: Sendable, Hashable {
    public var key: String
    public var value: String

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let key = object["key"]?.stringValue.flatMap(nonEmpty),
              let value = object["value"]?.stringValue.flatMap(nonEmpty)
        else { return nil }
        self.key = key
        self.value = value
    }
}

public enum UICalloutKind: String, Sendable, Hashable {
    case info, success, warning, error

    init(raw: String?) {
        self = UICalloutKind(rawValue: token(raw)) ?? .info
    }
}

public enum UIButtonStyle: String, Sendable, Hashable {
    case primary, secondary, destructive

    init(raw: String?) {
        self = UIButtonStyle(rawValue: token(raw)) ?? .secondary
    }
}

/// A button's action. `raw` is the untouched action object from the model; it is
/// what the host receives as the payload, so a future field reaches the handler
/// without a parser change.
/// How an image is fitted into the space it is given.
public enum UIImageFit: String, Sendable, Hashable {
    /// The whole image, inside the box. What an image wants by default.
    case fit
    /// Fills the box and crops the overflow, which is what makes a row of
    /// thumbnails line up instead of each being a different size.
    case fill

    public init(raw: String?) {
        self = UIImageFit(rawValue: (raw ?? "").lowercased()) ?? .fit
    }
}

/// The space an image is given.
///
/// A URL on its own is not enough to lay anything out: an image with no size
/// stretches to whatever it is placed in, so a 96-pixel sprite in a transcript
/// arrives at the width of the panel. Width and height are in points and either
/// may be left out, in which case the image keeps its aspect ratio inside what is
/// left.
public struct UIImageBox: Sendable, Hashable {
    public var width: Double?
    public var height: Double?
    public var fit: UIImageFit
    public var cornerRadius: Double?

    public init(
        width: Double? = nil,
        height: Double? = nil,
        fit: UIImageFit = .fit,
        cornerRadius: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.fit = fit
        self.cornerRadius = cornerRadius
    }

    public init(json: [String: JSONValue]) {
        // Clamped rather than trusted: a generated spec is free to say 40000, and
        // a view that tries to lay that out is a hung window rather than a wrong
        // picture.
        self.init(
            width: json["width"]?.doubleValue.map { min(max($0, 8), 2000) },
            height: json["height"]?.doubleValue.map { min(max($0, 8), 2000) },
            fit: UIImageFit(raw: json["fit"]?.stringValue),
            cornerRadius: json["radius"]?.doubleValue.map { min(max($0, 0), 80) }
        )
    }
}

public struct UIAction: Sendable, Hashable {
    public var id: String
    public var prompt: String?
    public var raw: JSONValue
}

// MARK: - Parsing

extension UIComponent {
    init(json: JSONValue) {
        guard let object = json.objectValue else {
            self = .unsupported(type: "<\(json.kindName)>")
            return
        }
        switch token(object["type"]?.stringValue) {
        case "text":
            guard let value = object["value"]?.stringValue.flatMap(nonEmpty) else {
                self = .unsupported(type: "text (missing value)")
                return
            }
            self = .text(value: value, style: UITextStyle(raw: object["style"]?.stringValue))

        case "metrics":
            let items = (object["items"]?.arrayValue ?? []).compactMap(UIMetric.init(json:))
            guard !items.isEmpty else {
                self = .unsupported(type: "metrics (no items with a value)")
                return
            }
            self = .metrics(items: items)

        case "row":
            self = .row(children: Self.children(of: object), gap: object["gap"]?.doubleValue)

        case "columns":
            self = .columns(children: Self.children(of: object), gap: object["gap"]?.doubleValue)

        case "grid":
            let columns = object["columns"]?.doubleValue.map { Int($0) } ?? 2
            self = .grid(columns: min(max(columns, 1), 8), children: Self.children(of: object))

        case "card":
            self = .card(
                title: object["title"]?.stringValue.flatMap(nonEmpty),
                subtitle: object["subtitle"]?.stringValue.flatMap(nonEmpty),
                tint: object["tint"]?.stringValue.flatMap(nonEmpty),
                children: Self.children(of: object)
            )

        case "list":
            let items = (object["items"]?.arrayValue ?? []).compactMap(UIListItem.init(json:))
            guard !items.isEmpty else {
                self = .unsupported(type: "list (no items with a title)")
                return
            }
            self = .list(items: items)

        case "table":
            let columns = (object["columns"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(nonEmpty) }
            guard !columns.isEmpty else {
                self = .unsupported(type: "table (no columns)")
                return
            }
            let rows = (object["rows"]?.arrayValue ?? []).map { row in
                (row.arrayValue ?? []).map { $0.stringValue ?? "" }
            }
            let align = (object["align"]?.arrayValue ?? []).map { UITableAlignment(raw: $0.stringValue) }
            self = .table(columns: columns, rows: rows, align: align)

        case "chart":
            let series = (object["series"]?.arrayValue ?? []).compactMap(UIChartPoint.init(json:))
            guard !series.isEmpty else {
                self = .unsupported(type: "chart (no series points with a value)")
                return
            }
            self = .chart(
                kind: UIChartKind(raw: object["kind"]?.stringValue),
                series: series,
                unit: object["unit"]?.stringValue.flatMap(nonEmpty)
            )

        case "progress":
            self = .progress(
                label: object["label"]?.stringValue.flatMap(nonEmpty),
                value: fraction(object["value"]),
                caption: object["caption"]?.stringValue.flatMap(nonEmpty)
            )

        case "keyvalue":
            let items = (object["items"]?.arrayValue ?? []).compactMap(UIKeyValuePair.init(json:))
            guard !items.isEmpty else {
                self = .unsupported(type: "keyvalue (no items with a key and value)")
                return
            }
            self = .keyValue(items: items)

        case "code":
            guard let value = object["value"]?.stringValue.flatMap(nonEmpty) else {
                self = .unsupported(type: "code (missing value)")
                return
            }
            self = .code(language: object["language"]?.stringValue.flatMap(nonEmpty), value: value)

        case "callout":
            guard let value = object["value"]?.stringValue.flatMap(nonEmpty) else {
                self = .unsupported(type: "callout (missing value)")
                return
            }
            self = .callout(
                kind: UICalloutKind(raw: object["kind"]?.stringValue),
                title: object["title"]?.stringValue.flatMap(nonEmpty),
                value: value
            )

        case "image":
            guard let url = object["url"]?.stringValue.flatMap(nonEmpty) else {
                self = .unsupported(type: "image (missing url)")
                return
            }
            self = .image(
                url: url,
                alt: object["alt"]?.stringValue.flatMap(nonEmpty),
                box: UIImageBox(json: object),
                action: object["action"].flatMap { raw -> UIAction? in
                    guard let id = raw["id"]?.stringValue.flatMap(nonEmpty) else { return nil }
                    return UIAction(id: id, prompt: raw["prompt"]?.stringValue.flatMap(nonEmpty), raw: raw)
                }
            )

        case "divider":
            self = .divider

        case "button":
            guard let label = object["label"]?.stringValue.flatMap(nonEmpty) else {
                self = .unsupported(type: "button (missing label)")
                return
            }
            guard let raw = object["action"]?.objectValue,
                  let id = raw["id"]?.stringValue.flatMap(nonEmpty)
            else {
                self = .unsupported(type: "button (missing action.id)")
                return
            }
            self = .button(
                label: label,
                symbol: object["symbol"]?.stringValue.flatMap(nonEmpty),
                style: UIButtonStyle(raw: object["style"]?.stringValue),
                action: UIAction(id: id, prompt: raw["prompt"]?.stringValue.flatMap(nonEmpty), raw: .object(raw))
            )

        case "html":
            guard let value = object["value"]?.stringValue.flatMap(nonEmpty) else {
                self = .unsupported(type: "html (missing value)")
                return
            }
            let height = object["height"]?.doubleValue ?? UISpec.defaultHTMLHeight
            self = .html(value: value, height: min(max(height, 60), 1200))

        case let type:
            self = .unsupported(type: type.isEmpty ? "<missing>" : type)
        }
    }

    private static func children(of object: [String: JSONValue]) -> [UIComponent] {
        (object["children"]?.arrayValue ?? []).map(UIComponent.init(json:))
    }
}

// MARK: - Helpers

/// Clamps to 0…1, tolerating the two conventions models actually use: a fraction
/// and a percentage. Anything else would render as a full bar for `75`.
private func fraction(_ value: JSONValue?) -> Double {
    guard let raw = value?.doubleValue else { return 0 }
    let scaled = raw > 1 && raw <= 100 ? raw / 100 : raw
    return min(max(scaled, 0), 1)
}

private func token(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private extension JSONValue {
    /// JSON's own name for this node, used to make "unsupported" placeholders
    /// say what was actually there.
    var kindName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
