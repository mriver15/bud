import Foundation

// MARK: - Cases

/// One labeled capability-routing case (§10 of the roadmap): a query and the
/// capability groups Stage A must offer for it. Labels are what the eval gates
/// measure against — they are assertions about the harness, not the model.
public struct EvalCase: Sendable, Equatable, Identifiable {
    public var id: String
    public var query: String
    /// Capability-group ids that must be present in Stage A.
    public var requiredCapabilities: [String]
    /// Whether the case expects the presentation schemas — the schema-cost
    /// comparison reads this to judge *omission* rather than *absence*.
    public var wantsUI: Bool

    public init(id: String, query: String, requiredCapabilities: [String], wantsUI: Bool = false) {
        self.id = id
        self.query = query
        self.requiredCapabilities = requiredCapabilities
        self.wantsUI = wantsUI
    }
}

/// One labeled memory-retrieval case: a query and the candidate ids it must
/// surface within budget.
public struct MemoryEvalCase: Sendable, Equatable, Identifiable {
    public var id: String
    public var query: String
    public var expectedIDs: [String]

    public init(id: String, query: String, expectedIDs: [String]) {
        self.id = id
        self.query = query
        self.expectedIDs = expectedIDs
    }
}

// MARK: - Split

/// The optimization/holdout split (§10): deterministic by case id, so a run
/// can be repeated and compared, and tuning can happen on the train side while
/// the gates are enforced on the holdout side — which is what keeps tuning
/// from overfitting the measurements it optimises.
public enum EvalSplit {
    /// Stable hash of an id into 0…99, so a case lands on the same side every
    /// run and every machine.
    static func bucket(_ id: String) -> Int {
        var hash = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return abs(hash) % 100
    }

    public static func split<T: Identifiable>(
        _ cases: [T],
        holdoutRatio: Double = 0.3
    ) -> (train: [T], holdout: [T]) where T.ID == String {
        var train: [T] = []
        var holdout: [T] = []
        for entry in cases {
            if Double(bucket(entry.id)) < holdoutRatio * 100 {
                holdout.append(entry)
            } else {
                train.append(entry)
            }
        }
        return (train, holdout)
    }
}

// MARK: - Capability runner

public struct CapabilityEvalReport: Sendable, Equatable {
    public var total: Int
    public var recalled: Int
    public var failures: [String]
    public var plannerSchemaChars: Int
    public var resolverSchemaChars: Int

    public var recallRate: Double { total > 0 ? Double(recalled) / Double(total) : 1 }

    public func summary() -> String {
        let plannerWin = plannerSchemaChars - resolverSchemaChars
        return "recall \(String(format: "%.0f%%", recallRate * 100)) "
            + "(\(recalled)/\(total)); resolver pays \(plannerWin >= 0 ? "less" : "more") "
            + "by \(abs(plannerWin)) schema chars than the planner across the set"
    }
}

/// Runs the labeled capability corpus through both the current planner and the
/// adaptive resolver, and reports recall plus the schema-cost comparison. The
/// exit criterion of the whole rework in one number: required capabilities
/// still activate, and the harness pays less for them.
public enum CapabilityEvalRunner {
    public static func run(
        cases: [EvalCase],
        descriptors: [ToolDescriptor],
        engine: DecisionEngine = DeterministicDecisionEngine(),
        bands: DecisionBands = .default
    ) async -> CapabilityEvalReport {
        let domains = Set(descriptors.map(\.providerName)).sorted() + ["none"]
        var recalled = 0
        var failures: [String] = []
        var plannerChars = 0
        var resolverChars = 0

        for entry in cases {
            let state = DecisionState(query: entry.query)
            let context = ToolPlanningContext(query: entry.query)

            let plannerPlan = ToolPlanner.plan(context: context, descriptors: descriptors)
            plannerChars += plannerPlan.descriptors.reduce(0) {
                $0 + $1.name.count + $1.description.count + $1.schema.stringContentLength
            }

            let batch = (try? await engine.evaluate(
                state: state, questions: DecisionQuestions.initial(domains: domains)
            )) ?? DecisionBatch(engineID: engine.id, answers: [])
            let stage = CapabilityResolver.stageA(
                state: state, batch: batch, descriptors: descriptors, stickyTools: [], bands: bands
            )
            resolverChars += stage.schemaCharacters

            let offered = Set(stage.plan.descriptors.map(\.providerName))
            let missing = entry.requiredCapabilities.filter { !offered.contains($0) }
            if missing.isEmpty {
                recalled += 1
            } else {
                failures.append("'\(entry.id)' missed \(missing.joined(separator: ", "))")
            }
        }

        return CapabilityEvalReport(
            total: cases.count,
            recalled: recalled,
            failures: failures,
            plannerSchemaChars: plannerChars,
            resolverSchemaChars: resolverChars
        )
    }
}

// MARK: - Memory runner

public struct MemoryEvalReport: Sendable, Equatable {
    public var total: Int
    public var recalled: Int
    public var failures: [String]

    public var recallRate: Double { total > 0 ? Double(recalled) / Double(total) : 1 }

    public func summary() -> String {
        "recall \(String(format: "%.0f%%", recallRate * 100)) (\(recalled)/\(total))"
    }
}

/// Runs the labeled retrieval corpus against the live cognitive store. The
/// caller seeds the store first — the runner only reads, so the same corpus
/// measures whatever memory state a real session has reached.
public enum MemoryEvalRunner {
    public static func run(
        cases: [MemoryEvalCase],
        budget: Int = 10_000,
        maxCandidates: Int = 12
    ) -> MemoryEvalReport {
        var recalled = 0
        var failures: [String] = []
        for entry in cases {
            let candidates = MemoryRetriever.retrieve(
                query: entry.query, budget: budget, maxCandidates: maxCandidates
            )
            let ids = Set(candidates.map(\.id))
            let missing = entry.expectedIDs.filter { !ids.contains($0) }
            if missing.isEmpty {
                recalled += 1
            } else {
                failures.append("'\(entry.id)' missed \(missing.joined(separator: ", "))")
            }
        }
        return MemoryEvalReport(total: cases.count, recalled: recalled, failures: failures)
    }
}

// MARK: - Gates

/// The §10 gates, as code rather than prose. The recall gate is enforced on
/// the holdout split; the fail-open gate is measured on live turns (the
/// planner-regret report) rather than simulated here.
public enum EvalGates {
    public static let capabilityRecallGate = 0.98
    public static let failOpenGate = 0.05

    public static func capabilityRecallPasses(_ report: CapabilityEvalReport) -> Bool {
        report.recallRate >= capabilityRecallGate
    }

    public static func memoryRecallPasses(_ report: MemoryEvalReport) -> Bool {
        report.recallRate >= capabilityRecallGate
    }
}
