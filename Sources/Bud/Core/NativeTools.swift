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

    public init() {}

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
            case "write_file": return try writeFile(arguments)
            case "list_files": return try listFiles(arguments)
            case "search_files": return try searchFiles(arguments)
            case "run_shell": return try await runShell(arguments)
            case "web_fetch": return try await webFetch(arguments)
            default: return .error("Unknown native tool '\(tool)'.")
            }
        } catch let error as ToolFailure {
            return .error(error.message)
        } catch {
            return .error("\(tool) failed: \(error.localizedDescription)")
        }
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

    private func webFetch(_ args: JSONValue) async throws -> ToolResult {
        guard let raw = args["url"]?.stringValue,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ToolFailure(message: "web_fetch requires a valid http(s) 'url'.")
        }
        let maxChars = min(200_000, max(500, Int(args["max_chars"]?.doubleValue ?? 40_000)))

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Apple Silicon) Bud/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
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
