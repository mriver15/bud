import Foundation

// MARK: - Inputs

/// Everything one compilation needs, as a value.
///
/// Retrieval is deliberately absent from the compiler: the ranked notes and the
/// skill catalogue are read *before* compilation by the caller and handed over
/// here, so the compiler stays a pure transformation over typed inputs — the
/// roadmap's "retrieval helpers may run before compilation" rule, with the
/// results entering the map through the report below.
public struct CompilationInputs: Sendable {
    public var systemPrompt: String
    public var model: String
    public var reasoningEffort: String?
    public var historyBudgetChars: Int
    public var history: [ChatMessage]
    public var tools: [ToolDescriptor]
    public var notes: String
    public var skillCatalogue: String
    public var promotedSkills: [String]
    /// The decision-gated memory section (Phase 6), pre-rendered by the
    /// memory resolver. Empty keeps the pre-rework payload byte-identical.
    public var memorySection: String
    /// The tracked conversation state (paths, URLs, store handles), pre-rendered
    /// by ``ConversationState``. Empty keeps the payload unchanged.
    public var state: String
    /// Context the MCP apps pushed via `ui/update-model-context`, pre-rendered.
    /// Empty keeps the payload unchanged.
    public var appContext: String
    public var omittedNote: String?
    /// When the compiled request is stamped. Injected rather than read here so
    /// a fixture can pin the clock and the output is deterministic.
    public var now: Date

    public init(
        systemPrompt: String,
        model: String,
        reasoningEffort: String?,
        historyBudgetChars: Int,
        history: [ChatMessage],
        tools: [ToolDescriptor],
        notes: String,
        skillCatalogue: String,
        promotedSkills: [String],
        memorySection: String = "",
        state: String = "",
        appContext: String = "",
        omittedNote: String?,
        now: Date
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.historyBudgetChars = historyBudgetChars
        self.history = history
        self.tools = tools
        self.notes = notes
        self.skillCatalogue = skillCatalogue
        self.promotedSkills = promotedSkills
        self.memorySection = memorySection
        self.state = state
        self.appContext = appContext
        self.omittedNote = omittedNote
        self.now = now
    }
}

// MARK: - Outputs

/// What the compiler built: the three pieces a provider request is assembled
/// from, plus the report that says how each was chosen and what it weighed.
public struct CompiledContext: Sendable, Equatable {
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolDescriptor]
    public var metadata: CompilationReport

    public init(
        system: String,
        messages: [ChatMessage],
        tools: [ToolDescriptor],
        metadata: CompilationReport
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.metadata = metadata
    }
}

/// The audit side of a compilation: what went in, what was dropped, and what it
/// cost. Feeds the shadow ContextMap's budget and memory/skill candidates, so a
/// round's map and its payload can never disagree about what the payload
/// actually carried.
public struct CompilationReport: Sendable, Equatable {
    public var ledger: ContextLedger
    public var notesCharacters: Int
    public var promotedSkills: [String]
    public var droppedHistoryCharacters: Int
    public var offeredToolCount: Int

    public init(
        ledger: ContextLedger,
        notesCharacters: Int,
        promotedSkills: [String],
        droppedHistoryCharacters: Int,
        offeredToolCount: Int
    ) {
        self.ledger = ledger
        self.notesCharacters = notesCharacters
        self.promotedSkills = promotedSkills
        self.droppedHistoryCharacters = droppedHistoryCharacters
        self.offeredToolCount = offeredToolCount
    }
}

// MARK: - The compiler

/// Assembles a provider-neutral request payload from typed inputs.
///
/// Phase 2 of the context-harness rework is the extraction: this protocol and
/// its one implementation reproduce the exact semantics the request path had
/// before — same system text order, same history trimming, same tools — so the
/// provider payload is unchanged while the assembly now lives behind one seam.
/// Later phases (SchemaCompressor, BudgetAllocator, capability-driven system
/// text) change behaviour by evolving the implementation, not the callers.
public protocol ContextCompiling: Sendable {
    func compile(_ inputs: CompilationInputs) -> CompiledContext
}

public struct ContextCompiler: ContextCompiling {
    public init() {}

