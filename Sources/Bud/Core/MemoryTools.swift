import Foundation

// MARK: - Provider

/// Bud's memory as one tool with modes: what the model keeps, and what it can
/// find, change and drop.
///
/// It used to be two tools that could only add and read back — `remember` and
/// `recall` — so a note that had gone stale, or was wrong, or duplicated
/// something already there, could only be corrected by the person, in Settings.
/// The model that wrote it in the first place is the one that knows it is wrong.
///
/// One tool rather than five, because five tools cost five schemas in every
/// request, and because the modes share everything that matters: the note store,
/// the scope vocabulary, the bounds on how much text comes back. `mode` is an
/// enum in the schema, so the model picks from the modes that exist rather than
/// remembering their names.
///
/// The provider holds no state of its own — the store is already safe to call
/// from any thread — so it is `nonisolated`, matching `NativeToolsProvider`. A
/// tool call that reaches SQLite must not run on the main actor, or every lookup
/// would freeze the window for the length of the query.
public nonisolated struct MemoryToolsProvider: ToolProvider {
    public let providerID = "memory"
    public let providerName = "Memory"

    public static let toolName = "memory"

    /// What the tool can be asked to do.
    enum Mode: String, CaseIterable {
        /// Find notes by wording — ranked, and tolerant of how the question is
        /// phrased.
        case search
        /// Read the notes back, newest first.
        case list
        /// Keep something new.
        case remember
        /// Rewrite a note in place, keeping its id.
        case update
        /// Drop a note and everything filed beside it.
        case forget
    }

    /// The scopes the store accepts, and the only values it ever sees.
    static let scopes = ["general", "user", "project"]
    static let defaultScope = "general"

    /// Bounds, so one call cannot pull the whole store into the transcript. The
    /// search limit is small because a search that returns twenty notes has
    /// answered nothing; the list keeps the older, looser bound.
    static let defaultSearchLimit = 5
    static let maxSearchLimit = 20
    static let defaultListLimit = 50
    static let maxListLimit = 200
    static let defaultChars = 6_000
    static let maxChars = 20_000

    public init() {}

    public nonisolated func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: Self.toolName,
                description: Self.toolDescription,
                schema: [
                    "type": "object",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "enum": .array(Mode.allCases.map { .string($0.rawValue) }),
                            "description": .string(
                                "search to find a note by wording, list to read them back, "
                                + "remember to keep something new, update to rewrite one, "
                                + "forget to drop one."
                            ),
                        ],
                        "text": [
                            "type": "string",
                            "description": .string(
                                "remember and update: the note as one self-contained "
                                + "sentence, for example \"Prefers answers without preamble\". It "
                                + "is read back later without this conversation around it, so a "
                                + "bare \"that setting\" or \"the file above\" means nothing."
                            ),
                        ],
                        "id": [
                            "type": "integer",
                            "description": .string(
                                "update and forget: the note's id, exactly as search or list "
                                + "returned it. There is no way to name a note by its wording "
                                + "here — a fuzzy match deleting the wrong memory is worse than "
                                + "one more call."
                            ),
                        ],
                        "query": [
                            "type": "string",
                            "description": .string(
                                "search: what to look for, in whatever words you have. The "
                                + "match is ranked and tolerant of phrasing, so a few words "
                                + "that belong to the note are enough."
                            ),
                        ],
                        "scope": [
                            "type": "string",
                            "enum": ["general", "user", "project"],
                            "description": .string(
                                "user for how this person works or wants to be answered, "
                                + "project for a convention of their codebase, general (the "
                                + "default) for anything else. On list and search it filters; "
                                + "on update it re-files."
                            ),
                        ],
                        "limit": [
                            "type": "integer",
                            "description": .string(
                                "search: how many notes to return, default 5, max 20. "
                                + "list: how many, default 50, max 200."
                            ),
                        ],
                        "max_chars": [
                            "type": "integer",
                            "description": "Cap on the returned text. Default 6000, max 20000.",
                        ],
                    ],
                    "required": ["mode"],
                ],
                providerID: providerID,
                providerName: providerName
            )
        ]
    }

    public nonisolated func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard tool == Self.toolName else {
            return .error(
                "The \(providerName) provider exposes '\(Self.toolName)' and nothing else; "
                + "it has no tool named '\(tool)'."
            )
        }
        do {
            return try perform(arguments)
        } catch let error as ToolFailure {
            return .error(error.message)
        } catch {
            return .error("\(Self.toolName) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    struct ToolFailure: Error { let message: String }

    /// The mode every call has to name, validated against the enum rather than
    /// passed through: a misspelt mode must not fall back to a write.
    private func mode(_ args: JSONValue) throws -> Mode {
        guard let raw = args["mode"]?.stringValue else {
            throw ToolFailure(
                message: "\(Self.toolName) requires 'mode': one of "
                    + Self.modeList + ". Nothing was done."
            )
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = Mode(rawValue: name) else {
            throw ToolFailure(
                message: "There is no '\(raw)' mode; the modes are " + Self.modeList
                    + ". Nothing was done."
            )
        }
        return mode
    }

    private static var modeList: String {
        let names = Mode.allCases.map(\.rawValue)
        guard let last = names.last else { return "" }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    private func perform(_ args: JSONValue) throws -> ToolResult {
        switch try mode(args) {
        case .search: return try search(args)
        case .list: return try list(args)
        case .remember: return try remember(args)
        case .update: return try update(args)
        case .forget: return try forget(args)
        }
    }

    // MARK: - remember

    private func remember(_ args: JSONValue) throws -> ToolResult {
        let text = try body(args, for: .remember)
        let scope = try scope(args, default: Self.defaultScope)

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
        let existing = notes()
        if let known = knownNote(text, among: existing) {
            return .ok(alreadyKnownMessage(text, known: known.text))
        }

        guard BudStore.remember(text, scope: scope, source: BudStore.currentConversationID()) else {
            // Two concurrent remembers of one fact race the check above: both
            // see nothing, one insert wins, the other is ignored. The note IS
            // saved — report it as known rather than as a failure the model
            // would retry with yet another phrasing.
            let after = notes()
            if let known = knownNote(text, among: after) {
                return .ok(alreadyKnownMessage(text, known: known.text))
            }
            throw ToolFailure(message: "Bud could not write that note, so it was not saved. Try again.")
        }

        // The id is the handle the rest of the modes take, so it is handed over
        // at the moment the note is made rather than left to be found later.
        if let lesson = notes().first(where: { $0.text == text }) {
            fileCognitiveCopy(text: text, scope: scope, lessonID: lesson.id)
            return .ok(
                "Recorded note \(lesson.id): \"\(summarise(text))\" [\(scope)]. It survives this "
                + "conversation like every other note, so there is nothing to confirm to the "
                + "user. Change it later with mode 'update', drop it with 'forget'."
            )
        }
        return .ok("Recorded \"\(summarise(text))\" as a \(scope) note.")
    }

    /// The cognitive layer reads the same note: an episode indexed by FTS, so
    /// later rounds whose wording touches it see it in the memory section without
    /// asking, and — for a structured note — a fact, so a query naming the subject
    /// retrieves it directly. Written by one function because `remember` and
    /// `update` must leave exactly the same shape behind.
    private func fileCognitiveCopy(text: String, scope: String, lessonID: Int) {
        CognitiveStore.recordEpisode(
            summary: text,
            scope: scope,
            salience: 0.8,
            source: "lesson:\(lessonID)"
        )
        // "Editor: Xcode" — the same promotion rule the migration applied to
        // existing notes, so what is written now behaves like what was written
        // before.
        guard scope != "general", let colon = text.firstIndex(of: ":") else { return }
        let subject = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, subject.count <= 60,
              subject.allSatisfy({ !$0.isWhitespace }),
              !value.isEmpty, value.count <= 200
        else { return }
        _ = CognitiveStore.recordFact(
            subject: subject,
            value: value,
            scope: scope,
            source: "lesson:\(lessonID)"
        )
    }

    /// The copies that have to go when a note is rewritten or dropped: the ones
    /// filed beside it, and any copy of the same sentence that nothing owns.
    private func dropCognitiveCopies(of text: String, lessonID: Int) {
        CognitiveStore.deleteBySource("lesson:\(lessonID)")
        CognitiveStore.deleteUnownedEpisodes(matching: text)
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

    // MARK: - search

    private func search(_ args: JSONValue) throws -> ToolResult {
        guard let raw = args["query"]?.stringValue else {
            throw ToolFailure(
                message: "mode 'search' needs 'query': what to look for. Nothing was searched."
            )
        }
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolFailure(message: "mode 'search' was given an empty 'query'.")
        }
        let limit = boundedInt(args["limit"], fallback: Self.defaultSearchLimit, maximum: Self.maxSearchLimit)
        let cap = boundedInt(args["max_chars"], fallback: Self.defaultChars, maximum: Self.maxChars)
        let wanted = try optionalScope(args)
        let candidates = scopeFiltered(notes(), by: wanted)

        let matches = rank(candidates, against: query).prefix(limit)

        var lines: [String] = []
        if matches.isEmpty {
            lines.append(nothingMatched(query, among: candidates, wanted: wanted))
        } else {
            lines.append(
                matches.count == 1
                    ? "1 note matches '\(query)':"
                    : "\(matches.count) notes match '\(query)', best first:"
            )
            for match in matches {
                lines.append(
                    "- \(match.lesson.id) [\(match.lesson.scope)] \(Self.shortDate(match.lesson.createdAt)) "
                        + "— \(match.lesson.text)" + (match.why.isEmpty ? "" : "  (matched: \(match.why))")
                )
            }
            lines.append(
                "Change one with mode 'update' and its id; drop one with mode 'forget' and its id."
            )
        }

        // Instructions the person wrote are memory too, and the model should know
        // they exist rather than concluding nothing is kept. They are reported
        // and not offered for editing: they are the person's own words.
        let instructions = matchingDirectives(query, limit: 2)
        if !instructions.isEmpty {
            lines.append("")
            lines.append(
                "Also matched \(instructions.count == 1 ? "a standing instruction" : "standing instructions") "
                    + "you wrote, not mine to change: "
                    + instructions.map { "\"\(summarise($0.text))\"" }.joined(separator: ", ")
                    + ". The person removes those in Memory settings."
            )
        }

        return .ok(bounded(lines.joined(separator: "\n"), at: cap))
    }

    private func nothingMatched(_ query: String, among candidates: [Lesson], wanted: String?) -> String {
        let scopeClause = wanted.map { " in \($0) notes" } ?? ""
        guard !candidates.isEmpty else {
            return "No notes match '\(query)', and there are no\(scopeClause) notes at all."
        }
        return "No note matches '\(query)'\(scopeClause). \(candidates.count) note(s) exist; "
            + "mode 'list' shows them all."
    }

    /// The notes that answer a query, best first, with the words that put each
    /// one there.
    ///
    /// Three passes, and the order between them is the whole design. A note
    /// containing the query verbatim is what was asked for. Failing that, the
    /// same IDF-weighted overlap the prompt's own note ranking uses — so a
    /// wording that shares the note's words finds it. Failing that, a prefix
    /// pass, because the words a model reaches for are often only nearly the
    /// words in the note: "migration" against "migrations", "preferences"
    /// against "prefers". Each pass only runs while nothing has matched, so a
    /// precise query cannot be diluted by a loose one.
    private func rank(_ lessons: [Lesson], against query: String) -> [Match] {
        let lowered = query.lowercased()
        let substring = lessons
            .filter { $0.text.lowercased().contains(lowered) }
            .map { Match(lesson: $0, score: 3, why: "the words themselves") }
        if !substring.isEmpty { return substring }

        let terms = TextRanking.tokens(in: query)
        guard !terms.isEmpty else { return [] }
        let documents = lessons.map { TextRanking.tokens(in: $0.text) }
        let scored = TextRanking.scores(terms: terms, documents: documents)
        var ranked: [Match] = []
        for (index, score) in scored.enumerated() where score > 0 {
            let shared = terms.filter { documents[index].contains($0) }
            ranked.append(
                Match(lesson: lessons[index], score: score, why: shared.prefix(4).joined(separator: ", "))
            )
        }
        if !ranked.isEmpty {
            return ranked.sorted { $0.score > $1.score }
        }

        // The prefix pass. Four characters is short enough to catch a stem and
        // long enough that "data" does not match "database" by accident.
        var fuzzy: [Match] = []
        for (index, lesson) in lessons.enumerated() {
            let words = Set(documents[index])
            let near = terms.filter { term in
                words.contains { word in
                    word != term && word.count >= 4 && term.count >= 4
                        && (word.hasPrefix(term) || term.hasPrefix(word)
                            || word.prefix(4) == term.prefix(4))
                }
            }
            guard !near.isEmpty else { continue }
            fuzzy.append(
                Match(lesson: lesson, score: Double(near.count), why: near.prefix(3).joined(separator: ", "))
            )
        }
        return fuzzy.sorted { $0.score > $1.score }
    }

    private struct Match {
        let lesson: Lesson
        let score: Double
        let why: String
    }

    // MARK: - list

    private func list(_ args: JSONValue) throws -> ToolResult {
        let limit = boundedInt(args["limit"], fallback: Self.defaultListLimit, maximum: Self.maxListLimit)
        let cap = boundedInt(args["max_chars"], fallback: Self.defaultChars, maximum: Self.maxChars)
        let wanted = try optionalScope(args)

        // One row past the count asked for, so "there is more" can be said
        // without a second query.
        let rows = scopeFiltered(notes(), by: wanted)
        guard !rows.isEmpty else {
            return .ok(
                wanted.map { "You have no \($0) notes yet." }
                    ?? "You have no saved notes yet. Nothing is carried over from earlier conversations."
            )
        }

        let more = rows.count > limit
        let shown = more ? Array(rows.prefix(limit)) : rows
        var text = "Your saved notes, newest first" + (wanted.map { ", \($0) only" } ?? "") + ":"
        for lesson in shown {
            text += "\n- \(lesson.id) [\(lesson.scope)] \(Self.shortDate(lesson.createdAt)) \(lesson.text)"
        }
        if more {
            text += "\n\n\(rows.count - shown.count) older note(s) exist; raise 'limit' for them."
        }
        return .ok(bounded(text, at: cap))
    }

    // MARK: - update

    private func update(_ args: JSONValue) throws -> ToolResult {
        guard let id = noteID(args) else {
            throw ToolFailure(
                message: "mode 'update' needs 'id' and 'text': the note to rewrite and its new "
                    + "wording. Nothing was changed."
            )
        }
        let text = try body(args, for: .update)
        let rows = notes()
        guard let existing = rows.first(where: { $0.id == id }) else {
            throw ToolFailure(message: missingNote(id, among: rows))
        }
        let scope = try scope(args, default: existing.scope)

        if existing.text == text, existing.scope == scope {
            return .ok("Note \(id) already reads exactly that; nothing was changed.")
        }
        // A rewrite that collides with another note would leave two notes saying
        // one thing — the state `remember` refuses to create, so `update` must
        // not create it either.
        if let clash = knownNote(text, among: rows.filter { $0.id != id }) {
            throw ToolFailure(
                message: "Note \(clash.id) already says that — \"\(summarise(clash.text))\". "
                    + "Rewrite that one instead, or forget it first. Nothing was changed."
            )
        }

        dropCognitiveCopies(of: existing.text, lessonID: id)
        guard BudStore.rewrite(id: id, text: text, scope: scope) else {
            // The copy was dropped before the write, so a failed write must put
            // the note's memory back: a note that still reads as it did, with
            // nothing filed beside it, would be silently less retrievable.
            fileCognitiveCopy(text: existing.text, scope: existing.scope, lessonID: id)
            throw ToolFailure(message: "Bud could not rewrite note \(id); it is unchanged.")
        }
        fileCognitiveCopy(text: text, scope: scope, lessonID: id)

        let refiled = scope == existing.scope
            ? ""
            : " Re-filed from \(existing.scope) to \(scope)."
        return .ok(
            "Note \(id) now reads \"\(summarise(text))\" (was \"\(summarise(existing.text))\")."
                + refiled + " Its id is unchanged, so anything that referred to it still does."
        )
    }

    // MARK: - forget

    private func forget(_ args: JSONValue) throws -> ToolResult {
        guard let id = noteID(args) else {
            throw ToolFailure(
                message: "mode 'forget' needs 'id': the note to drop, exactly as search or list "
                    + "returned it. Nothing was forgotten."
            )
        }
        let rows = notes()
        guard let existing = rows.first(where: { $0.id == id }) else {
            throw ToolFailure(message: missingNote(id, among: rows))
        }

        // The note, the copies filed beside it, and any copy of the same
        // sentence that nothing owns: all of it goes, or retrieval keeps
        // surfacing what the model was told to forget. `BudStore.forget` is the
        // one place that policy lives — the same call the Memory pane makes —
        // rather than being re-implemented here where it could drift from it.
        BudStore.forget(id: id)

        let remaining = rows.count - 1
        return .ok(
            "Forgotten: note \(id) \"\(summarise(existing.text))\" [\(existing.scope)], "
                + "kept since \(Self.shortDate(existing.createdAt)). Its episode and its fact went with "
                + "it. \(remaining) note(s) remain. This cannot be undone, so do not say it was "
                + "merely hidden."
        )
    }

    /// No note under that id: say so, and say where ids come from, rather than
    /// guessing at the nearest match. A memory removed by approximation is worse
    /// than one more round trip.
    private func missingNote(_ id: Int, among rows: [Lesson]) -> String {
        let newest = rows.prefix(3).map { "\($0.id) (\(summarise($0.text)))" }.joined(separator: ", ")
        let hint = rows.isEmpty
            ? "You have no saved notes."
            : "The newest are: \(newest)."
        return "There is no note \(id). \(hint) Mode 'list' shows every id; 'search' finds one "
            + "by wording. Nothing was changed."
    }

    // MARK: - Shared argument handling

    /// The note text a write mode needs, trimmed and refused when empty.
    private func body(_ args: JSONValue, for mode: Mode) throws -> String {
        guard let raw = args["text"]?.stringValue else {
            throw ToolFailure(
                message: "mode '\(mode.rawValue)' needs 'text': the note itself. Nothing was done."
            )
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ToolFailure(
                message: "mode '\(mode.rawValue)' was given an empty 'text'. Nothing was done."
            )
        }
        return text
    }

    /// The scope the model asked for, defaulted and validated rather than passed
    /// through, so a typo cannot file a note under a scope nothing ever reads.
    private func scope(_ args: JSONValue, default fallback: String) throws -> String {
        guard let raw = args["scope"]?.stringValue else { return fallback }
        let scope = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.scopes.contains(scope) else {
            throw ToolFailure(
                message: "scope must be one of \(Self.scopes.joined(separator: ", ")); got '\(raw)'. "
                    + "Nothing was done."
            )
        }
        return scope
    }

    private func optionalScope(_ args: JSONValue) throws -> String? {
        guard args["scope"] != nil, args["scope"]?.stringValue != nil else { return nil }
        return try scope(args, default: Self.defaultScope)
    }

    private func noteID(_ args: JSONValue) -> Int? {
        guard let raw = args["id"]?.doubleValue, raw.isFinite else { return nil }
        return Int(raw)
    }

    private func notes() -> [Lesson] { BudStore.lessons(limit: Int.max) }

    private func scopeFiltered(_ rows: [Lesson], by scope: String?) -> [Lesson] {
        guard let scope else { return rows }
        return rows.filter { $0.scope == scope }
    }

    /// Standing instructions matching a query, by the same prefix rule the notes
    /// use — they are short, and the model is usually quoting a word from one.
    private func matchingDirectives(_ query: String, limit: Int) -> [Directive] {
        let terms = TextRanking.tokens(in: query)
        guard !terms.isEmpty else { return [] }
        return CognitiveStore.directives()
            .filter { directive in
                let words = Set(TextRanking.tokens(in: directive.text))
                return terms.contains { term in
                    words.contains { word in
                        word == term
                            || (word.count >= 4 && term.count >= 4
                                && (word.hasPrefix(term) || term.hasPrefix(word)))
                    }
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    /// A note quoted back to the model without letting a long one crowd out the
    /// result it needs to read.
    private func summarise(_ text: String) -> String {
        text.count <= 200 ? text : String(text.prefix(200)) + "…"
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

/// The model's only guidance on when this is worth calling. The description
/// names the situations that justify a call and the ones that do not, because a
/// memory tool described vaguely is either called on every turn or never called
/// at all — and it says which mode is which, since that is now the one thing
/// standing between the model and five behaviours.
extension MemoryToolsProvider {
    static let toolDescription = """
    Your own notes: keep them, find them, correct them, drop them.

    'remember' saves what would change how you help next time — how they like to be \
    answered, what they are working on, what they already know, and what they have \
    turned down and why — noticed on your own initiative and kept without saying so. \
    Not trivia, and nothing that only matters now: the task in hand, a file you are \
    editing, this turn's output, or anything you could read again from the code or \
    the transcript. A fact already in your notes, even rephrased, comes back as \
    already known rather than being saved twice.

    'search' finds a note by wording and returns the ids the other modes take; \
    'list' reads them back newest first. The notes that bear on what you are doing \
    are already in front of you on every request — reach for these for the rest, or \
    for exact wording, before asking the user to repeat something they have told you.

    'update' rewrites a note in place, keeping its id, and 'forget' drops it. Use \
    them when you are the reason the note is wrong: you have learned better since, \
    or the person has changed their mind. Both take an id from a search or a list — \
    there is no way to name a note by its wording, because a memory removed by \
    approximation is worse than one more call. Standing instructions are the \
    person's own: search reports them, and changing them happens in Memory settings.
    """
}
