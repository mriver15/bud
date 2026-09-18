import Foundation

// MARK: - Provider

/// Exposes the generative-UI DSL to the model.
///
/// One tool, no state: the provider exists to document the DSL in the schema and
/// to translate the model's arguments into a `ToolResult.ui` payload. Because
/// the arguments *are* the surface the user sees, a malformed call is answered
/// with an error the model can act on rather than a silently empty panel.
public final class GenUIToolProvider: ToolProvider {
    public let providerID = "genui"
    public let providerName = "Interface"

    /// The model-facing tool name, run through the same sanitiser as every other
    /// provider so the name it sees can never fail DeepSeek's `^[a-zA-Z0-9_-]{1,64}$`.
    public static let renderToolName = ToolNaming.sanitize("render_ui")

    public init() {}

    public func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: Self.renderToolName,
                description: Self.toolDescription,
                schema: Self.renderUISchema,
                providerID: providerID,
                providerName: providerName
            )
        ]
    }

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard tool == Self.renderToolName else {
            return .error(
                "The \(providerName) provider exposes only '\(Self.renderToolName)'; it has no tool named '\(tool)'."
            )
        }
        guard let object = arguments.objectValue else {
            return .error(
                "\(Self.renderToolName) expects an object with a 'components' array; "
                + "received \(arguments.kindSummary)."
            )
        }
        guard let components = object["components"] else {
            return .error(
                "\(Self.renderToolName) requires 'components': an array of component objects "
                + "(text, metrics, row, columns, grid, card, list, table, chart, progress, keyvalue, "
                + "code, callout, image, divider, button, html). Nothing was rendered."
            )
        }
        guard let raw = components.arrayValue else {
            return .error(
                "'components' must be a JSON array of component objects; received \(components.kindSummary)."
            )
        }
        guard !raw.isEmpty else {
            return .error("'components' was an empty array, so there was nothing to render.")
        }
        guard let spec = UISpec(json: arguments) else {
            return .error(
                "\(Self.renderToolName) could not read the arguments as a spec; expected "
                + "{\"title\": \"…\", \"components\": [{\"type\": …}]}."
            )
        }

        var summary = "Rendered \(spec.components.count) top-level component"
        summary += spec.components.count == 1 ? "" : "s"
        summary += "."
        if !spec.unsupportedTypes.isEmpty {
            summary += " These component types were not understood and show as placeholders: "
            + spec.unsupportedTypes.joined(separator: ", ")
            + ". Valid types are listed in the tool schema."
        }
        return .ui(arguments, text: summary)
    }
}

// MARK: - Tool documentation

extension GenUIToolProvider {
    private static let toolDescription = """
    Render an interface in Bud's panel instead of writing prose. Use it for \
    comparisons, dashboards, status reports, key-figure summaries, tables, charts, \
    and any answer the user will scan rather than read. The spec is a JSON object \
    with an optional 'title' and a 'components' array; components nest through \
    'children'. Keep the components self-explanatory and do not repeat the same \
    content in a text component.
    """

    /// The model's only documentation for the DSL, so it spells out every
    /// component type and every field — including the fields that are required,
    /// which is the mistake models make most often.
    private static let componentReference = """
    Component shapes. The fields listed for a type are the complete set it uses; \
    all are optional unless marked required.
    - text: value (string, required), style (title|heading|body|caption|mono|quote, default body)
    - metrics: items (array, required) of {label, value, delta?, trend?}; value may be a number or an already-formatted string; trend is up|down|flat
    - row: children (array of components, required), gap? (number) — lays children out horizontally and wraps when the panel is too narrow
    - columns: children, gap? — same as row, but the children share the available width equally
    - grid: columns (integer, required), children (required) — fixed number of equal columns
    - card: children (required), title?, subtitle?, tint? (accent|success|warning|danger|blue|purple|pink|teal|gray or #RRGGBB)
    - list: items (array, required) of {title, subtitle?, badge?, symbol?}; symbol is an SF Symbol name
    - table: columns (array of strings, required), rows (array of arrays of strings), align? (one per column: left|right|center)
    - chart: series (array, required) of {label, value: number}, kind (bar|line|area, default bar), unit?
    - progress: value (number from 0 to 1, required), label?, caption?
    - keyvalue: items (array, required) of {key, value} — for properties and specs
    - code: value (string, required), language?
    - callout: value (required), kind (info|success|warning|error, default info), title?
    - image: url (required, http or https), alt?
    - divider: no fields
    - button: label (required), action (required: {id, prompt?}), symbol? (SF Symbol), style? (primary|secondary|destructive); tapping sends the action to the host and, when 'prompt' is present, sends it as the user's next message
    - html: value (required: an inline HTML fragment using inline CSS or SVG; scripts never run and links are inert), height? (number, default 220)
    """

