import Foundation

/// Built-in capabilities that do not come from an MCP server.
///
/// These are what make Bud useful before the user has connected anything: file
/// access, shell, and the web. Each is deliberately bounded — output caps and
/// timeouts — because every byte a tool returns is re-sent to the model on each
/// subsequent round of the turn.
///
/// `nonisolated` opts this type out of the implicit `@MainActor` that conforming
/// to `ToolProvider` would otherwise infer. These tools do pure file and network
/// work with no shared state, so running them on the main actor would block the
/// UI for the duration of every shell command and page fetch.
public nonisolated struct NativeToolsProvider: ToolProvider {
    public let providerID = "native"
    public let providerName = "Bud"

    /// Asked before a tool that changes the machine, and answered by whatever is
    /// holding the panel. `nil` means there is nobody to ask — the measurement
    /// CLIs, and checks that are exercising the tool rather than the gate — and
    /// the tool runs.
    ///
    /// Injected rather than reached for, because this provider is `nonisolated`
    /// and knows nothing about the UI; the policy lives with the thing that can
    /// show a dialog.
    public typealias Confirmation = @Sendable (ToolConfirmation) async -> ToolConfirmation.Decision

    private let confirm: Confirmation?

    public init(confirm: Confirmation? = nil) {
        self.confirm = confirm
    }

    /// The refusal a denied tool returns.
    ///
    /// A sentence rather than an error, because the model has to be able to read
    /// it and do something else: a refusal is a normal outcome of asking, not a
    /// failure of the tool. It says the command did not run, so a model that was
    /// about to report success knows it has nothing to report.
    static func refusal(for request: ToolConfirmation) -> ToolResult {
        .error(
            "The user declined this \(request.tool) call, so it was not run. "
                + "Do not repeat it as it stands — ask again differently, or do something else."
        )
    }

    /// Asks, if there is anyone to ask and the tool is one that changes things.
    /// Returns a refusal to return to the model, or `nil` to carry on.
    private func refusalUnlessConfirmed(tool: String, arguments: JSONValue) async -> ToolResult? {
        guard let confirm,
              let request = ToolConfirmation.request(
                  tool: tool,
                  arguments: arguments,
                  expandingTilde: { expand($0) }
              )
        else { return nil }

        let decision = await confirm(request)
        return decision.isAllowed ? nil : Self.refusal(for: request)
    }

    public nonisolated func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "read_file",
                description: "Read a file and return numbered lines. Text is read directly; a PDF "
                    + "gives up its text layer, and any text inside an image is read from the "
                    + "picture — so a screenshot of an error can be read, though Bud cannot see "
                    + "the picture itself. Use start_line/end_line to page large files.",
                schema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute or ~-relative path."],
                        "start_line": ["type": "integer", "description": "1-based first line."],
                        "end_line": ["type": "integer", "description": "1-based last line, inclusive."],
                    ],
                    "required": ["path"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "search_files",
                description: "Search the contents of files under a folder or a single file, and "
                    + "return the matching lines with their file and line number. Read-only: "
                    + "this is how to look through a codebase without a shell, which is why an "
                    + "agent that may not change anything can still find things. The pattern is "
                    + "a regular expression.",
                schema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Folder to search, or one file."],
                        "pattern": ["type": "string", "description": "Regular expression."],
                        "file_glob": [
                            "type": "string",
                            "description": "Only files whose name ends in this, e.g. .swift. Optional.",
                        ],
                        "max_results": ["type": "integer", "description": "Default 80."],
                    ],
                    "required": ["path", "pattern"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "read_stored",
                description: "Read a tool result that was too large to send. When a result "
                    + "exceeds what fits in a request, Bud keeps the whole thing and hands you "
                    + "a handle in the message that replaced it — this is how you get at the "
                    + "rest. Search it with a pattern, or read a line range, or call it with "
                    + "only the handle to see how big it is and where it starts.",
                schema: [
                    "type": "object",
                    "properties": [
                        "handle": [
                            "type": "string",
                            "description": "The store_ handle from the message you were given.",
                        ],
                        "pattern": [
                            "type": "string",
                            "description": "Return the lines matching this regular expression.",
                        ],
                        "start_line": ["type": "integer", "description": "1-based first line."],
                        "end_line": ["type": "integer", "description": "1-based last line, inclusive."],
                        "max_results": ["type": "integer", "description": "Default 80."],
                    ],
                    "required": ["handle"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "write_file",
                description: "Create or overwrite a text file. Creates parent directories. "
                    + "Prefer this over run_shell with redirection.",
                schema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"],
                    ],
                    "required": ["path", "content"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "list_files",
                description: "List files under a directory, optionally filtered by a glob pattern "
                    + "such as **/*.swift. Returns paths relative to the root.",
                schema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Directory to search. Defaults to the working directory."],
                        "pattern": ["type": "string", "description": "Glob, e.g. *.md or **/*.ts. Defaults to *."],
                        "max_results": ["type": "integer", "description": "Default 200."],
                    ],
                    "required": [],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "run_shell",
                description: "Run a shell command via zsh and return stdout, stderr and the exit code. "
                    + "Non-interactive: never use it for anything that needs a TTY or waits for input.",
                schema: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string"],
                        "cwd": ["type": "string", "description": "Working directory. Defaults to the user's home."],
                        "timeout_seconds": ["type": "integer", "description": "Default 60, max 600."],
                    ],
                    "required": ["command"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "web_fetch",
                description: "Fetch a URL and return it as readable text. HTML is converted to plain "
                    + "text. Use for documentation, articles and API responses.",
                schema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string"],
                        "max_chars": ["type": "integer", "description": "Default 40000."],
                    ],
                    "required": ["url"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
        ]
    }

    public nonisolated func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        do {
            switch tool {
            case "read_file": return try readFile(arguments)
            case "write_file":
                // Asked before it is done, not after: a confirmation that arrives
                // once the file is written is a notification.
                if let refused = await refusalUnlessConfirmed(tool: "write_file", arguments: arguments) {
                    return refused
                }
                return try writeFile(arguments)
            case "list_files": return try listFiles(arguments)
            case "search_files": return try searchFiles(arguments)
            case "read_stored": return try readStored(arguments)
            case "run_shell":
                if let refused = await refusalUnlessConfirmed(tool: "run_shell", arguments: arguments) {
                    return refused
                }
                return try await runShell(arguments)
            case "web_fetch": return try await webFetch(arguments)
            default: return .error("Unknown native tool '\(tool)'.")
            }
        } catch let error as ToolFailure {
            return .error(error.message)
        } catch {
            return .error("\(tool) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reading what a result was too large to carry

    private nonisolated func readStored(_ arguments: JSONValue) throws -> ToolResult {
        let raw = try Self.requiredString(arguments, "handle")
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The refusal names the shape, because a model that mistyped a handle can
        // fix that, and one that invented one should stop trying.
        guard StoredResults.isHandle(handle) else {
            return .error(
                "'\(raw)' is not a handle. Handles look like store_1a2b3c4d and are given to "
                    + "you in place of a result that was too large to send."
            )
        }
        guard StoredResults.read(handle: handle) != nil else {
            // Kept for the newest forty, so an old conversation's handle really can
            // be gone. Saying which of the two it is beats a bare failure.
            return .error(
                "Nothing stored under \(handle). Stored results are kept for the newest "
                    + "\(StoredResults.keep), and this one is no longer among them."
            )
        }

        let total = StoredResults.lineCount(handle: handle)

        if let pattern = arguments["pattern"]?.stringValue, !pattern.isEmpty {
            let limit = min(max(Int(arguments["max_results"]?.doubleValue ?? 80), 1), 400)
            let found = StoredResults.search(handle: handle, pattern: pattern, limit: limit)
            guard !found.isEmpty else {
                return .ok("No line in \(handle) matches \(pattern). It has \(BudFormat.count(total)) lines.")
            }
            return .ok(found.joined(separator: "\n"))
        }

        let start = max(1, Int(arguments["start_line"]?.doubleValue ?? 1))
        let end = Int(arguments["end_line"]?.doubleValue ?? Double(start + 199))
        let slice = StoredResults.lines(handle: handle, from: start, to: end)
        guard !slice.isEmpty else {
            return .error("\(handle) has \(BudFormat.count(total)) lines; \(BudFormat.count(start)) is past the end.")
        }
        var text = slice.joined(separator: "\n")
        if end < total {
            text += "\n…[\(BudFormat.count(total - end)) more lines. Ask for the next range, or search with a pattern.]"
        }
        return .ok(text)
    }

    // MARK: - Searching

    /// Grep, in Swift, with no shell in the path.
    ///
    /// A read-only agent cannot be given `run_shell` — it writes, and there is no
    /// flag that makes a shell safe — so without this the only agents that could
    /// search a codebase were the ones that could also delete it. That is backwards:
    /// looking through files is the thing read-only work mostly consists of.
    private nonisolated func searchFiles(_ arguments: JSONValue) throws -> ToolResult {
        let path = try Self.requiredString(arguments, "path")
        let pattern = try Self.requiredString(arguments, "pattern")
        let suffix = arguments["file_glob"]?.stringValue
        let limit = min(max(Int(arguments["max_results"]?.doubleValue ?? 80), 1), 400)

        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            return .error("That pattern is not a regular expression: \(error.localizedDescription)")
        }

        let root = URL(fileURLWithPath: expand(path))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return .error("Nothing at \(path).")
        }

        var files: [URL] = []
        if isDirectory.boolValue {
            files = Self.walk(root, suffix: suffix, cap: 2_000)
        } else {
            files = [root]
        }

        var matches: [String] = []
        var scanned = 0
        var truncated = false

        for file in files {
            if matches.count >= limit { truncated = true; break }
            // A file that is not text has nothing to match, and reading a large
            // binary to discover that is the difference between a search and a hang.
            guard let data = try? Data(contentsOf: file), data.count < 2_000_000,
                  !data.prefix(4_000).contains(0)
            else { continue }
            scanned += 1
            guard let text = String(data: data, encoding: .utf8) else { continue }

            let display = Self.tilde(file)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if matches.count >= limit { truncated = true; break }
                let string = String(line)
                let range = NSRange(string.startIndex..., in: string)
                guard expression.firstMatch(in: string, range: range) != nil else { continue }
                // Long lines are capped: a minified file matches once on line three
                // and would otherwise put a megabyte into the transcript.
                let clipped = string.count > 220 ? String(string.prefix(220)) + "…" : string
                matches.append("\(display):\(index + 1): \(clipped.trimmingCharacters(in: .whitespaces))")
            }
        }

        guard !matches.isEmpty else {
            return .ok("No match for \(pattern) in \(scanned) file\(scanned == 1 ? "" : "s").")
        }
        var text = matches.joined(separator: "\n")
        if truncated {
            text += "\n[stopped at \(limit) matches — narrow the pattern or raise max_results]"
        }
        return .ok(text)
    }

    /// Every file under `root`, skipping the parts of a tree that are never the
    /// answer: version control, build output, and anything enormous.
    private nonisolated static func walk(_ root: URL, suffix: String?, cap: Int) -> [URL] {
        let skipped: Set<String> = [
            ".git", ".build", "node_modules", ".venv", "venv", "__pycache__",
            "DerivedData", ".next", "dist", "target", ".cache",
        ]
        var found: [URL] = []
        var stack = [root]

        while let directory = stack.popLast() {
            guard found.count < cap else { break }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if !skipped.contains(entry.lastPathComponent) { stack.append(entry) }
                    continue
                }
                guard found.count < cap else { break }
                if let suffix, !suffix.isEmpty, !entry.lastPathComponent.hasSuffix(suffix) { continue }
                found.append(entry)
            }
        }
        return found
    }

    private nonisolated static func tilde(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private nonisolated static func requiredString(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue else {
            throw ToolFailure(message: "'\(key)' is required.")
        }
        return value
    }

    // MARK: - Errors

    struct ToolFailure: Error { let message: String }

    // MARK: - Paths

    private func expand(_ raw: String) -> String {
        var path = raw
        if path.hasPrefix("~") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        if path.hasPrefix("/") { return path }
        // Relative paths resolve against the user's home rather than the app's
        // cwd, which for a bundled .app is "/".
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(path).path
    }

    // MARK: - read_file

    private func readFile(_ args: JSONValue) throws -> ToolResult {
        guard let raw = args["path"]?.stringValue else {
            throw ToolFailure(message: "read_file requires 'path'.")
        }
        let path = expand(raw)

        // Checked before reading rather than after: a video or a disk image is
        // tens of megabytes, and loading one to discover it is not text costs
        // more than the answer is worth.
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
           size > 40_000_000 {
            throw ToolFailure(message: "\(path) is \(size / 1_000_000)MB, too large to read whole.")
        }
        guard let content = FileReading.read(path: path) else {
            throw ToolFailure(message: "No such file: \(path)")
        }

        let text: String
        var caption: String?
        switch content {
        case .text(let body):
            text = body
        case .extracted(let body, let note):
            // Worded as where the text came from, because the line numbers below
            // are the lines of the extraction, not lines that exist on disk.
            caption = note
            text = body
        case .unreadable(let reason):
            throw ToolFailure(message: "\(path) is \(reason).")
        }

        let all = text.components(separatedBy: "\n")
        let start = max(1, Int(args["start_line"]?.doubleValue ?? 1))
        let end = min(all.count, Int(args["end_line"]?.doubleValue ?? Double(all.count)))
        guard start <= end else {
            throw ToolFailure(message: "start_line \(start) is past end_line \(end) (file has \(all.count) lines).")
        }

        let width = String(end).count
        let body = (start...end).map { n -> String in
            let line = all[n - 1]
            return "\(String(format: "%\(width)d", n))\t\(line)"
        }.joined(separator: "\n")

        var header = "\(path) — lines \(start)-\(end) of \(all.count)"
        if end < all.count { header += " (\(all.count - end) more lines below)" }
        if let caption { header += "\n(\(caption))" }
        return .ok(header + "\n" + body)
    }

    // MARK: - write_file

    private func writeFile(_ args: JSONValue) throws -> ToolResult {
        guard let raw = args["path"]?.stringValue, let content = args["content"]?.stringValue else {
            throw ToolFailure(message: "write_file requires 'path' and 'content'.")
        }
        let path = expand(raw)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ToolFailure(message: "Could not write \(path): \(error.localizedDescription)")
        }
        let lines = content.components(separatedBy: "\n").count
        return .ok("Wrote \(content.utf8.count) bytes (\(lines) lines) to \(path).")
    }

    // MARK: - list_files

    private func listFiles(_ args: JSONValue) throws -> ToolResult {
        let root = expand(args["path"]?.stringValue ?? "~")
        let pattern = args["pattern"]?.stringValue ?? "*"
        let limit = min(2000, max(1, Int(args["max_results"]?.doubleValue ?? 200)))

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolFailure(message: "Not a directory: \(root)")
        }

        // A leading **/ means "any depth"; otherwise match the basename.
        let deep = pattern.contains("**/")
        let effective = pattern.replacingOccurrences(of: "**/", with: "")

        var out: [String] = []
        var truncated = false
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let item = enumerator?.nextObject() as? URL {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDir else { continue }
            let relative = item.path.replacingOccurrences(of: root + "/", with: "")
            let candidate = deep ? relative : item.lastPathComponent
            guard Self.globMatch(
                pattern: effective,
                in: candidate,
                crossesSeparators: deep
            ) else { continue }
            if out.count >= limit { truncated = true; break }
            out.append(relative)
        }

        guard !out.isEmpty else {
            return .ok("No files matching '\(pattern)' under \(root).")
        }
        let sorted = out.sorted()
        var body = sorted.joined(separator: "\n")
        if truncated { body += "\n…[truncated at \(limit) results]" }
        return .ok("\(sorted.count) file(s) under \(root) matching '\(pattern)':\n\(body)")
    }

    /// Glob supporting `*`, `?` and character ranges.
    ///
    /// `crossesSeparators` decides whether a wildcard may match `/`. It is true
    /// when the caller wrote a `**/` prefix (meaning "at any depth"), and false
    /// for a plain basename pattern — so `*.swift` matches `foo.swift` but not
    /// `src/foo.swift`, while `**/*.swift` matches both.
    static func globMatch(pattern: String, in path: String, crossesSeparators: Bool = false) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        let p = Array(pattern)
        let s = Array(path)

        /// Wildcards may not swallow a path separator unless the caller opted in.
        func isBlocked(_ ch: Character) -> Bool { ch == "/" && !crossesSeparators }

        func match(_ pi: Int, _ si: Int) -> Bool {
            var pi = pi, si = si
            while pi < p.count {
                switch p[pi] {
                case "*":
                    var next = pi + 1
                    while next < p.count, p[next] == "*" { next += 1 }
                    if next == p.count { return true }
                    var probe = si
                    while probe <= s.count {
                        if match(next, probe) { return true }
                        guard probe < s.count, !isBlocked(s[probe]) else { return false }
                        probe += 1
                    }
                    return false
                case "?":
                    guard si < s.count, !isBlocked(s[si]) else { return false }
                    pi += 1; si += 1
                case "[":
                    guard si < s.count, !isBlocked(s[si]) else { return false }
                    var ci = pi + 1
                    var negate = false
                    if ci < p.count, p[ci] == "!" || p[ci] == "^" { negate = true; ci += 1 }
                    var hit = false
                    var closed = false
                    while ci < p.count {
                        if p[ci] == "]" { closed = true; break }
                        if ci + 2 < p.count, p[ci + 1] == "-", p[ci + 2] != "]" {
                            if s[si] >= p[ci], s[si] <= p[ci + 2] { hit = true }
                            ci += 3
                        } else {
                            if p[ci] == s[si] { hit = true }
                            ci += 1
                        }
                    }
                    guard closed, hit != negate else { return false }
                    pi = ci + 1; si += 1
                default:
                    guard si < s.count, p[pi] == s[si] else { return false }
                    pi += 1; si += 1
                }
            }
            return si == s.count
        }
        return match(0, 0)
    }

    // MARK: - run_shell

    private func runShell(_ args: JSONValue) async throws -> ToolResult {
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            throw ToolFailure(message: "run_shell requires 'command'.")
        }
        let cwd = expand(args["cwd"]?.stringValue ?? "~")
        let timeout = min(600, max(1, args["timeout_seconds"]?.doubleValue ?? 60))

        let result = await Shell.run(
            executable: "/bin/zsh",
            args: ["-lc", command],
            cwd: FileManager.default.fileExists(atPath: cwd) ? cwd : nil,
            timeout: timeout
        )
        var out = ""
        if !result.stdout.isEmpty { out += result.stdout }
        if !result.stderr.isEmpty {
            out += (out.isEmpty ? "" : "\n") + "stderr:\n" + result.stderr
        }
        if result.timedOut {
            out += "\n[timed out after \(Int(timeout))s and was terminated]"
        }
        if out.isEmpty { out = "(no output)" }
        return result.code == 0 && !result.timedOut
            ? .ok("exit 0\n\(out)")
            : .error("exit \(result.code)\(result.timedOut ? " (timeout)" : "")\n\(out)")
    }

    // MARK: - web_fetch

    /// Whether a target is this machine or a network next to it.
    ///
    /// `web_fetch` takes its URL from a model, and the model may have read that
    /// URL on a page someone else wrote. Without this, `http://169.254.169.254/`
    /// — cloud instance metadata, credentials included — or `http://127.0.0.1:8080/`
    /// is fetched like any other page and its body joins the conversation.
    ///
    /// A name is resolved here and every address it answers with is checked, not
    /// just the literal-IP form: `http://localhost/` and a hostname that happens
    /// to point at 10.0.0.1 are the same request as the numbers. `localhost` is in
    /// `/etc/hosts` on every Mac, `.local` is Bonjour, and `.internal` is what a
    /// corporate resolver hands out. A name that does not resolve is refused
    /// rather than passed through.
    ///
    /// Residual limit: this resolves the name, and the connection resolves it
    /// again, so a name whose answer changes in between — DNS rebinding — still
    /// reaches an address refused here. Pinning the connection to the address that
    /// was checked would close it, and `URLSession` offers no way to ask for that;
    /// the redirect guard below closes the other way round the check.
    static func isBlockedTarget(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        guard !name.isEmpty else { return true }
        if name == "localhost"
            || name.hasSuffix(".localhost")
            || name.hasSuffix(".local")
            || name.hasSuffix(".internal") {
            return true
        }
        guard let addresses = resolvedAddresses(name) else { return true }
        return addresses.contains { isPrivateAddress($0) }
    }

    /// The refusal a blocked target produces, so the check before the request and
    /// the redirect guard after it say the same thing.
    static func blockedTargetMessage(_ host: String) -> String {
        let named = host.isEmpty ? "that address" : "'\(host)'"
        return "web_fetch refuses \(named): it is this machine, a private or link-local "
            + "address, or a name that resolves to one. Give a public http(s) URL instead."
    }

    /// Every address a name answers with, or `nil` when it does not resolve.
    private static func resolvedAddresses(_ host: String) -> [String]? {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let head = info else { return nil }
        defer { freeaddrinfo(head) }

        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            if let address = current.pointee.ai_addr {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address, current.pointee.ai_addrlen,
                    &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    out.append(String(decoding: bytes, as: UTF8.self))
                }
            }
            node = current.pointee.ai_next
        }
        return out
    }

    /// Whether a numeric address is loopback, link-local, private, or otherwise
    /// somewhere a fetch has no business going.
    static func isPrivateAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            guard b.count == 4 else { return true }
            switch b[0] {
            case 0, 10, 127: return true
            case 100: return (b[1] & 0xC0) == 64
            case 169: return b[1] == 254
            case 172: return (b[1] & 0xF0) == 16
            case 192: return b[1] == 168
            case 198: return b[1] == 18 || b[1] == 19
            default: return b[0] >= 224
            }
        }

        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return true }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        guard b.count == 16 else { return true }
        let isV4Mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
        if isV4Mapped {
            return isPrivateAddress("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
        }
        if b.allSatisfy({ $0 == 0 }) { return true }
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }
        if (b[0] & 0xFE) == 0xFC { return true }
        if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 { return true }
        return b[0] == 0xFF
    }

    private func webFetch(_ args: JSONValue) async throws -> ToolResult {
        guard let raw = args["url"]?.stringValue,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ToolFailure(message: "web_fetch requires a valid http(s) 'url'.")
        }
        let host = url.host() ?? ""
        guard !Self.isBlockedTarget(host) else {
            throw ToolFailure(message: Self.blockedTargetMessage(host))
        }
        let maxChars = min(200_000, max(500, Int(args["max_chars"]?.doubleValue ?? 40_000)))

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Apple Silicon) Bud/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30

        let redirects = WebFetchRedirectGuard()
        let (data, response) = try await URLSession.shared.data(for: request, delegate: redirects)
        // Checked before the status code: a refused redirect arrives as the 3xx
        // response itself, and "HTTP 302" would say nothing about why.
        if let refused = redirects.refusedHost {
            throw ToolFailure(message: Self.blockedTargetMessage(refused))
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToolFailure(message: "HTTP \(http.statusCode) for \(url.absoluteString)")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw ToolFailure(message: "Response was not UTF-8 text (\(data.count) bytes).")
        }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isHTML = contentType.contains("html") || body.lowercased().hasPrefix("<!doctype html")
            || body.lowercased().contains("<html")

        var text = isHTML ? Self.htmlToText(body) : body
        var note = ""
        if text.count > maxChars {
            note = "\n…[truncated \(text.count - maxChars) of \(text.count) characters]"
            text = String(text.prefix(maxChars))
        }
        return .ok("\(url.absoluteString)\n\n\(text)\(note)")
    }

    /// Strips markup down to readable prose. Not a full HTML parser — the goal is
    /// text the model can use, not fidelity. Script, style and SVG bodies are
    /// dropped entirely so nothing executable or decorative leaks in.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "svg", "noscript", "head"] {
            while let open = s.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = s.range(of: "</\(tag)>", options: .caseInsensitive),
                  open.lowerBound < close.upperBound {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        // Block elements become newlines so paragraphs do not run together.
        s = s.replacingOccurrences(
            of: "<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(
            of: "&#(\\d+);",
            with: "",
            options: .regularExpression
        )

        // Collapse the whitespace soup that tag removal leaves behind.
        let lines = s.components(separatedBy: "\n").map { line -> String in
            line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Fetch redirects

/// Refuses a redirect to somewhere `isBlockedTarget` would have refused.
///
/// The check before the request sees the URL the model gave; `URLSession` follows
/// what that page answers with. A public host that replies `302 Location:
/// http://127.0.0.1/` would otherwise make the check a formality, so the same
/// question is asked again for every hop, before the hop is made.
///
/// Cancelling a redirect delivers the 3xx response itself, so the caller reads the
/// refused host from here and reports it rather than a bare status code.
///
/// Internal rather than private so the decision can be put through the self-test
/// without a server that redirects to a private address — the one thing that is
/// awkward to arrange, and the only thing worth checking.
final class WebFetchRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: String?

    /// The host a redirect was refused for, or nil when none was.
    var refusedHost: String? { lock.withLock { blocked } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let host = request.url?.host() ?? ""
        guard !NativeToolsProvider.isBlockedTarget(host) else {
            lock.withLock { blocked = host }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - Process execution

/// Blocking `Process` wrapped for async callers.
///
/// `Process` is not `Sendable`, so it is created and torn down entirely inside
/// one background closure; only value types cross the boundary. Output is drained
/// through `readabilityHandler` rather than after exit, because a child that fills
/// a 64KB pipe buffer would otherwise block forever writing while we wait for it
/// to exit.
enum Shell {
    struct Output: Sendable {
        var code: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let cap: Int

        init(cap: Int) { self.cap = cap }

        func append(_ chunk: Data) {
            lock.withLock {
                guard data.count < cap else { return }
                data.append(chunk.prefix(cap - data.count))
            }
        }

        var string: String {
            lock.withLock { String(data: data, encoding: .utf8) ?? "" }
        }
    }

    static func run(
        executable: String,
        args: [String],
        cwd: String?,
        timeout: TimeInterval
    ) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

                var environment = ProcessInfo.processInfo.environment
                // Guarantees a predictable, colour-free, non-interactive shell.
                environment["TERM"] = "dumb"
                environment["NO_COLOR"] = "1"
                environment["CLICOLOR"] = "0"
                if environment["PATH"]?.isEmpty ?? true {
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                let outBuf = Buffer(cap: 1_000_000)
                let errBuf = Buffer(cap: 200_000)
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { outBuf.append(d) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { errBuf.append(d) }
                }

                var timedOut = false
                let killer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut = true
                    process.terminate()
                    // SIGTERM is not guaranteed for well-behaved-but-stuck
                    // children; escalate shortly after.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                var code: Int32 = -1
                do {
                    try process.run()
                    process.waitUntilExit()
                    code = process.terminationStatus
                } catch {
                    errBuf.append(Data("Could not launch \(executable): \(error.localizedDescription)".utf8))
                }
                killer.cancel()

                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever is still buffered in the pipe after the handlers
                // are removed.
                outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                continuation.resume(returning: Output(
                    code: code,
                    stdout: outBuf.string.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: errBuf.string.trimmingCharacters(in: .whitespacesAndNewlines),
                    timedOut: timedOut
                ))
            }
        }
    }
}
