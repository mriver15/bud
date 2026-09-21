import Foundation

/// The browser, as tools.
///
/// Same idea as any other tool provider — the model is handed names, schemas and
/// results — but the payoff is different: this is what the Playwright MCP server
/// would have provided, without a Node install, an `npx` handshake, or a
/// Chromium download behind it. WebKit is already on the machine.
///
/// Three tools rather than one per verb, and that is a deliberate trade. Thirteen
/// tools meant thirteen schemas in every browser-shaped request and a menu in
/// which `browser_click`, `browser_press`, `browser_select` and `browser_hover`
/// were four ways of saying "act on the element with this ref" — a wide choice
/// set for a model already holding twenty other tools, and the wrong place to
/// spend the model's attention. One tool to go somewhere, one to look, one to
/// act, with the modes as enums in the schema.
///
/// The descriptions still carry more weight here than elsewhere, and now the
/// field descriptions carry most of it: a model that does not know it must read
/// the outline before it can click will guess a ref and learn from the refusal,
/// which costs a round trip and teaches it nothing about the page.
public final class BrowserToolProvider: ToolProvider {
    public let providerID = "browser"
    public let providerName = "Browser"

    private let engine: BrowserEngine

    /// The outline the model has most recently been shown, and the text it most
    /// recently read. Both are session state on the provider — what has been
    /// shown — not page state, so a fresh provider (a warm-up, a cost estimate)
    /// starts with no delta baseline.
    private var lastOutline: PageOutline?
    private var lastRead: LastRead?

    public init(engine: BrowserEngine) {
        self.engine = engine
    }

    // MARK: - Descriptors

