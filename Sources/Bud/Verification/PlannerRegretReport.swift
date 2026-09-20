import Foundation

/// The planner-regret report (§9 of the roadmap): the named signals the
/// runtime files when the original plan was insufficient or wasteful, mined
/// back out of the evidence store for the tuning phase.
///
/// The report is the artifact — a regression dashboard can render these rows
/// later without re-aggregating anything.
public enum PlannerRegretReport {
    public struct Row: Sendable, Equatable {
        public var signal: String
        public var meaning: String
        public var count: Int
        public var examples: [String]

        public init(signal: String, meaning: String, count: Int, examples: [String]) {
            self.signal = signal
            self.meaning = meaning
            self.count = count
            self.examples = examples
        }
    }

    /// The §9 signal table, in the order a report lists them.
    static let signals: [(id: String, meaning: String)] = [
        ("unused_exposed_tool", "Schema was paid for but never used."),
        ("missed_capability", "A needed capability was omitted and required fail-open expansion."),
        ("alias_recovery", "The model reached for a conceptual or legacy tool name that had to be resolved."),
        ("memory_miss", "The model called recall mid-task for memory omitted from initial context."),
    ]

    public static func aggregate(events: [String]) -> [Row] {
        var rows: [Row] = []
        for signal in signals {
            let matching = events.filter { $0.hasPrefix(signal.id + ":") }
            guard !matching.isEmpty else { continue }
            rows.append(
                Row(
                    signal: signal.id,
                    meaning: signal.meaning,
                    count: matching.count,
                    examples: Array(matching.prefix(3))
                )
            )
        }
        return rows
    }

    /// Reads the regret evidence the current store holds and renders it.
    public static func render(events: [String]? = nil) -> String {
        let rows = aggregate(events: events ?? CognitiveStore.contextEvents(action: "regret"))
        guard !rows.isEmpty else {
            return "No planner-regret signals recorded yet — run turns and the "
                + "harness will file what the plan got wrong."
        }
        var out = "Planner regret — where the plan was insufficient or wasteful\n\n"
        for row in rows {
            out += "  \(row.signal) × \(row.count)\n"
            out += "    \(row.meaning)\n"
            for example in row.examples {
                let trimmed = example.count > 100 ? String(example.prefix(100)) + "…" : example
                out += "    — \(trimmed)\n"
            }
        }
        return out
    }
}
