import Foundation

/// The class of thing a tool wants to do to the machine or the world, from least
/// to most consequential.
///
/// The class is what the dialog labels, and what decides which scopes it may
/// offer. A read and a write are not the same decision: the first is about
/// showing something the user could already see, the second is about destroying
/// something that already exists. Keeping them separate is what lets the dialog
/// say "replace" for a file, "run" for a command, and "change" for an MCP server
/// without inventing a new surface for each.
public enum ToolRisk: String, Sendable, Equatable, CaseIterable {
    /// Reading a local file. Never confirmed — the user could already read it.
    case read
    /// Reading through a provider (an MCP server, a page fetch). Attributed in
    /// the transcript rather than confirmed.
    case externalRead
    /// Writing a file the user owns. Confirmed only when it replaces something.
    case localWrite
    /// Running a shell command. Always confirmed while the gate is on.
    case execution
    /// A mutation through a provider — an MCP server changing something outside
    /// this machine. Confirmed when the server asks for it.
    case externalMutation
    /// An MCP app handing text to the agent to act on. Not a machine mutation,
    /// but the same injection surface: app text becomes the next thing the agent
    /// runs with tools in its hands.
    case appMessage

    /// The class, as the dialog labels it.
    public var label: String {
        switch self {
        case .read: return "Read"
        case .externalRead: return "External read"
        case .localWrite: return "Local write"
        case .execution: return "Execution"
        case .externalMutation: return "External mutation"
        case .appMessage: return "Message from app"
        }
    }

    /// The symbol shown beside the headline, in the same family the panel uses.
    public var symbol: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .externalRead: return "globe"
        case .localWrite: return "square.and.pencil"
        case .execution: return "terminal"
        case .externalMutation: return "arrow.up.forward.square"
        case .appMessage: return "bubble.left.and.bubble.right"
        }
    }
}

/// One thing the agent wants to do to the machine, waiting for a person to agree
/// to it.
///
/// The gate exists because a tool result is not a trusted input. A page Bud was
/// asked to read, or an MCP server Bud was asked to talk to, lands in the same
/// context as the user's own instructions, and one of the tools in that turn runs
/// whatever shell command it is handed. Framing that content as data raises the
/// cost of an injection; this is the part that does not depend on the model
/// noticing.
///
/// Only the tools that change things ask. Reading a file the user can already
/// read, listing a directory, or fetching a page is not a decision somebody needs
/// to make every time, and a confirmation that appears constantly is one that
/// gets dismissed without being read.
public struct ToolConfirmation: Identifiable, Sendable, Equatable {

    /// What the person decided.
    public enum Decision: Sendable, Equatable {
        /// Run it, this once.
        case allow
        /// Run it, and everything else this tool is asked to do until Bud quits.
        ///
        /// Deliberately not written to the config: agreeing to something once, in
        /// the middle of a task, is not the same act as deciding it should be your
        /// standing preference forever. The setting in Settings is how that is
        /// expressed, and it is a different click in a different place.
        case allowForSession
        /// Run it, and everything else this tool is asked to do inside the same
        /// directory, until Bud quits. Offered only where a directory is in scope:
        /// a write's parent folder, a command's working directory.
        case allowForDirectory
        /// Do not run it. The tool returns this to the model as a refusal.
        case deny

        public var isAllowed: Bool { self != .deny }
    }

    public let id: UUID
    /// The tool being asked about, as the model named it.
    public let tool: String
    /// A sentence saying what is about to happen, in the app's voice.
    public let headline: String
    /// The thing itself: the command, or the path. Monospaced when shown.
    public let detail: String
    /// A second line of context — a working directory, a size — when there is one.
    public let note: String?
    /// The first few lines of a file being written, so the shape of it is visible
    /// without pasting a whole file into a dialog. `nil` for a command.
    public let preview: String?
    /// Whether `detail` is a shell command. A command is shown verbatim; a path is
    /// shown as the absolute path it will actually resolve to.
    public let isCommand: Bool
    /// The class of thing being asked about, shown as a label and used to decide
    /// which scopes the dialog may offer.
    public let risk: ToolRisk
    /// Whether this write replaces a file that already exists. A new file runs
    /// without asking; a replacement is a decision because it destroys something.
    public let overwrites: Bool
    /// The size, in bytes, of the file being replaced, when `overwrites`.
    public let overwrittenBytes: Int?
    /// The normalised directory an `.allowForDirectory` covers, when the class
    /// has one — a write's parent folder or a command's working directory.
    public let scopeDirectory: String?

    public init(
        id: UUID = UUID(),
        tool: String,
        headline: String,
        detail: String,
        note: String? = nil,
        preview: String? = nil,
        isCommand: Bool,
        risk: ToolRisk = .execution,
        overwrites: Bool = false,
        overwrittenBytes: Int? = nil,
        scopeDirectory: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.headline = headline
        self.detail = detail
        self.note = note
        self.preview = preview
        self.isCommand = isCommand
        self.risk = risk
        self.overwrites = overwrites
        self.overwrittenBytes = overwrittenBytes
        self.scopeDirectory = scopeDirectory
    }

    /// How much of a file's content to show. Enough to recognise what is being
    /// written, far short of pasting a generated file into a dialog.
    public static let previewCharacters = 400

