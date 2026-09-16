import Foundation

/// The browser, as tools.
///
/// Same idea as any other tool provider — the model is handed names, schemas and
/// results — but the payoff is different: this is what the Playwright MCP server
/// would have provided, without a Node install, an `npx` handshake, or a
/// Chromium download behind it. WebKit is already on the machine.
///
/// The descriptions carry more weight here than elsewhere. A model that does not
/// know it must snapshot before it can click will call `browser_click` with a
/// guess and learn from the refusal, which costs a round trip and teaches it
/// nothing about the page.
public final class BrowserToolProvider: ToolProvider {
    public let providerID = "browser"
    public let providerName = "Browser"

    private let engine: BrowserEngine

    public init(engine: BrowserEngine) {
        self.engine = engine
    }

    // MARK: - Descriptors

    public func toolDescriptors() async -> [ToolDescriptor] {
        func tool(_ name: String, _ description: String, _ schema: [String: JSONValue]) -> ToolDescriptor {
            ToolDescriptor(
                name: name,
                description: description,
                schema: .object(schema),
                providerID: providerID,
                providerName: providerName
            )
        }
        func object(_ properties: [String: JSONValue], required: [String] = []) -> [String: JSONValue] {
            [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]
        }

        return [
            tool(
                "browser_open",
                "Open a URL in the browser and wait for the page to load. After this, call "
                    + "browser_snapshot to see what is on the page.",
                object([
                    "url": [
                        "type": "string",
                        "description": "A full address, or a host like example.com.",
                    ],
                ], required: ["url"])
            ),
            tool(
                "browser_snapshot",
                "The page as an outline: headings, text, and every link, button, field and checkbox, "
                    + "each action carrying a ref. Read this before acting — refs come from it, and "
                    + "acting on a ref that is not here fails.",
                object([:])
            ),
            tool(
                "browser_read",
                "The page's readable text, for when the outline is not enough and you need the prose.",
                object([
                    "max_chars": ["type": "integer", "description": "Default 40000."],
                ])
            ),
            tool(
                "browser_click",
                "Click an element by the ref a snapshot gave it. Use for links, buttons, checkboxes "
                    + "and anything that opens a menu.",
                object([
                    "ref": ["type": "integer", "description": "From the latest snapshot."],
                    "snapshot_after": [
                        "type": "boolean",
                        "description": "Include a fresh outline in the result. Default true, because the page usually changed.",
                    ],
                ], required: ["ref"])
            ),
            tool(
                "browser_type",
                "Type into a field by its ref. Replaces what is already there and tells the page the "
                    + "value changed, so frameworks that watch for typing see it.",
                object([
                    "ref": ["type": "integer"],
                    "text": ["type": "string"],
                    "submit": [
                        "type": "boolean",
                        "description": "Submit the field's form afterwards. Default false.",
                    ],
                ], required: ["ref", "text"])
            ),
            tool(
                "browser_hover",
                "Move the pointer over an element by its ref. For menus, tooltips and anything "
                    + "that only reveals itself on hover.",
                object([
                    "ref": ["type": "integer", "description": "From the latest snapshot."],
                ], required: ["ref"])
            ),
            tool(
                "browser_select",
                "Choose an option in a dropdown by its ref. Give either the option's value or its "
                    + "visible text.",
                object([
                    "ref": ["type": "integer"],
                    "value": ["type": "string", "description": "The option's value attribute."],
                    "label": ["type": "string", "description": "The option's visible text."],
                ], required: ["ref"])
            ),
            tool(
                "browser_wait",
                "Wait until some text appears, or an element matching a CSS selector exists. Use "
                    + "after an action on a page that loads its content late.",
                object([
                    "text": ["type": "string", "description": "Text to wait for."],
                    "selector": ["type": "string", "description": "A CSS selector to wait for."],
                    "timeout": ["type": "number", "description": "Seconds. Default 10."],
                ])
            ),
            tool(
                "browser_console",
                "What the page logged and what it threw. Usually the only evidence of why a page "
                    + "that looks fine is not working.",
                object([:])
            ),
            tool(
                "browser_press",
                "Press a key in the focused element: Enter, Tab, Escape, Backspace, PageDown, PageUp, "
                    + "Home, End, or an arrow key.",
                object([
                    "key": ["type": "string"],
                ], required: ["key"])
            ),
            tool(
                "browser_scroll",
                "Scroll the page. Use before a snapshot when the content you want is below the fold.",
                object([
                    "direction": [
                        "type": "string",
                        "description": "up, down, top or bottom. Default down.",
                    ],
                    "amount": ["type": "integer", "description": "Pixels. Default 800."],
                ])
            ),
            tool(
                "browser_back",
                "Go back one page in the browser's history.",
                object([:])
            ),
            tool(
                "browser_screenshot",
                "Save a PNG of the page as it looks and return the path. Layout and visual state that "
                    + "an outline cannot express — whether something is visible, what a banner says.",
                object([:])
            ),
        ]
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
                let outline = try await engine.snapshot()
                return await showing("Opened \(engine.state.url)\n\n\(outline)", page: engine.state.title)

            case "browser_snapshot":
                return .ok(try await engine.snapshot())

            case "browser_read":
                let limit = int(arguments, "max_chars") ?? 40_000
                return .ok(try await engine.readableText(limit: limit))

            case "browser_click":
                guard let ref = int(arguments, "ref") else {
                    return .error("browser_click needs the ref a snapshot gave the element.")
                }
                try await engine.click(ref: ref)
                guard bool(arguments, "snapshot_after") ?? true else {
                    return await showing("Clicked ref \(ref).", page: engine.state.title)
                }
                return await showing(
                    "Clicked ref \(ref).\n\n\(try await engine.snapshot())",
                    page: engine.state.title
                )

            case "browser_type":
                guard let ref = int(arguments, "ref") else {
                    return .error("browser_type needs the ref of the field.")
                }
                try await engine.type(
                    ref: ref,
                    text: string(arguments, "text") ?? "",
                    submit: bool(arguments, "submit") ?? false
                )
                return await showing("Typed into ref \(ref).", page: engine.state.title)

            case "browser_hover":
                guard let ref = int(arguments, "ref") else {
                    return .error("browser_hover needs the ref a snapshot gave the element.")
                }
                try await engine.hover(ref: ref)
                return await showing("Hovered over ref \(ref).", page: engine.state.title)

            case "browser_select":
                guard let ref = int(arguments, "ref") else {
                    return .error("browser_select needs the ref of the dropdown.")
                }
                try await engine.select(
                    ref: ref,
                    value: string(arguments, "value"),
                    label: string(arguments, "label")
                )
                return await showing(
                    "Chose an option in ref \(ref).\n\n\(try await engine.snapshot())",
                    page: engine.state.title
                )

            case "browser_wait":
                let text = string(arguments, "text")
                let selector = string(arguments, "selector")
                guard text != nil || selector != nil else {
                    return .error("browser_wait needs something to wait for: text or a selector.")
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

            case "browser_console":
                let messages = try await engine.consoleMessages()
                guard !messages.isEmpty else {
                    return .ok("The page has logged nothing.")
                }
                return .ok("Page console:\n" + messages.joined(separator: "\n"))

            case "browser_press":
                guard let key = string(arguments, "key") else {
                    return .error("browser_press needs a key.")
                }
                try await engine.press(key)
                return await showing("Pressed \(key).", page: engine.state.title)

            case "browser_scroll":
                try await engine.scroll(
                    direction: string(arguments, "direction") ?? "down",
                    amount: int(arguments, "amount") ?? 800
                )
                return .ok("Scrolled. Take a snapshot to see what is there now.")

            case "browser_back":
                try await engine.goBack()
                return await showing(
                    "Went back to \(engine.state.url).\n\n\(try await engine.snapshot())",
                    page: engine.state.title
                )

            case "browser_screenshot":
                let data = try await engine.screenshot()
                guard let path = save(data) else {
                    return .error("The screenshot could not be written.")
                }
                return ToolResult(
                    text: "Saved a \(data.count / 1024)KB PNG of \(engine.state.url) to \(path).",
                    ui: Self.imageSpec(path: path, caption: engine.state.title)
                )

            default:
                return .error("The \(providerName) provider has no tool named '\(tool)'.")
            }
        } catch let error as BrowserError {
            // The message already says what to do about it — a stale ref names the
            // fix, and a bad address says what an address looks like.
            return .error(error.errorDescription ?? "The browser failed.")
        } catch {
            return .error("The browser failed: \(error.localizedDescription)")
        }
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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("page-\(stamp).png")
        do {
            try data.write(to: url, options: .atomic)
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
