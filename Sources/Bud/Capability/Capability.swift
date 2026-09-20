import Foundation

/// One named capability: what Bud can do, described in a line, activatable as a
/// tool group or a delegate.
///
/// A capability is not necessarily a tool (§3.4 of the roadmap): it may resolve
/// to a whole provider group promoted together, or to an agent the work is
/// handed to. The base index carries these one-line summaries instead of the
/// full roster, which is what removes inventory growth from the parent prompt.
public struct Capability: Sendable, Equatable, Identifiable {
    public enum Activation: Sendable, Equatable {
        /// Promote this provider's whole tool group.
        case toolGroup(String)
        /// Reachable only by delegating to this agent.
        case delegate(String)
    }

    public var id: String
    /// One line: what it does and when. The whole of what a discovery prompt
    /// shows before anything is expanded.
    public var summary: String
    /// Names the model may reach for instead of the id.
    public var aliases: [String]
    public var activation: Activation
    public var toolCount: Int

    public init(
        id: String,
        summary: String,
        aliases: [String],
        activation: Activation,
        toolCount: Int
    ) {
        self.id = id
        self.summary = summary
        self.aliases = aliases
        self.activation = activation
        self.toolCount = toolCount
    }

    public var isDelegate: Bool {
        if case .delegate = activation { return true }
        return false
    }
}

/// A lookup result: how well a query names a capability, and why.
public struct CapabilityMatch: Sendable, Equatable {
    public var capability: Capability
    /// 0…1, in the roadmap's activation bands: ≥0.85 activate, 0.55…0.85
    /// advertise, below 0.55 omit.
    public var confidence: Double
    public var reason: String

    public init(capability: Capability, confidence: Double, reason: String) {
        self.capability = capability
        self.confidence = confidence
        self.reason = reason
    }
}