    private static let renderUISchema: JSONValue = {
        let componentItem = objectSchema(
            componentReference,
            properties: [
                ("type", field("string", "The component type. One of the shapes described in this schema.", values: UISpec.knownComponentTypes)),
                ("value", field("string", "text, code, callout and html: the content. progress: use the number field instead.")),
                ("style", field("string", "text: title|heading|body|caption|mono|quote.", values: ["title", "heading", "body", "caption", "mono", "quote"])),
                ("title", field("string", "card, callout and the root spec: a heading above the content.")),
                ("subtitle", field("string", "card: a secondary line under the title.")),
                ("tint", field("string", "card: accent colour name or #RRGGBB hex.")),
                ("label", field("string", "metric item: the caption under the number. progress: the caption above the bar. button: the button text (required for button).")),
                ("delta", field("string", "metric item: the change to show next to the label, e.g. \"+12%\".")),
                ("trend", field("string", "metric item: the direction the delta points.", values: ["up", "down", "flat"])),
                ("items", alternatives(
                    "metric, list and keyvalue rows; the shape depends on the component type.",
                    [
                        objectSchema("metric", properties: [
                            ("label", field("string", "The metric's name.")),
                            ("value", field("string", "The big number, as a number or a pre-formatted string.")),
                            ("delta", field("string", "The change to show beside the label.")),
                            ("trend", field("string", "Direction of the change.", values: ["up", "down", "flat"])),
                        ], required: ["value"]),
                        objectSchema("list entry", properties: [
                            ("title", field("string", "Primary text.")),
                            ("subtitle", field("string", "Secondary text.")),
                            ("badge", field("string", "Short pill on the right, e.g. a status.")),
                            ("symbol", field("string", "SF Symbol name for the leading icon.")),
                        ], required: ["title"]),
                        objectSchema("key/value pair", properties: [
                            ("key", field("string", "The property name.")),
                            ("value", field("string", "The property value.")),
                        ], required: ["key", "value"]),
                    ]
                )),
                ("series", arraySchema(
                    "chart: the data points in left-to-right order.",
                    items: objectSchema("One point.", properties: [
                        ("label", field("string", "The x-axis label.")),
                        ("value", field("number", "The plotted value.")),
                    ], required: ["label", "value"]),
                    minItems: 1
                )),
                ("kind", alternatives(
                    "chart uses bar|line|area; callout uses info|success|warning|error.",
                    [
                        field("string", "chart", values: ["bar", "line", "area"]),
                        field("string", "callout", values: ["info", "success", "warning", "error"]),
                    ]
                )),
                ("unit", field("string", "chart: units for the value labels, e.g. \"%\" or \"ms\".")),
                ("columns", alternatives(
                    "grid: the number of columns (integer). table: the header labels (array of strings).",
                    [
                        field("integer", "grid: column count."),
                        arraySchema("table: header labels, left to right.", items: field("string", "A column heading."), minItems: 1),
                    ]
                )),
                ("rows", arraySchema(
                    "table: the body rows; each row is an array of cell strings in column order.",
                    items: arraySchema("One row.", items: field("string", "A cell value."))
                )),
                ("align", arraySchema(
                    "table: per-column alignment; index 0 aligns the first column.",
                    items: field("string", "Column alignment.", values: ["left", "right", "center"])
                )),
                ("children", arraySchema(
                    "row, columns, grid and card: the nested components, rendered in order.",
                    items: .object(["type": "object", "description": "A component object with a 'type' field."])
                )),
                ("gap", field("number", "row and columns: spacing in points between children.")),
                ("language", field("string", "code: the syntax label shown above the block, e.g. \"swift\".")),
                ("caption", field("string", "progress: a line of context under the bar.")),
                ("key", field("string", "keyvalue item: the property name.")),
                ("url", field("string", "image: an http, https, or file: URL (file: must be under ~/.bud).")),
                ("width", field("number", "image: width in points. Omit to fill the available width.")),

                ("fit", field("string", "image: fit (default) shows the whole image; fill crops it to the box.")),
                ("radius", field("number", "image: corner rounding in points. 0 for square corners.")),
                ("alt", field("string", "image: description shown when the image cannot load.")),
                ("symbol", field("string", "list item and button: an SF Symbol name.")),
                ("badge", field("string", "list item: a short pill on the right.")),
                ("height", field("number", "image: height in points — omit to keep the aspect ratio, ~96 for a sprite. html: pixel height of the frame, default 220.")),
                ("action", objectSchema(
                    "button: what happens when it is tapped.",
                    properties: [
                        ("id", field("string", "Identifier the host receives, e.g. \"open-settings\".")),
                        ("prompt", field("string", "A user message to send as a follow-up, e.g. \"Show the same breakdown for last quarter.\"")),
                    ],
                    required: ["id"]
                )),
            ],
            required: ["type"]
        )

        return objectSchema(
            "The interface to render. Components are drawn top to bottom inside one panel card.",
            properties: [
                ("title", field("string", "Optional heading for the whole surface.")),
                ("components", arraySchema(
                    "The components to render, in order.",
                    items: componentItem,
                    minItems: 1
                )),
            ],
            required: ["components"]
        )
    }()
}

// MARK: - Schema builders

private func field(_ type: String, _ description: String, values: [String] = []) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string(type),
        "description": .string(description),
    ]
    if !values.isEmpty { object["enum"] = .array(values.map { .string($0) }) }
    return .object(object)
}

private func objectSchema(
    _ description: String,
    properties: [(String, JSONValue)],
    required: [String] = []
) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": "object",
        "description": .string(description),
        "properties": .object(Dictionary(uniqueKeysWithValues: properties)),
    ]
    if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
    return .object(object)
}

private func arraySchema(_ description: String, items: JSONValue, minItems: Int? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": "array",
        "description": .string(description),
        "items": items,
    ]
    if let minItems { object["minItems"] = .number(Double(minItems)) }
    return .object(object)
}

/// For the two fields whose meaning depends on the component: `columns` is an
/// integer on `grid` and a string array on `table`, `kind` is a different enum
/// on `chart` and `callout`. One `oneOf` documents both without flattening them
/// into a permissive `["integer", "array"]`.
private func alternatives(_ description: String, _ options: [JSONValue]) -> JSONValue {
    .object([
        "description": .string(description),
        "oneOf": .array(options),
    ])
}

private extension JSONValue {
    /// Names the node for error messages, so a model that sent a string where an
    /// object belongs is told exactly that.
    var kindSummary: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .number: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }
}
