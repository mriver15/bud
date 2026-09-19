import Foundation

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
/// Only the two tools that change the machine ask. Reading a file the user can
/// already read, listing a directory, or fetching a page is not a decision
/// somebody needs to make every time, and a confirmation that appears constantly
/// is one that gets dismissed without being read.
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

    public init(
        id: UUID = UUID(),
        tool: String,
        headline: String,
        detail: String,
        note: String? = nil,
        preview: String? = nil,
        isCommand: Bool
    ) {
        self.id = id
        self.tool = tool
        self.headline = headline
        self.detail = detail
        self.note = note
        self.preview = preview
        self.isCommand = isCommand
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
                isCommand: true
            )

        case "write_file":
            guard let raw = arguments["path"]?.stringValue else { return nil }
            let content = arguments["content"]?.stringValue ?? ""
            return ToolConfirmation(
                tool: tool,
                headline: "Write this file?",
                detail: expandingTilde(raw),
                note: content.isEmpty ? "empty file" : "\(content.count) characters",
                preview: preview(of: content),
                isCommand: false
            )

        default:
            return nil
        }
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
}
