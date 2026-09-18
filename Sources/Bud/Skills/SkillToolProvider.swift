import Foundation

/// Skills, as the model sees them.
///
/// Progressive disclosure, as the standard describes it: the name and description
/// of every installed skill are listed in the prompt, and the instructions are
/// loaded only when the model decides one applies. A hundred skills cost a page
/// of prompt rather than a hundred pages of context, which is the whole reason
/// the format is shaped this way.
public final class SkillToolProvider: ToolProvider {
    public let providerID = "skills"
    public let providerName = "Skills"

    public init() {}

    public func toolDescriptors() async -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "skill",
                description: "Load a skill's instructions. The available skills are listed in your "
                    + "instructions with what each one is for; call this with the name of the one "
                    + "that covers the task before you start, and follow what it says.",
                schema: [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The skill's name, as listed.",
                        ],
                    ],
                    "required": ["name"],
                ],
                providerID: providerID,
                providerName: providerName
            ),
        ]
    }

    public func invoke(tool: String, arguments: JSONValue, callID: String) async -> ToolResult {
        guard tool == "skill" else {
            return .error("The \(providerName) provider has no tool named '\(tool)'.")
        }
        guard let requested = arguments["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty
        else {
            return .error("skill needs the name of the skill to load.")
        }

        guard let skill = SkillStore.read(name: requested) else {
            let known = SkillStore.installed().map(\.name)
            guard !known.isEmpty else {
                return .error(
                    "No skills are installed. They can be added in Settings › Skills."
                )
            }
            return .error("No skill named '\(requested)'. Installed: \(known.joined(separator: ", ")).")
        }

        var out = "# Skill: \(skill.name)\n\n\(skill.instructions)\n"
        // The folder, so anything the skill tells the model to read or run can be
        // reached: a skill that says "run scripts/extract.py" is useless without
        // knowing where that is.
        if let directory = skill.directory {
            out += "\n---\nThe skill's files are in \(directory.path)"
            if !skill.resources.isEmpty {
                out += ":\n" + skill.resources.map { "- \($0)" }.joined(separator: "\n")
            } else {
                out += "."
            }
        }
        return .ok(out)
    }
}

// MARK: - The prompt block

public enum SkillContext {
    /// The list the model sees before loading anything.
    ///
    /// Capped, and the cap is stated rather than silent. A model told there are
    /// twelve skills when there are forty will not go looking for the rest; a
    /// model told the list is truncated knows it may be worth asking.
    /// The catalogue, with the skills a message looks like it needs spelled out.
    ///
    /// **Every installed skill is listed, always.** That is the design, not an
    /// oversight: measured against the real skills, term matching put thirteen of
    /// fourteen messages on the right skill and scored nothing at all for the
    /// fourteenth, where the user said "W-9" and the skill says "PDF". A filter
    /// would have dropped the one that was right, and the model — which knows a
    /// W-9 is a PDF — would never have seen it.
    ///
    /// So the scoring promotes rather than selects. What it promotes gets its whole
    /// description; everything else gets its first sentence. That is 2,037
    /// characters against 9,389 for the nineteen real skills, with a hand back to
    /// `skill` for anything that reads as truncated.
    ///
    /// Returns the promoted names alongside the text so a caller can tell whether
    /// the catalogue actually changed — rendering it afresh on every message would
    /// rewrite the front of the prompt every message, and the front of the prompt
    /// is the part a provider caches.
    public static func catalogue(
        query: String,
        limit: Int = 40,
        skills: [Skill]? = nil
    ) -> (text: String, promoted: [String]) {
        let installed = skills ?? SkillStore.installed()
        guard !installed.isEmpty else { return ("", []) }

        let shown = Array(installed.prefix(limit))
        let promoted = SkillRanking.rank(query, skills: shown)
        let chosen = Set(promoted)
        let relevant = shown.filter { chosen.contains($0.name) }
        let rest = shown.filter { !chosen.contains($0.name) }

        var lines = [
            "You have skills installed. Each is a set of instructions for a kind of task.",
            "Read the one that covers what you are about to do — call `skill` with its name —",
            "before you start, rather than working it out from scratch.",
        ]

        if !relevant.isEmpty {
            lines.append("")
            lines.append("These cover what was just asked:")
            for skill in relevant {
                lines.append("- \(skill.name): \(flattened(skill.summary))")
            }
        }

        if !rest.isEmpty {
            lines.append("")
            lines.append(
                relevant.isEmpty
                    ? "Installed:"
                    : "Also installed — a shortened line each, and `skill` reads the whole thing:"
            )
            for skill in rest {
                lines.append("- \(skill.name): \(opening(skill.summary))")
            }
        }

        if installed.count > shown.count {
            lines.append("")
            lines.append("(\(installed.count - shown.count) more are installed but not listed here;"
                + " ask if none of the above fits.)")
        }

        return (lines.joined(separator: "\n"), promoted)
    }

    /// The whole thing, on one line.
    private static func flattened(_ summary: String) -> String {
        summary
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// One line, and no more than the first sentence of it.
    ///
    /// The first sentence is what a skill *is*; the ones after it are when to use
    /// it, which is what the full description is for. 160 characters covers the
    /// first sentence of nearly every real skill — 22% of the whole catalogue,
    /// measured — and the name in front of it is what the model actually matches
    /// against.
    private static func opening(_ summary: String) -> String {
        let flat = flattened(summary)
        guard let stop = flat.range(of: ". ") else {
            return flat.count > compactLimit ? String(flat.prefix(compactLimit)) + "…" : flat
        }
        let sentence = String(flat[..<stop.lowerBound]) + "."
        guard sentence.count > compactLimit else { return sentence }
        return String(flat.prefix(compactLimit)) + "…"
    }

    private static let compactLimit = 160
}
