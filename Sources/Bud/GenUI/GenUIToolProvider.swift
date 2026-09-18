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

    /// The picture lookup, which lives here rather than in a provider of its own
    /// because it exists for one purpose: to have something to put in an image.
    public static let findToolName = ToolNaming.sanitize("find_image")

    public func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: Self.renderToolName,
                description: Self.toolDescription,
                schema: Self.renderUISchema,
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: Self.findToolName,
                description: Self.findToolDescription,
                schema: Self.findImageSchema,
                providerID: providerID,
                providerName: providerName
            ),
        ]
    }

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        if tool == Self.findToolName {
            return await findImages(arguments)
        }
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

    /// The model's only documentation for the DSL, so it spells out every component
    /// type and every field — including the fields that are required, which is the
    /// mistake models make most often.
    ///
    /// This is the whole vocabulary, and it is the only place it lives. It used to
    /// be written twice: once here, and again as a sentence on each field of the
    /// schema, where the same sentence had to name the component it belonged to
    /// because the schema is flat. Keeping one copy is most of why this tool is
    /// half the size it was — and the copy that went was the scattered one.
    ///
    /// Deliberately terse. Past the field names and their types a reader has what
    /// it needs, and every word here is sent whether or not anything is rendered.
    private static let componentReference = """
    Component shapes. The fields listed for a type are the complete set it uses; \
    all are optional unless marked required.
    - text: value (string, required), style (title|heading|body|caption|mono|quote, default body)
    - metrics: items (required) of {label, value, delta?, trend? (up|down|flat)}; value \
    may be a number or an already-formatted string
    - row / columns: children (required), gap? — children side by side, wrapping / \
    sharing the width equally
    - grid: columns (integer, required), children (required)
    - card: children (required), title?, subtitle?, tint? (accent|success|warning|danger|blue|purple|pink|teal|gray, or #RRGGBB)
    - list: items (required) of {title, subtitle?, badge?, symbol? (an SF Symbol name)}
    - table: columns (strings, required), rows (arrays of strings), align? (left|right|center, one per column)
    - chart: series (required) of {label, value (number)}, kind (bar|line|area, default bar), unit?
    - progress: value (number 0 to 1, required), label?, caption?
    - keyvalue: items (required) of {key, value}
    - code: value (required), language?
    - callout: value (required), kind (info|success|warning|error, default info), title?
    - image: url (required), alt?, width?, height?, fit? (fit|fill), radius?
    - divider: no fields
    - button: label (required), action (required: {id, prompt?}), symbol?, style? (primary|secondary|destructive)
    - html: value (required, inline HTML/CSS/SVG; scripts never run and links are inert), height? (default 220)

    Tapping a button sends its action to the host, and its `prompt` — when there is \
    one — is sent as the user's next message.

    Reach for a picture when one would carry something words cannot: a team of \
    creatures, a set of places, a row of products, a map, a logo. Call find_image \
    first — one call for a whole set of them — and put the URLs it returns straight \
    into image components. A card with a picture in it reads as finished; the same \
    card without one reads as a form. Do not invent urls: a guessed address is a \
    broken tile, and find_image exists so there is no reason to guess.
    """

    /// Looking a picture up, for a surface that would be clearer with one.
    private static let findToolDescription = """
        Find an image for something, to use in render_ui. Ask for one thing or a whole set \
        at once — six creatures is one call, not six. Wikipedia is tried first, so anything \
        with an article (a species, a place, a person, a product) comes back as its own \
        picture; anything else falls back to a search of Wikimedia Commons. Every result \
        carries the page it came from and its licence where the source states one, so credit \
        can be given.

        Use this whenever a surface would read better with a picture in it: a team, a \
        gallery of places, a product comparison, a diagram of something recognisable. Do \
        NOT invent image URLs — a made-up URL renders as a broken tile, and a lookup is one \
        call.
        """

    private static let findImageSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": field("string", "What to find a picture of."),
            "queries": .object([
                "type": .string("array"),
                "description": .string(
                    "Several things at once, up to \(ImageSearch.batchLimit). "
                        + "Use this rather than calling repeatedly."
                ),
                "items": .object(["type": .string("string")]),
            ]),
            "per_query": field("number", "How many options each, default 3, maximum 6."),
        ]),
    ])

    /// Best first. The result is a list of URLs the model can paste straight into
    /// an image component, with where each came from so it can be credited.
    private func findImages(_ arguments: JSONValue) async -> ToolResult {
        var queries: [String] = []
        if let one = arguments["query"]?.stringValue, !one.isEmpty { queries.append(one) }
        queries.append(contentsOf: (arguments["queries"]?.arrayValue ?? []).compactMap(\.stringValue))
        queries = queries.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !queries.isEmpty else {
            return .error("\(Self.findToolName) needs 'query', or 'queries' for a set of them.")
        }
        if queries.count > ImageSearch.batchLimit {
            queries = Array(queries.prefix(ImageSearch.batchLimit))
        }
        let perQuery = min(max(Int(arguments["per_query"]?.doubleValue ?? 3), 1), 6)

        let found = await ImageSearch.find(queries, perQuery: perQuery)
        guard !found.isEmpty else {
            return .ok("Nothing found for \(queries.map { "“\($0)”" }.joined(separator: ", ")).")
        }

        var lines: [String] = []
        // A query that found nothing is stated, not omitted. Dropping it silently
        // is how a broken lookup came back looking like a shorter answer.
        for query in queries where !found.contains(where: { $0.query == query }) {
            lines.append("")
            lines.append("\(query): nothing found — try a plainer or more specific name.")
        }
        var current = ""
        for image in found {
            if image.query != current {
                current = image.query
                lines.append("")
                lines.append("\(current):")
            }
            lines.append("  \(image.url)")
            var note = "    "
            switch image.source {
            case .article: note += "the article for it"
            // Said plainly, because the difference matters when the choice is
            // between a picture of the thing and a picture of someone dressed as it.
            case .search: note += "a match on the words — check the title before using it"
            }
            note += " · \(image.title)"
            if let credit = image.credit, !credit.isEmpty { note += " · \(credit)" }
            if let page = image.page, !page.isEmpty { note += " · \(page)" }
            lines.append(note)
        }
        let header = """
            Use these URLs directly in an image component — do not retype or shorten them. \
            An article image is the thing itself; anything else is the closest file whose \
            name matched, so read its title before putting it in front of someone.
            """
        return .ok(header + "\n" + lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let renderUISchema: JSONValue = {
        // Fields carry their name, their type and their enum and nothing else. The
        // sentence that used to sit on each one said which component it belonged
        // to, and that is a fact about a *flat* schema — the legend says it once,
        // to the same reader, for a fifth of the characters.
        //
        // Three keep a note, because their names do not say it: how big a picture
        // is when only one dimension is given, what an action's prompt does, and
        // that `children` holds components. Everything else is inferable, and a
        // model that infers wrongly is told exactly that by the renderer.
        let componentItem = objectSchema(
            componentReference,
            properties: [
                ("type", field("string", values: UISpec.knownComponentTypes)),
                ("value", field("string")),
                ("style", field("string", values: ["title", "heading", "body", "caption", "mono", "quote"])),
                ("title", field("string")),
                ("subtitle", field("string")),
                ("tint", field("string")),
                ("label", field("string")),
                ("delta", field("string")),
                ("trend", field("string", values: ["up", "down", "flat"])),
                ("items", alternatives([
                    objectSchema(properties: [
                        ("label", field("string")),
                        ("value", field("string")),
                        ("delta", field("string")),
                        ("trend", field("string", values: ["up", "down", "flat"])),
                    ], required: ["value"]),
                    objectSchema(properties: [
                        ("title", field("string")),
                        ("subtitle", field("string")),
                        ("badge", field("string")),
                        ("symbol", field("string")),
                    ], required: ["title"]),
                    objectSchema(properties: [
                        ("key", field("string")),
                        ("value", field("string")),
                    ], required: ["key", "value"]),
                ])),
                ("series", arraySchema(
                    items: objectSchema(properties: [
                        ("label", field("string")),
                        ("value", field("number")),
                    ], required: ["label", "value"]),
                    minItems: 1
                )),
                ("kind", alternatives([
                    field("string", values: ["bar", "line", "area"]),
                    field("string", values: ["info", "success", "warning", "error"]),
                ])),
                ("unit", field("string")),
                ("columns", alternatives([
                    field("integer"),
                    arraySchema(items: field("string"), minItems: 1),
                ])),
                ("rows", arraySchema(items: arraySchema(items: field("string")))),
                ("align", arraySchema(items: field("string", values: ["left", "right", "center"]))),
                ("children", arraySchema(
                    items: field("object", "A component object with a 'type' field.")
                )),
                ("gap", field("number")),
                ("language", field("string")),
                ("caption", field("string")),
                ("key", field("string")),
                ("url", field("string", "An http, https, or file: URL. file: must be under ~/.bud.")),
                ("width", field("number", "In points. Omit to fill the available width.")),
                ("fit", field("string", values: ["fit", "fill"])),
                ("radius", field("number")),
                ("alt", field("string")),
                ("symbol", field("string")),
                ("badge", field("string")),
                ("height", field("number", "Image: in points, and omitting it keeps the aspect ratio. html: default 220.")),
                ("action", objectSchema(
                    properties: [
                        ("id", field("string")),
                        ("prompt", field("string", "Sent as the user's next message.")),
                    ],
                    required: ["id"]
                )),
            ],
            required: ["type"]
        )

        return objectSchema(
            properties: [
                ("title", field("string", "Optional heading for the whole surface.")),
                ("components", arraySchema(items: componentItem, minItems: 1)),
            ],
            required: ["components"]
        )
    }()
}

// MARK: - Schema builders

private func field(_ type: String, _ description: String = "", values: [String] = []) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string(type)]
    if !description.isEmpty { object["description"] = .string(description) }
    if !values.isEmpty { object["enum"] = .array(values.map { .string($0) }) }
    return .object(object)
}

private func objectSchema(
    _ description: String = "",
    properties: [(String, JSONValue)],
    required: [String] = []
) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": "object",
        "properties": .object(Dictionary(uniqueKeysWithValues: properties)),
    ]
    if !description.isEmpty { object["description"] = .string(description) }
    if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
    return .object(object)
}

private func arraySchema(_ description: String = "", items: JSONValue, minItems: Int? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": "array",
        "items": items,
    ]
    if !description.isEmpty { object["description"] = .string(description) }
    if let minItems { object["minItems"] = .number(Double(minItems)) }
    return .object(object)
}

/// For the two fields whose meaning depends on the component: `columns` is an
/// integer on `grid` and a string array on `table`, `kind` is a different enum
/// on `chart` and `callout`. One `oneOf` documents both without flattening them
/// into a permissive `["integer", "array"]`.
private func alternatives(_ options: [JSONValue], _ description: String = "") -> JSONValue {
    var object: [String: JSONValue] = ["oneOf": .array(options)]
    if !description.isEmpty { object["description"] = .string(description) }
    return .object(object)
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
