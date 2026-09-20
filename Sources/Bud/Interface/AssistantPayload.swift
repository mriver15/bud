import Foundation

/// A model's final answer as a provider-neutral payload (§6.3 of the roadmap):
/// prose, a surface, or both.
///
/// The output-dialect experiment's alternative to the `render_ui` tool: the
/// model speaks the interface into its answer instead of calling a tool to get
/// it drawn. Whether the dialect ships is an eval decision — token cost, UI
/// selection accuracy and repair rate versus the tool approach — and nothing
/// here changes how the tool works today.
public enum AssistantPayload: Sendable, Equatable {
    case markdown(String)
    case budUI(UISpec)
    case mixed(markdown: String, ui: UISpec)

    /// The surface, when the answer carries one.
    public var ui: UISpec? {
        switch self {
        case .budUI(let spec), .mixed(_, let spec): return spec
        case .markdown: return nil
        }
    }

    /// The prose, with any envelope removed. The whole answer when there is no
    /// surface.
    public var markdown: String {
        switch self {
        case .markdown(let text), .mixed(let text, _): return text
        case .budUI: return ""
        }
    }
}
