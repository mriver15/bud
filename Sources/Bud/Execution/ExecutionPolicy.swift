import Foundation

/// The deterministic side of the execution policy: heuristics that are
/// advisory by contract (§7 — "classifiers advise; policy enforces").
///
/// Nothing here widens access and nothing here blocks on its own. The injection
/// heuristic flags text that reads like it is instructing a model rather than
/// reporting facts, and the harness turns that flag into an extra line on the
/// approval dialog — the deterministic gate still decides.
public enum ExecutionPolicy {
    /// Whether tool-result text reads like instructions aimed at a model. A
    /// deliberately crude marker list: a false positive costs one extra line on
    /// a dialog, a false negative costs the person reading it their one chance
    /// to notice.
    public static func looksLikeInstructions(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "ignore previous instructions",
            "ignore all previous",
            "you must ignore",
            "you must not",
            "you must run",
            "you must execute",
            "you must output",
            "you must respond",
            "you are now",
            "do not tell the user",
            "disregard",
            "important: do",
            "as an ai",
        ]
        return markers.contains { lowered.contains($0) }
    }
}