    public func compile(_ inputs: CompilationInputs) -> CompiledContext {
        // The stable prefix: policy prompt, session model, reasoning effort.
        // Byte-stable so providers can keep caching it.
        var text = inputs.systemPrompt
        text += "\nDefault model for this session: \(inputs.model)."
        if let effort = inputs.reasoningEffort { text += " Reasoning effort: \(effort)." }

        // Ranked context, in the order the pre-extraction path appended it:
        // memory notes (fenced, they are data), then the skill catalogue, then
        // what the planner held back this round.
        if !inputs.notes.isEmpty { text += "\n\n" + ToolProvenance.rememberedNotes(inputs.notes) }
        if !inputs.memorySection.isEmpty { text += "\n\n" + inputs.memorySection }
        if !inputs.state.isEmpty { text += "\n\n" + inputs.state }
        if !inputs.appContext.isEmpty {
            text += "\n\n" + ToolProvenance.appDataPrefix + "\n" + inputs.appContext
        }
        if !inputs.skillCatalogue.isEmpty { text += "\n\n" + inputs.skillCatalogue }
        if let omitted = inputs.omittedNote, !omitted.isEmpty {
            text += "\n\n" + omitted
        }

        // The one line that changes every minute rides last. Providers cache the
        // front of the prompt, so keeping the volatile clock at the end means a
        // new timestamp invalidates only the tail instead of the whole stable
        // prefix above it.
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        text += "\n\nCurrent time: \(stamp.string(from: inputs.now))."

        let distilled = Self.distillConsumed(inputs.history)
        let bounded = Self.bounded(distilled.messages, budget: inputs.historyBudgetChars)

        let toolChars = inputs.tools.reduce(0) {
            $0 + $1.name.count + $1.description.count + $1.schema.stringContentLength
        }
        let historyChars = bounded.messages.reduce(0) { $0 + $1.content.count }
        let ledger = ContextLedger(
            systemCharacters: text.count,
            historyCharacters: historyChars,
            toolSchemaCharacters: toolChars,
            memoryCharacters: inputs.notes.count,
            skillsCharacters: inputs.skillCatalogue.count,
            totalCharacters: text.count + historyChars + toolChars
                + inputs.notes.count + inputs.skillCatalogue.count
        )

        return CompiledContext(
            system: text,
            messages: bounded.messages,
            tools: inputs.tools,
            metadata: CompilationReport(
                ledger: ledger,
                notesCharacters: inputs.notes.count,
                promotedSkills: inputs.promotedSkills,
                droppedHistoryCharacters: distilled.dropped + bounded.dropped,
                offeredToolCount: inputs.tools.count
            )
        )
    }

    // MARK: - History bounding

    /// The conversation as the model receives it, trimmed to the budget.
    ///
    /// History grew without limit. A result is capped at 24,000 characters when
    /// it arrives and nothing capped the total, so every round re-sent every
    /// result the conversation had ever produced — and the conversation that
    /// most needs a long one is the one that called the most tools.
    ///
    /// Only tool *results* are emptied, and only their contents. The call and
    /// its result have to stay paired or the provider rejects the whole request,
    /// so a dropped result becomes a line saying it was dropped rather than a
    /// missing message. Oldest first, and never the newest: the newest result is
    /// the one the model has not read yet.
    ///
    /// This bounds what the *model* carries, not what happened. The transcript
    /// keeps the full text, and the model is told how to recover — call the tool
    /// again, or `read_stored` when the result had already spilled to the store —
    /// which is true, and is all the recovery it needs.
    static func bounded(
        _ messages: [ChatMessage],
        budget: Int
    ) -> (messages: [ChatMessage], dropped: Int) {
        guard budget > 0, !messages.isEmpty else { return (messages, 0) }

        var total = messages.reduce(0) { $0 + $1.content.count }
        guard total > budget else { return (messages, 0) }

        var bounded = messages
        var dropped = 0
        for index in bounded.indices {
            guard total > budget, index < bounded.count - 1 else { break }
            guard bounded[index].role == .tool else { continue }
            let content = bounded[index].content
            // Not worth emptying something the marker would be nearly as long as.
            guard content.count > dropThreshold else { continue }
            let marker = droppedMarker(for: content)
            guard marker.count < content.count else { continue }
            total -= content.count - marker.count
            dropped += content.count
            bounded[index].content = marker
        }
        return (bounded, dropped)
    }