    public func toolDescriptors() async -> [ToolDescriptor] {
        func field(_ type: String, _ description: String) -> JSONValue {
            .object(["type": .string(type), "description": .string(description)])
        }
        func variant(_ type: String, _ values: [String], _ description: String) -> JSONValue {
            .object([
                "type": .string(type),
                "enum": .array(values.map { .string($0) }),
                "description": .string(description),
            ])
        }
        func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ])
        }
        func tool(_ name: String, _ description: String, _ schema: JSONValue) -> ToolDescriptor {
            ToolDescriptor(
                name: name,
                description: description,
                schema: schema,
                providerID: providerID,
                providerName: providerName
            )
        }

        let open = tool(
            "browser_open",
            """
            Open a URL and wait for the page. Returns the outline — headings, links, \
            buttons, fields and checkboxes, each actionable item carrying the ref that \
            browser_act takes — and so does every action, so there is nothing to read \
            afterwards unless the page settles late.
            """,
            object([
                "url": field("string", "A full address, or a host like example.com."),
            ], required: ["url"])
        )

        let read = tool(
            "browser_read",
            """
            Look at the page. 'outline' is the page as it can be acted on and is what \
            assigns refs; take it when the page changed without you, and expect an older \
            ref to be refused. 'text' is the readable text, for when the outline is not \
            enough to read from. 'console' is what the page logged and threw, usually the \
            only evidence of why a page that looks fine is not working. 'screenshot' \
            saves a picture of the page for the user — you cannot see it.
            """,
            object([
                "mode": variant(
                    "string", ReadMode.allCases.map(\.rawValue), "Default 'outline'."
                ),
                "delta": field(
                    "boolean",
                    "outline and text: only what changed since the last read of that kind, "
                        + "which is worth it on a long page. The first delta returns everything "
                        + "and says so."
                ),
                "max_chars": field("integer", "text only. Default 40000."),
            ])
        )

        let act = tool(
            "browser_act",
            """
            Do something to the page, by the ref a read gave the element. Returns a fresh \
            outline unless snapshot_after is false.
            """,
            object([
                "action": variant(
                    "string", Act.allCases.map(\.rawValue),
                    "What to do; each action needs the fields its own entries below name."
                ),
                "ref": field(
                    "integer",
                    "click, type, hover, select: the element, by the ref the latest outline "
                        + "gave it."
                ),
                "text": field(
                    "string",
                    "type: what to put in the field, replacing what is there. wait: the text "
                        + "to wait for."
                ),
                "submit": field("boolean", "type: submit the field's form afterwards. Default false."),
                "value": field("string", "select: the option's value attribute."),
                "label": field("string", "select: the option's visible text, when there is no value."),
                "key": field(
                    "string",
                    "press: Enter, Tab, Escape, Backspace, PageDown, PageUp, Home, End, or an "
                        + "arrow key."
                ),
                "selector": field("string", "wait: a CSS selector to wait for, instead of text."),
                "timeout": field("number", "wait: seconds. Default 10."),
                "direction": field("string", "scroll: up, down, top or bottom. Default down."),
                "amount": field("integer", "scroll: pixels. Default 800."),
                "snapshot_after": field("boolean", "Whether to return a fresh outline. Default true."),
            ], required: ["action"])
        )

        return [open, read, act]
    }

    // MARK: - Invocation

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        do {
            switch tool {
            case "browser_open":
                guard let raw = string(arguments, "url") else {
                    return .error("browser_open needs a url.")
                }
                try await engine.open(raw)
                let outline = try await rememberOutline()
                return await showing("Opened \(engine.state.url)\n\n\(outline.render())", page: engine.state.title)

            case "browser_read":
                guard let requested = readMode(arguments) else {
                    let raw = string(arguments, "mode") ?? ""
                    return .error(
                        "There is no '\(raw)' mode; browser_read does "
                            + Self.readModeList + "."
                    )
                }
                switch requested {
                case .outline:
                    return .ok(try await outlineResult(delta: bool(arguments, "delta") ?? false))
                case .text:
                    return .ok(try await textResult(
                        limit: int(arguments, "max_chars") ?? 40_000,
                        delta: bool(arguments, "delta") ?? false
                    ))
                case .console:
                    let messages = try await engine.consoleMessages()
                    guard !messages.isEmpty else { return .ok("The page has logged nothing.") }
                    return .ok("Page console:\n" + messages.joined(separator: "\n"))
                case .screenshot:
                    let data = try await engine.screenshot()
                    guard let path = save(data) else {
                        return .error("The screenshot could not be written.")
                    }
                    return ToolResult(
                        text: "Saved a \(data.count / 1024)KB PNG of \(engine.state.url) to \(path). "
                            + "The user can see it; you cannot, so read the outline or the text if you "
                            + "need to know what is on the page.",
                        ui: Self.imageSpec(path: path, caption: engine.state.title)
                    )
                }

            case "browser_act":
                return try await act(arguments)

            default:
                return .error(
                    "The \(providerName) provider has three tools — browser_open, browser_read "
                        + "and browser_act — and none named '\(tool)'."
                )
            }
        } catch let error as BrowserError {
            // The message already says what to do about it — a stale ref names the
            // fix, and a bad address says what an address looks like.
            return .error(error.errorDescription ?? "The browser failed.")
        } catch {
            return .error("The browser failed: \(error.localizedDescription)")
        }
    }

    // MARK: - What the page looks like

    /// The outline, or only what moved since the last one.
    private func outlineResult(delta: Bool) async throws -> String {
        let outline = try await engine.outline()
        defer { lastOutline = outline }
        guard delta else { return outline.render() }
        guard let previous = lastOutline else {
            return outline.render()
                + "\n\nDelta mode is now active — the next outline reports only what changed."
        }
        return OutlineDelta.compare(previous: previous, current: outline).render(current: outline)
    }

    /// The readable text, or only what changed since the last read of it.
    private func textResult(limit: Int, delta: Bool) async throws -> String {
        let text = try await engine.readableText(limit: limit)
        let read = LastRead(url: engine.state.url, title: engine.state.title, text: text)
        defer { lastRead = read }
        guard delta else { return text }
        guard let previous = lastRead else {
            return text + "\n\nDelta mode is now active — the next read reports only what changed."
        }
        return Self.readDelta(previous: previous, current: read)
    }

    // MARK: - Acting on it

    /// Every action, dispatched from one enum.
    ///
    /// The per-action argument checks live here rather than in the schema, because
    /// a schema can say that `ref` exists and not that `ref` is meaningless for
    /// `press`. The refusals name the action and the field it needs, which is the
    /// same teaching the thirteen descriptions used to do one tool at a time.
    private func act(_ arguments: JSONValue) async throws -> ToolResult {
        guard let raw = string(arguments, "action") else {
            return .error(
                "browser_act needs 'action': one of " + Self.actionList + "."
            )
        }
        guard let action = Act(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            return .error("There is no '\(raw)' action; browser_act does " + Self.actionList + ".")
        }
        let snapshotAfter = bool(arguments, "snapshot_after") ?? true

        switch action {
        case .click:
            guard let ref = int(arguments, "ref") else {
                return .error("browser_act 'click' needs 'ref' — the number the latest outline gave the element.")
            }
            try await engine.click(ref: ref)
            guard snapshotAfter else {
                return await showing("Clicked ref \(ref).", page: engine.state.title)
            }
            return await showing(
                "Clicked ref \(ref).\n\n\(try await rememberOutline().render())",
                page: engine.state.title
            )

        case .type:
            guard let ref = int(arguments, "ref") else {
                return .error("browser_act 'type' needs 'ref' — the field's number from the latest outline.")
            }
            try await engine.type(
                ref: ref,
                text: string(arguments, "text") ?? "",
                submit: bool(arguments, "submit") ?? false
            )
            return await showing("Typed into ref \(ref).", page: engine.state.title)

        case .hover:
            guard let ref = int(arguments, "ref") else {
                return .error("browser_act 'hover' needs 'ref' — the number the latest outline gave the element.")
            }
            try await engine.hover(ref: ref)
            return await showing("Hovered over ref \(ref).", page: engine.state.title)

        case .select:
            guard let ref = int(arguments, "ref") else {
                return .error("browser_act 'select' needs 'ref' — the dropdown's number from the latest outline.")
            }
            try await engine.select(
                ref: ref,
                value: string(arguments, "value"),
                label: string(arguments, "label")
            )
            return await showing(
                "Chose an option in ref \(ref).\n\n\(try await rememberOutline().render())",
                page: engine.state.title
            )

        case .press:
            guard let key = string(arguments, "key") else {
                return .error("browser_act 'press' needs 'key', for example Enter or PageDown.")
            }
            try await engine.press(key)
            return await showing("Pressed \(key).", page: engine.state.title)

        case .scroll:
            try await engine.scroll(
                direction: string(arguments, "direction") ?? "down",
                amount: int(arguments, "amount") ?? 800
            )
            return .ok("Scrolled. Read the outline to see what is there now.")

        case .wait:
            let text = string(arguments, "text")
            let selector = string(arguments, "selector")
            guard text != nil || selector != nil else {
                return .error("browser_act 'wait' needs something to wait for: 'text' or 'selector'.")
            }
            let arrived = try await engine.wait(
                text: text,
                selector: selector,
                timeout: double(arguments, "timeout") ?? 10
            )
            let what = text.map { "text “\($0)”" } ?? "selector \(selector ?? "")"
            guard arrived else {
                return .error("Waited for \(what) and it did not appear.")
            }
            return await showing("Found \(what).", page: engine.state.title)

        case .back:
            try await engine.goBack()
            return await showing(
                "Went back to \(engine.state.url).\n\n\(try await rememberOutline().render())",
                page: engine.state.title
            )
        }
    }

    /// What `browser_act` can be asked to do, and the list the refusals print.
    enum Act: String, CaseIterable {
        case click, type, hover, select, press, scroll, wait, back
    }

    /// What `browser_read` can be asked for.
    enum ReadMode: String, CaseIterable {
        case outline, text, console, screenshot
    }

    private static var actionList: String {
        let names = Act.allCases.map(\.rawValue)
        guard let last = names.last else { return "" }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    /// The mode asked for, or nil when the name is not one of them. A typo is
    /// refused rather than defaulted: a model that asked for the console and was
    /// handed an outline would carry on believing it had read the console.
    private func readMode(_ arguments: JSONValue) -> ReadMode? {
        guard let raw = string(arguments, "mode") else { return .outline }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ReadMode(rawValue: name)
    }

    private static var readModeList: String {
        let names = ReadMode.allCases.map(\.rawValue)
        guard let last = names.last else { return "" }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    /// The same answer, with a picture of the page beside it.
    ///
    /// The model does not read the image — it gets the outline as text, because a
    /// screenshot is not something it can look at. The user does. A tool row that
    /// says "clicked ref 7" is much easier to trust, and to correct when it is
    /// wrong, with the page it clicked on screen next to it.
    private func showing(_ text: String, page: String) async -> ToolResult {
        guard let data = try? await engine.screenshot(), let path = save(data) else {
            return .ok(text)
        }
        return ToolResult(text: text, ui: Self.imageSpec(path: path, caption: page))
    }

    /// A one-image surface. Deliberately not a generic UI spec: this is the tool
    /// showing its own work, not the model asking for a drawing.
    private static func imageSpec(path: String, caption: String) -> JSONValue {
        .object([
            "title": .string(caption.isEmpty ? "Page" : caption),
            "components": .array([
                .object([
                    "type": .string("image"),
                    "url": .string(URL(fileURLWithPath: path).absoluteString),
                    "alt": .string(caption.isEmpty ? "Page" : caption),
                ]),
            ]),
        ])
    }

    /// Written where a person can find them, rather than into a temporary
    /// directory the system is free to empty.
    private func save(_ data: Data) -> String? {
        let directory = BudConfigLoader.budDirectory.appendingPathComponent("screenshots", isDirectory: true)
        // A screenshot is the page the session was signed into, so neither it nor
        // the directory it lands in is for anyone else on the machine.
        BudConfigLoader.createOwnerOnlyDirectory(directory)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("page-\(stamp).png")
        do {
            try BudConfigLoader.writeOwnerOnly(data, to: url)
            prune(directory)
            return url.path
        } catch {
            return nil
        }
    }

    /// Keeps the newest few and drops the rest.
    ///
    /// Every browser action leaves a PNG behind, and a browsing session can run
    /// to dozens. Left alone this becomes a directory nobody looks in and nobody
    /// clears, growing for the life of the install.
    private func prune(_ directory: URL, keeping: Int = 60) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let dated = entries
            .filter { $0.pathExtension == "png" }
            .compactMap { url -> (URL, Date)? in
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return date.map { (url, $0) }
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keeping) {
            try? manager.removeItem(at: url)
        }
    }

    // MARK: - Delta

    /// The page outline, remembered as what the model has now seen.
    ///
    /// Every outline the model receives is the baseline for the next delta, so
    /// the comparison is always against the most recent thing shown rather than
    /// the first.
    private func rememberOutline() async throws -> PageOutline {
        let outline = try await engine.outline()
        lastOutline = outline
        return outline
    }

    /// The text the model last read, with the identity that went with it, so a
    /// delta read can say the page moved on before diffing the prose.
    private struct LastRead {
        var url: String
        var title: String
        var text: String

        /// The prose as diffable lines; blank lines are layout, not content, so
        /// they are not compared.
        var lines: [String] {
            text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    /// The delta of a read: identity changes first, then the prose lines that
    /// appeared or vanished. Pure and deterministic, so it is reproducible.
    private static func readDelta(previous: LastRead, current: LastRead) -> String {
        let added = removedLines(from: current.lines, in: previous.lines)
        let removed = removedLines(from: previous.lines, in: current.lines)
        var sections: [String] = ["\(current.title)\n\(current.url)\n"]
        if previous.url != current.url { sections.append("URL changed: \(current.url)") }
        if previous.title != current.title { sections.append("Title changed: \(current.title)") }
        if added.isEmpty && removed.isEmpty {
            if previous.url == current.url && previous.title == current.title {
                return "\(current.title)\n\(current.url)\n\nNothing changed since the last read."
            }
            return sections.joined(separator: "\n")
        }
        sections.append("Text changed:")
        for line in added { sections.append("  + \(line)") }
        for line in removed { sections.append("  - \(line)") }
        return sections.joined(separator: "\n")
    }

    /// The lines of `a` not accounted for in `b`, counting duplicates, in `a`'s
    /// order. Prose has no refs to identify lines by, so identity is the text
    /// itself and a multiset difference is the honest report.
    private static func removedLines(from a: [String], in b: [String]) -> [String] {
        var remaining = b.reduce(into: [String: Int]()) { counts, line in
            counts[line, default: 0] += 1
        }
        var out: [String] = []
        for line in a {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
            } else {
                out.append(line)
            }
        }
        return out
    }

    // MARK: - Arguments

    private func string(_ arguments: JSONValue, _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func int(_ arguments: JSONValue, _ key: String) -> Int? {
        arguments[key]?.doubleValue.map(Int.init)
    }

    private func bool(_ arguments: JSONValue, _ key: String) -> Bool? {
        arguments[key]?.boolValue
    }

    private func double(_ arguments: JSONValue, _ key: String) -> Double? {
        arguments[key]?.doubleValue
    }
}
