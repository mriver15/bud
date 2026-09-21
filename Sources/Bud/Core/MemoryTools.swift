import Foundation

// MARK: - Provider

/// Bud's memory: two tools over the lessons the store keeps for it.
///
/// `remember` writes a fact worth carrying out of this conversation, `recall`
/// reads the list back. The provider holds no state of its own — the store is
/// already safe to call from any thread — so it is `nonisolated`, matching
/// `NativeToolsProvider`. A tool call that reaches SQLite must not run on the
/// main actor, or every lookup would freeze the window for the length of the
/// query.
public nonisolated struct MemoryToolsProvider: ToolProvider {
    public let providerID = "memory"
    public let providerName = "Memory"

    /// The scopes `remember` accepts, and the only values the store ever sees.
    static let scopes = ["general", "user", "project"]
    static let defaultScope = "general"

    /// Recall is bounded twice over: by a count, so one call cannot pull an
    /// unbounded list into the transcript, and by characters, because a single
    /// note can itself be long.
    static let defaultRecallLimit = 50
    static let maxRecallLimit = 200
    static let defaultRecallChars = 6_000
    static let maxRecallChars = 20_000

    public init() {}

    public nonisolated func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "remember",
                description: Self.rememberDescription,
                schema: [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": .string(
                                "The fact as one self-contained sentence, "
                                + "for example \"Prefers answers without preamble\". It is read "
                                + "back later without this conversation around it, so a bare "
                                + "\"that setting\" or \"the file above\" means nothing."
                            ),
                        ],
                        "scope": [
                            "type": "string",
                            "enum": ["general", "user", "project"],
                            "description": .string(
                                "user for how this person works or wants to be "
                                + "answered, project for a convention of their codebase, "
                                + "general (the default) for anything else."
                            ),
                        ],
                    ],
                    "required": ["text"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
            ToolDescriptor(
                name: "recall",
                description: Self.recallDescription,
                schema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "integer",
                            "description": "How many of the newest notes to return. Default 50, max 200.",
                        ],
                        "max_chars": [
                            "type": "integer",
                            "description": "Cap on the returned text. Default 6000, max 20000.",
                        ],
                    ],
                    "required": [],
                ],
                providerID: providerID,
                providerName: providerName
            ),
        ]
    }

    public nonisolated func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        do {
            switch tool {
            case "remember": return try remember(arguments)
            case "recall": return try recall(arguments)
            default:
                return .error(
                    "The \(providerName) provider exposes only 'remember' and 'recall'; "
                    + "it has no tool named '\(tool)'."
                )
            }
        } catch let error as ToolFailure {
            return .error(error.message)
        } catch {
            return .error("\(tool) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    struct ToolFailure: Error { let message: String }

    // MARK: - remember

    private func remember(_ args: JSONValue) throws -> ToolResult {
        guard let raw = args["text"]?.stringValue else {
            throw ToolFailure(message: "remember requires 'text': the fact to keep. Nothing was recorded.")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ToolFailure(message: "remember was given an empty 'text', so there was nothing to record.")
        }
        let scope = try scope(args)

        // Whether the fact was already known has to be decided before writing.
        // The store answers a duplicate the same way it answers a fresh write —
        // `INSERT OR IGNORE` reports success when it skips a row — so its return
        // value alone cannot distinguish the two, and a model told it saved
        // something it did not is worse served than one told nothing at all.
        //
        // The match is exact or near: a model that saves the same fact twice in
        // one round rephrases it, and two phrasings of one fact must not land as
        // two notes. Token containment catches the rephrasing without ever
        // refusing a genuinely different note.
        let existing = BudStore.lessons(limit: Int.max)
        if let known = knownNote(text, among: existing) {
            return .ok(alreadyKnownMessage(text, known: known.text))
        }

        guard BudStore.remember(text, scope: scope, source: BudStore.currentConversationID()) else {
            // Two concurrent remembers of one fact race the check above: both
            // see nothing, one insert wins, the other is ignored. The note IS
            // saved — report it as known rather than as a failure the model
            // would retry with yet another phrasing.
            let after = BudStore.lessons(limit: Int.max)
            if let known = knownNote(text, among: after) {
                return .ok(alreadyKnownMessage(text, known: known.text))
            }
            throw ToolFailure(message: "Bud could not write that note, so it was not saved. Try again.")
        }

        // The cognitive layer reads the same fact: an episode indexed by FTS, so
        // later rounds whose wording touches it see it in the memory section
        // without asking. Salience is high — a fact somebody asked to keep is
        // exactly the kind retrieval should surface.
        if let lesson = BudStore.lessons(limit: Int.max).first(where: { $0.text == text }) {
            CognitiveStore.recordEpisode(
                summary: text,
                scope: scope,
                salience: 0.8,
                source: "lesson:\(lesson.id)"
            )
        }

        return .ok(
            "Recorded \"\(summarise(text))\" as a \(scope) note. It survives this conversation like every "
            + "other note, so there is nothing to confirm to the user."
        )
    }

    /// The note already holding this fact: the same text, or one whose words
    /// mostly contain the new note's words. At least three shared words, and
    /// containment of three quarters or better — loose enough to miss nothing a
    /// person would call "the same note twice", tight enough that two notes
    /// merely about the same subject are both kept.
    private func knownNote(_ text: String, among lessons: [Lesson]) -> Lesson? {
        let newTokens = Set(TextRanking.tokens(in: text))
        guard newTokens.count >= 3 else { return nil }
        return lessons.first { lesson in
            guard lesson.text != text else { return true }
            let tokens = Set(TextRanking.tokens(in: lesson.text))
            guard tokens.count >= 3 else { return false }
            let shared = tokens.intersection(newTokens).count
            guard shared >= 3 else { return false }
            return Double(shared) / Double(max(tokens.count, newTokens.count)) >= 0.75
        }
    }

    private func alreadyKnownMessage(_ text: String, known: String) -> String {
        "Already known — \"\(summarise(text))\" matches your existing note "
            + "\"\(summarise(known))\", so nothing was recorded. "
            + "Do not claim you just saved it."
    }

    /// The scope the model asked for, defaulted and validated rather than passed
    /// through, so a typo cannot file a fact under a scope nothing ever reads.
    private func scope(_ args: JSONValue) throws -> String {
        guard let raw = args["scope"]?.stringValue else { return Self.defaultScope }
        let scope = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.scopes.contains(scope) else {
            throw ToolFailure(
                message: "scope must be one of \(Self.scopes.joined(separator: ", ")); got '\(raw)'. "
                    + "Nothing was recorded."
            )
        }
        return scope
    }

    /// A note quoted back to the model without letting a long one crowd out the
    /// result it needs to read.
    private func summarise(_ text: String) -> String {
        text.count <= 200 ? text : String(text.prefix(200)) + "…"
    }

    // MARK: - recall

    private func recall(_ args: JSONValue) throws -> ToolResult {
        let limit = boundedInt(args["limit"], fallback: Self.defaultRecallLimit, maximum: Self.maxRecallLimit)
        let cap = boundedInt(args["max_chars"], fallback: Self.defaultRecallChars, maximum: Self.maxRecallChars)

        // One row past the count asked for, so "there is more" can be said
        // without a second query.
        let rows = BudStore.lessons(limit: limit + 1)
        guard !rows.isEmpty else {
            return .ok("You have no saved notes yet. Nothing is carried over from earlier conversations.")
        }

        let more = rows.count > limit
        let shown = more ? Array(rows.prefix(limit)) : rows

        var text = more
            ? "Your saved notes, newest first (the \(shown.count) most recent):"
            : "Your saved notes, newest first:"
        for lesson in shown {
            text += "\n- \(Self.shortDate(lesson.createdAt)) [\(lesson.scope)] \(lesson.text)"
        }
        if more {
            text += "\n\nOlder notes exist; raise 'limit' to bring them in."
        }

        return .ok(bounded(text, at: cap))
    }

    /// Cuts on a line boundary so the last note shown is never a half sentence
    /// the model mistakes for the whole of it.
    private func bounded(_ text: String, at cap: Int) -> String {
        guard text.count > cap else { return text }
        let cut = text.index(text.startIndex, offsetBy: cap)
        var kept = String(text[..<cut])
        if let lastBreak = kept.lastIndex(of: "\n") { kept = String(kept[..<lastBreak]) }
        return kept + "\n\n…[\(text.count - kept.count) characters not shown]"
    }

    /// A plain calendar date. Built by hand rather than through a
    /// `DateFormatter`, which cannot be held in a static and would be rebuilt on
    /// every call.
    static func shortDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    /// Reads a count out of the arguments. Bounded in the `Double` domain before
    /// the conversion, because `Int(_:)` traps on a value a model can freely
    /// send as `1e400` or `infinity`.
    private func boundedInt(_ value: JSONValue?, fallback: Int, maximum: Int) -> Int {
        guard let raw = value?.doubleValue, raw.isFinite else { return min(fallback, maximum) }
        return Int(min(max(raw.rounded(), 1), Double(maximum)))
    }
}

// MARK: - Tool documentation

/// The model's only guidance on when these tools are worth calling. Both
/// descriptions name the situations that justify a call and the ones that do
/// not, because a memory tool described vaguely is either called on every turn
/// or never called at all.
extension MemoryToolsProvider {
    static let rememberDescription = """
    Save what would change how you help next time. The bar is usefulness rather \
    than interest: how they like to be answered, what they are working on and how \
    long they have been at it, what they already know so you do not explain it \
    again, and what they have already turned down, with the reason, so you do not \
    offer it twice. Notice these on your own initiative and keep them without \
    saying so — nobody has to ask, and nobody needs telling. Do not keep a log of \
    trivia or of anything that only matters now: the task in hand, a file you are \
    editing, this turn's output, or anything you could read again from the code \
    or the transcript. A fact already in your notes — even rephrased — comes back \
    as already known rather than being saved again.
    """

    static let recallDescription = """
    Read back the notes you saved with 'remember', newest first. The ones that bear \
    on what you are doing are already in front of you on every request, so reach for \
    this when you need the rest of them or the exact wording: before asking the user \
    to repeat a preference they have already given you, or when they refer to \
    something from an earlier conversation. It is a short list of your own notes, not \
    a search of past conversations, so it is cheap enough to call when in doubt.
    """
}