    /// Below this a result is cheaper to send than to explain away. The marker
    /// is now under ~90 characters, so this sits a few times above it: a result
    /// has to be comfortably larger than its replacement before the rewrite is
    /// worth the churn.
    private static let dropThreshold = 200

    private static func droppedMarker(for content: String) -> String {
        if let handle = storedHandle(in: content) {
            // A spilled result keeps its handle: the data is still on disk, and
            // `read_stored` is how the model gets back to it.
            return "[dropped to fit the budget; still stored as \(handle) — read_stored to retrieve.]"
        }
        return "[dropped \(BudFormat.count(content.count)) characters; call the tool again to see it.]"
    }

    /// The `store_` handle a spilled result carries, when its data is still
    /// there.
    ///
    /// The spill marker sits at the end of the content, so the *last* handle in
    /// the text is the one for this result; any earlier one is part of the
    /// result's own text. A handle is only kept when the file still exists — a
    /// token that merely looks like a handle points nowhere.
    private static func storedHandle(in content: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"store_[0-9a-fA-F]{8}"#) else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = expression.matches(in: content, range: range).last,
              let tokenRange = Range(match.range, in: content) else { return nil }
        let token = String(content[tokenRange]).lowercased()
        return FileManager.default.fileExists(atPath: StoredResults.url(for: token).path) ? token : nil
    }

    // MARK: - Consumed-result distillation

    /// Tool results from turns the model has already answered are replaced with a
    /// compact marker, so a later request carries the durable values (in the
    /// conversation-state block) instead of re-reading every result it moved past.
    ///
    /// The cut is the most recent user message: everything the current question
    /// produced is still active work and stays verbatim, while a result an
    /// earlier turn already read and answered is only recoverable, not required,
    /// on the next request. The call/result pairing is untouched — only the
    /// content is replaced — and the transcript keeps the full text; only the
    /// model is bounded.
    static func distillConsumed(
        _ messages: [ChatMessage]
    ) -> (messages: [ChatMessage], dropped: Int) {
        guard let lastUser = messages.lastIndex(where: {
            $0.role == .user && !$0.content.hasPrefix(HistoryCompactor.summaryPrefix)
        }) else { return (messages, 0) }

        var out = messages
        var dropped = 0
        for index in out.indices where index < lastUser && out[index].role == .tool {
            let content = out[index].content
            guard content.count > dropThreshold else { continue }
            let marker = consumedMarker(for: content)
            guard marker.count < content.count else { continue }
            dropped += content.count
            out[index].content = marker
        }
        return (out, dropped)
    }

    /// The marker a consumed result leaves behind. Kept honest about how to get
    /// the text back: a spilled result keeps its handle, anything else is a call
    /// away.
    private static func consumedMarker(for content: String) -> String {
        if let handle = storedHandle(in: content) {
            return "[Earlier result, stored as \(handle) — read_stored to retrieve.]"
        }
        return "[Earlier result, no longer carried — re-run the tool to see it again.]"
    }

    // MARK: - Memory ranking input

    /// The tail of the conversation, for ranking what is worth remembering.
    ///
    /// The subject of a conversation is mostly in its tail: what was said a
    /// dozen turns ago is a weaker guess at what a note would be used for than
    /// what was said in the last exchange. Tool results are skipped — they are
    /// the largest thing in the history and the least like something a note is
    /// about — and every message is capped, because this is a query to rank
    /// against rather than context to send.
    static func conversationTail(
        of history: [ChatMessage],
        messages: Int = 6,
        perMessage: Int = 1_500
    ) -> String {
        var tail: [String] = []
        for message in history.reversed() where message.role == .user || message.role == .assistant {
            tail.append(String(message.content.prefix(perMessage)))
            if tail.count == messages { break }
        }
        return tail.reversed().joined(separator: "\n")
    }
}