    /// The request for a tool call, or `nil` for a tool that does not need one.
    ///
    /// Built from the arguments the model actually sent, not from the tool's
    /// description of itself, because the point is to show the person the real
    /// command rather than a summary of it.
    public static func request(
        tool: String,
        arguments: JSONValue,
        expandingTilde: (String) -> String
    ) -> ToolConfirmation? {
        switch tool {
        case "run_shell":
            guard let command = arguments["command"]?.stringValue,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let cwd = arguments["cwd"]?.stringValue
            return ToolConfirmation(
                tool: tool,
                headline: "Run this command?",
                detail: command,
                note: cwd.map { "in \(expandingTilde($0))" },
                isCommand: true,
                risk: .execution,
                scopeDirectory: normalizedDirectory(expandingTilde(cwd ?? "~"))
            )

        case "write_file":
            guard let raw = arguments["path"]?.stringValue else { return nil }
            let content = arguments["content"]?.stringValue ?? ""
            let path = expandingTilde(raw)
            // A new file runs without asking; only a replacement is a decision
            // somebody has to make, because it is the one thing that destroys
            // content that already exists.
            guard let size = existingSize(atPath: path) else { return nil }
            return ToolConfirmation(
                tool: tool,
                headline: "Replace this file?",
                detail: path,
                note: sizeText(size),
                preview: preview(of: content),
                isCommand: false,
                risk: .localWrite,
                overwrites: true,
                overwrittenBytes: size,
                scopeDirectory: normalizedDirectory((path as NSString).deletingLastPathComponent)
            )

        default:
            return nil
        }
    }

    /// The confirmation for a provider-side mutation — an MCP tool that changes
    /// something outside this machine. Named separately from `request` because it
    /// carries the server and the un-namespaced action, which the argument-only
    /// native path does not have.
    public static func externalMutation(
        server: String,
        action: String,
        tool: String,
        arguments: JSONValue
    ) -> ToolConfirmation {
        let args = nonEmptyArgumentsText(arguments)
        let detail = args.isEmpty ? action : "\(action) \(args)"
        return ToolConfirmation(
            tool: tool,
            headline: "Allow this change on \(server)?",
            detail: detail,
            note: nil,
            preview: nil,
            isCommand: false,
            risk: .externalMutation
        )
    }

    /// An MCP app asking to hand a message to the agent. Confirmed because an app
    /// is not the user: its text becomes the next thing the agent acts on, and it
    /// must not masquerade as the person's own input.
    public static func appMessage(server: String, message: String) -> ToolConfirmation {
        ToolConfirmation(
            tool: "ui/message",
            headline: "Allow \(server) to send a message?",
            detail: message,
            note: "The agent will read this and act on it.",
            preview: nil,
            isCommand: false,
            risk: .appMessage
        )
    }

    /// The beginning of a file, cut on a line boundary where there is one, so the
    /// preview reads as the start of something rather than a sentence cut in half.
    static func preview(of content: String) -> String? {
        guard !content.isEmpty else { return nil }
        guard content.count > previewCharacters else { return content }
        let head = String(content.prefix(previewCharacters))
        if let lastBreak = head.lastIndex(of: "\n") {
            return String(head[head.startIndex..<lastBreak])
        }
        return head
    }

    // MARK: - Mutation naming

    /// The verbs that mean "this changes something", matched on word boundaries
    /// of a tool's un-namespaced name. Deliberately over-inclusive: a false-
    /// positive confirmation costs a click, a silent mutation does not.
    private static let mutationVerbs: Set<String> = [
        "create", "update", "delete", "remove", "write", "put", "post", "patch",
        "push", "send", "submit", "install", "uninstall", "approve", "reject",
        "publish", "deploy", "move", "rename", "grant", "revoke", "set",
    ]

    /// Whether an un-namespaced tool name looks like it mutates something, by
    /// scanning for a mutation verb on a word boundary. `delete_issue`,
    /// `delete-issue` and `deleteIssue` all match; `getDelete` matches; a
    /// read-only `list_issues` does not.
    public static func looksLikeMutation(_ toolName: String) -> Bool {
        words(in: toolName).contains(where: mutationVerbs.contains)
    }

    /// Splits a name into lowercase words on non-alphanumeric boundaries and on
    /// lower→upper transitions, so `deleteIssue` and `delete_issue` yield the
    /// same `delete`.
    private static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if let p = previous, p.isLowercase, ch.isUppercase {
                    words.append(current)
                    current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    // MARK: - Small pieces

    /// The size in bytes of an existing file, or `nil` when nothing is there —
    /// the one fact that separates "create" from "replace".
    static func existingSize(atPath path: String) -> Int? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.size] as? Int
    }

    /// A human size, in the form Finder uses — "2.4 KB", "3.1 MB".
    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Collapses `.`/`..`/repeated slashes so two spellings of one folder share
    /// one scope key.
    static func normalizedDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The non-empty arguments of a call, as a single `key: value` line, so the
    /// dialog names what is being changed without pasting an empty argument block.
    private static func nonEmptyArgumentsText(_ arguments: JSONValue) -> String {
        guard let object = arguments.objectValue, !object.isEmpty else { return "" }
        let parts = object
            .sorted { $0.key < $1.key }
            .compactMap { (key, value) -> String? in
                let text = argumentText(value)
                guard !text.isEmpty else { return nil }
                return "\(key): \(text)"
            }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }

    private static func argumentText(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s):
            return s.count > 200 ? String(s.prefix(200)) + "…" : s
        case .array, .object:
            return value.encodedString()
        }
    }
}
