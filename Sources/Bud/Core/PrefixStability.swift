import CryptoKit
import Foundation

// MARK: - Prefix stability

/// How much of the request prefix survives when the query changes.
///
/// Providers cache the front of the prompt, so the part that stays put between
/// two questions is the part that is not paid for twice. This measures that: it
/// builds the request prefix for two queries from the same public composition
/// pieces the runtime uses — the system prompt, the live-context lines, the
/// remembered notes, the skill catalogue, and the planned/compacted tool block —
/// then reports, block by block, how many characters are stable and how many
/// changed.
///
/// Descriptive, not prescriptive: none of these figures are tuned to one
/// provider's cache semantics. They say what the two prefixes have in common and
/// leave the reader to decide what that is worth.
public struct PrefixStability: Sendable {
    /// One block of the prefix, compared between two queries.
    public struct Block: Sendable {
        public let name: String
        /// Characters in query A's rendering of the block.
        public let aChars: Int
        /// Characters in query B's rendering of the block.
        public let bChars: Int
        /// Characters identical at the front of both renderings — the cacheable
        /// part. A block that shares nothing reports zero.
        public let stableChars: Int
        /// Characters past the shared front, measured against the longer of the
        /// two renderings. Zero when the block is unchanged.
        public let changedChars: Int
        /// The stable share of the longer rendering: `stableChars` over the
        /// longer of `aChars` and `bChars`. An unchanged block reports 1; an
        /// empty one reports 0.
        public let share: Double
    }

    public let blocks: [Block]
    /// The total prefix length, summing each block at its longer rendering.
    public let totalChars: Int
    /// The stable characters across every block.
    public let stableChars: Int
    /// `stableChars` over `totalChars` — the fraction of the prefix that
    /// survives between the two queries.
    public let stableShare: Double
    /// SHA-256 of query A's whole prefix.
    public let hashA: String
    /// SHA-256 of query B's whole prefix.
    public let hashB: String

    /// Builds and compares the request prefix for two queries.
    ///
    /// - Parameters:
    ///   - tools: the offered descriptors, already filtered to what the main
    ///     agent sees (`!$0.agentOnly`), exactly as the runtime filters them.
    ///
    /// Passing the same query twice is the sanity path: every block shares its
    /// whole front, so `changedChars` is zero everywhere and the stable share
    /// is 1.
    public static func measure(
        queryA: String,
        queryB: String,
        config: BudConfig,
        tools: [ToolDescriptor]
    ) -> PrefixStability {
        let a = prefix(for: queryA, config: config, tools: tools)
        let b = prefix(for: queryB, config: config, tools: tools)

        var blocks: [Block] = []
        blocks.reserveCapacity(a.count)
        var total = 0
        var stable = 0
        for (blockA, blockB) in zip(a, b) {
            let shared = blockA.text.commonPrefix(with: blockB.text).count
            let longer = max(blockA.text.count, blockB.text.count)
            let changed = longer - shared
            let share = longer == 0 ? 0 : Double(shared) / Double(longer)
            blocks.append(Block(
                name: blockA.name,
                aChars: blockA.text.count,
                bChars: blockB.text.count,
                stableChars: shared,
                changedChars: changed,
                share: share
            ))
            total += longer
            stable += shared
        }

        let hashA = sha256Hex(a.map(\.text).joined(separator: "\n\n"))
        let hashB = sha256Hex(b.map(\.text).joined(separator: "\n\n"))
        return PrefixStability(
            blocks: blocks,
            totalChars: total,
            stableChars: stable,
            stableShare: total == 0 ? 0 : Double(stable) / Double(total),
            hashA: hashA,
            hashB: hashB
        )
    }

    // MARK: - Composition

    /// One query's prefix, block by block, in the order the report presents them.
    private struct NamedText {
        let name: String
        let text: String
    }

    private static func prefix(
        for query: String,
        config: BudConfig,
        tools: [ToolDescriptor]
    ) -> [NamedText] {
        var blocks: [NamedText] = []
        blocks.reserveCapacity(5)

        // The system prompt, verbatim: the part a provider caches most eagerly.
        blocks.append(NamedText(name: "system prompt", text: config.systemPrompt))

        // The trailing lines the runtime appends every request — model, reasoning
        // effort, and the clock. A fixed reading rather than the live one, so the
        // hashes are reproducible instead of one minute old on the next run.
        blocks.append(NamedText(name: "live context", text: liveContext(config: config)))

        // The remembered notes, ranked against the query exactly as the runtime
        // ranks them against the conversation tail. Empty when nothing is stored,
        // which is the offline/scratch case.
        let notes = BudStore.lessonContext(query)
        let fenced = notes.isEmpty ? "" : ToolProvenance.rememberedNotes(notes)
        blocks.append(NamedText(name: "memory notes", text: fenced))

        // The skill catalogue, ranked against the query.
        blocks.append(NamedText(
            name: "skill catalogue",
            text: SkillContext.catalogue(query: query).text
        ))

        // The tools the planner offers for the query, schema-compacted where the
        // config asks, plus the note naming what it held back. The one block that
        // moves with the query's intent — a browse request pulls in the browser
        // group, a generic one does not.
        blocks.append(NamedText(name: "tool block", text: toolBlock(for: query, config: config, tools: tools)))

        return blocks
    }

    /// The live-context lines, with a fixed clock so the hashes are stable across
    /// runs. Mirrors `RequestMeasureCLI.liveContextSample`.
    private static func liveContext(config: BudConfig) -> String {
        var text = "\n\nCurrent time: Wednesday, 1 January 2025, 00:00."
        text += "\nDefault model for this session: \(config.model)."
        if let effort = config.reasoningEffort { text += " Reasoning effort: \(effort)." }
        return text
    }

    /// The tool block for one query: the planned descriptors, compacted when the
    /// config asks, serialised as the request carries them, plus the planner's
    /// note about what it held back.
    private static func toolBlock(
        for query: String,
        config: BudConfig,
        tools: [ToolDescriptor]
    ) -> String {
        var context = ToolPlanningContext()
        context.query = query
        let plan = ToolPlanner.plan(context: context, descriptors: tools)

        var planned = plan.descriptors
        if config.compactSchemas {
            planned = planned.map { DescriptorCompactor.compact($0) }
        }

        var text = JSONValue.array(planned.map(\.openAIToolDefinition)).encodedString()
        if let note = ToolPlanner.omittedNote(plan.omitted), !note.isEmpty {
            text += "\n\n" + note
        }
        return text
    }

    /// SHA-256 as lowercase hex, the same construction the update path uses.
    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
