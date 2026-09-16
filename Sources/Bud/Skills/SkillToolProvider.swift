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
    public static func prompt(limit: Int = 40) -> String {
        let installed = SkillStore.installed()
        guard !installed.isEmpty else { return "" }

        let shown = installed.prefix(limit)
        var lines = [
            "You have skills installed. Each is a set of instructions for a kind of task.",
            "Read the one that covers what you are about to do — call `skill` with its name —",
            "before you start, rather than working it out from scratch.",
            "",
        ]
        for skill in shown {
            lines.append("- \(skill.name): \(skill.summary.replacingOccurrences(of: "\n", with: " "))")
        }
        if installed.count > shown.count {
            lines.append("")
            lines.append("(\(installed.count - shown.count) more are installed but not listed here;"
                + " ask if none of the above fits.)")
        }
        return lines.joined(separator: "\n")
    }
}
