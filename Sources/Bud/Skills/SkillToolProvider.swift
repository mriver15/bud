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
    /// The list the model sees before loading anything: every installed skill,
    /// ranked against the message rather than filtered.
    ///
    /// Measured against the real skills, term matching put thirteen of fourteen
    /// messages on the right skill and scored nothing at all for the fourteenth,
    /// where the user said "W-9" and the skill says "PDF". A filter would have
    /// dropped the one that was right, and the model — which knows a W-9 is a PDF
    /// — would never have seen it. So the scoring promotes rather than selects:
    /// what it promotes gets its whole description, and everything else gets one
    /// line — the first sentence plus the aliases its author wrote down, so a
    /// domain name stays visible.
    ///
    /// The whole list is capped by a character budget, and the cap is stated
    /// rather than silent. A model told the list is truncated knows it may be
    /// worth asking, and whatever was left out stays one `skill` call away.
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

        // The budget is spent in priority order: what the message is about in
        // full first, then the rest one line each. A line that does not fit in
        // the remaining budget is skipped rather than cut short, and everything
        // skipped stays one `skill` call away.
        var budget = skillCatalogueBudget
        var listed = 0

        var promotedLines: [String] = []
        for skill in relevant {
            let line = "- \(skill.name): \(flattened(skill.summary))"
            guard line.count <= budget else { continue }
            promotedLines.append(line)
            budget -= line.count
            listed += 1
        }

        var restLines: [String] = []
        for skill in rest {
            let line = "- \(skill.name): \(opening(skill))"
            guard line.count <= budget else { continue }
            restLines.append(line)
            budget -= line.count
            listed += 1
        }

        if !promotedLines.isEmpty {
            lines.append("")
            lines.append("These cover what was just asked:")
            lines.append(contentsOf: promotedLines)
        }

        if !restLines.isEmpty {
            lines.append("")
            lines.append(
                promotedLines.isEmpty
                    ? "Installed:"
                    : "Also installed — a shortened line each, and `skill` reads the whole thing:"
            )
            lines.append(contentsOf: restLines)
        }

        let unlisted = installed.count - listed
        if unlisted > 0 {
            lines.append("")
            lines.append("More available: \(unlisted) skills; ask Bud to list them.")
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

    /// One line for a skill that is not promoted: its first sentence, plus the
    /// aliases its author wrote down for it, so a domain name like "W-9" for the
    /// PDF skill stays visible when the rest of the description does not.
    private static func opening(_ skill: Skill) -> String {
        var line = firstSentence(skill.summary)
        let aliases = triggerAliases(skill.triggers)
        if !aliases.isEmpty {
            line += " [also called: \(aliases.joined(separator: ", "))]"
        }
        return line
    }

    /// One line, and no more than the first sentence of it.
    ///
    /// The first sentence is what a skill *is*; the ones after it are when to use
    /// it, which is what the full description is for. 160 characters covers the
    /// first sentence of nearly every real skill — 22% of the whole catalogue,
    /// measured — and the name in front of it is what the model actually matches
    /// against.
    private static func firstSentence(_ summary: String) -> String {
        let flat = flattened(summary)
        guard let stop = flat.range(of: ". ") else {
            return flat.count > compactLimit ? String(flat.prefix(compactLimit)) + "…" : flat
        }
        let sentence = String(flat[..<stop.lowerBound]) + "."
        guard sentence.count > compactLimit else { return sentence }
        return String(flat.prefix(compactLimit)) + "…"
    }

    /// The aliases a skill's author wrote down as its `triggers`, one per comma
    /// or newline, kept in their original casing so they read as names rather
    /// than as matching tokens.
    private static func triggerAliases(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// How many characters the catalogue may spend spelling out skills.
    ///
    /// The catalogue is the largest thing in front of the model that grows on
    /// its own: every skill installed adds a line, for ever, whether or not it
    /// is ever used. So it is capped by characters rather than by count, and the
    /// cap is stated rather than silent. Six thousand is about a page and a half
    /// of prompt — room for the few skills a message is actually about in full
    /// and a long list of one-line names and aliases, and no more than the
    /// catalogue is worth against the rest of the context it shares the request
    /// with. Whatever it leaves out stays one `skill` call away.
    static let skillCatalogueBudget = 6_000

    private static let compactLimit = 160
}
