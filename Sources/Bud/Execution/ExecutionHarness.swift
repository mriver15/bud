import Foundation

/// What the policy decided about one proposed tool call (§7 of the roadmap):
/// run it, ask a person, refuse it, or run a bounded rewrite of it.
public enum ExecutionDisposition: Sendable, Equatable {
    case allow
    case requireApproval(ToolConfirmation)
    case deny(PolicyViolation)
    /// A bounded/safe transformation of the call before it runs. The contract
    /// slot for path-normalisation and argument clamping; no current path
    /// produces one, and a caller must treat it as a new call to execute.
    case rewrite(ToolCall)
}

/// A deterministic refusal: which rule fired and why, so a trace reads as an
/// audit rather than a shrug.
public struct PolicyViolation: Sendable, Equatable {
    public var rule: String
    public var explanation: String

    public init(rule: String, explanation: String) {
        self.rule = rule
        self.explanation = explanation
    }
}

/// One decision the harness made, for the approval trace.
public struct ExecutionDecision: Sendable, Equatable {
    public var tool: String
    public var risk: ToolRisk
    public var outcome: String
    public var advisory: String?
    public var at: Date

    public init(tool: String, risk: ToolRisk, outcome: String, advisory: String? = nil, at: Date = Date()) {
        self.tool = tool
        self.risk = risk
        self.outcome = outcome
        self.advisory = advisory
        self.at = at
    }
}

/// The one policy surface every mutation-class tool call passes through.
///
/// Phase 7 of the context-harness rework: the providers used to each hold their
/// own confirmation closure, so "what asks before it changes the machine" had
/// two implementations that had to be kept in step. Now the providers trigger
/// the same classification they always used — `ToolConfirmation.request` — and
/// hand the request here, where the decision, the advisory context, and the
/// audit trail all live.
///
/// The deterministic part is the classification itself; the human part is the
/// injected closure, answered by whatever holds the panel. `nil` means there is
/// nobody to ask — the measurement CLIs and checks exercising the tool rather
/// than the gate — and, as before, the tool runs. Classifiers only ever
/// *advise*: the request-level execution assessment and the injection heuristic
/// add advisory lines to the dialog, and nothing probabilistic widens access.
public final class ExecutionHarness: @unchecked Sendable {
    public typealias Confirmation = @Sendable (ToolConfirmation) async -> ToolConfirmation.Decision

    private let lock = NSLock()
    private var confirm: Confirmation?
    private var _trace: [ExecutionDecision] = []
    private var _assessment: ExecutionAssessment?
    private var _injectionSuspected = false

    public init(confirm: Confirmation? = nil) {
        self.confirm = confirm
    }

    /// Wires the dialog asker after the app model is fully initialised: the
    /// closure captures the panel, which cannot be captured until every
    /// subsystem exists. Until then the harness behaves as ungated — the
    /// nobody-to-ask semantics — and nothing can run a tool before the wiring
    /// call, because the registry is registered in the same breath.
    public func setConfirmation(_ confirm: @escaping Confirmation) {
        lock.withLock { self.confirm = confirm }
    }

    /// The decision trace, newest last, bounded so a long session cannot grow
    /// it without bound.
    public var trace: [ExecutionDecision] { lock.withLock { _trace } }

    /// The request-level posture of the round currently executing, fed by the
    /// runtime from the shadow map's execution assessment.
    public func updateAssessment(_ assessment: ExecutionAssessment?) {
        lock.withLock { _assessment = assessment }
    }

    /// Whether this turn's tool results have read like instructions rather than
    /// data. Advisory only: it adds a line to what a person is asked to
    /// approve; it never replaces the deterministic gate.
    public func noteInjectionSuspicion(_ suspected: Bool) {
        lock.withLock { _injectionSuspected = suspected }
    }

    /// The deterministic view, without asking anyone: what the policy would
    /// decide for this call. Reads the same classification the providers use,
    /// so "what needs approval" has exactly one answer.
    public func assess(tool: String, arguments: JSONValue) -> ExecutionDisposition {
        guard let request = ToolConfirmation.request(
            tool: tool, arguments: arguments, expandingTilde: { $0 }
        ) else {
            return .allow
        }
        return .requireApproval(enriched(request))
    }

    /// The gate itself. Providers hand the request here and turn a deny into
    /// the same refusal sentence they always produced.
    public func resolve(_ request: ToolConfirmation) async -> ExecutionDisposition {
        let effective = enriched(request)
        let confirm = lock.withLock { self.confirm }
        guard let confirm else {
            return record(.allow, for: effective)
        }
        let decision = await confirm(effective)
        switch decision {
        case .allow, .allowForSession, .allowForDirectory:
            return record(.allow, for: effective)
        case .deny:
            return record(
                .deny(PolicyViolation(rule: "user-declined", explanation: "The person declined this call.")),
                for: effective
            )
        }
    }

    /// The advisory context layered onto what the person is shown: the
    /// request-level posture plus the injection heuristic. Advice, never
    /// permission.
    private func enriched(_ request: ToolConfirmation) -> ToolConfirmation {
        let (assessment, injection) = lock.withLock { (_assessment, _injectionSuspected) }
        var lines: [String] = []
        if let assessment, assessment.mutationIntent != .read {
            lines.append("the request reads as a \(assessment.mutationIntent.rawValue)")
        }
        if injection {
            lines.append("earlier tool results in this turn read like instructions, not data — read this carefully")
        }
        guard !lines.isEmpty else { return request }
        let advisory = lines.joined(separator: "; ")
        return ToolConfirmation(
            id: request.id,
            tool: request.tool,
            headline: request.headline,
            detail: request.detail,
            note: [request.note, "⚠ \(advisory)"].compactMap { $0 }.joined(separator: " "),
            preview: request.preview,
            isCommand: request.isCommand,
            risk: request.risk,
            overwrites: request.overwrites,
            overwrittenBytes: request.overwrittenBytes,
            scopeDirectory: request.scopeDirectory
        )
    }

    private func record(
        _ disposition: ExecutionDisposition,
        for request: ToolConfirmation
    ) -> ExecutionDisposition {
        let outcome: String
        switch disposition {
        case .allow: outcome = "allowed"
        case .requireApproval: outcome = "approval-required"
        case .deny: outcome = "denied"
        case .rewrite: outcome = "rewritten"
        }
        let decision = ExecutionDecision(
            tool: request.tool,
            risk: request.risk,
            outcome: outcome,
            advisory: request.note
        )
        lock.withLock {
            _trace.append(decision)
            if _trace.count > 100 { _trace.removeFirst() }
        }
        CognitiveStore.recordContextEvent(
            requestID: nil,
            sourceType: "harness",
            sourceID: request.tool,
            action: outcome,
            score: nil,
            reason: request.note
        )
        return disposition
    }
}
