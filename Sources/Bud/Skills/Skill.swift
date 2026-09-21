import Foundation

/// One Agent Skill: a folder with a `SKILL.md` in it.
///
/// Bud implements the open Agent Skills format rather than one of its own. A
/// skill written here is a skill every other agent that supports the standard can
/// load, and one written elsewhere can be dropped in without translation — which
/// is the only reason a marketplace is worth building rather than a folder.
public struct Skill: Sendable, Identifiable, Equatable {
    public var id: String { name }

    /// Lowercase letters, digits and single hyphens; at most 64 characters; and
    /// it has to match the name of the folder it sits in.
    public var name: String
    /// What the skill does *and when to use it*. This is the whole of what the
    /// model sees until it decides to load the skill, so a description that only
    /// says what the skill is about will not be picked up at the right moment.
    public var summary: String
    public var license: String?
    public var compatibility: String?
    public var metadata: [String: String]
    /// Pre-approved tools, as the spec's space-separated string. Kept as written:
    /// it is experimental in the standard, and Bud decides what to run.
    ///
    /// It is no longer only decorative: a skill that declares `agent:` is offered
    /// as something to delegate to, and this is then the tool list that agent runs
    /// with. See ``Skill/toolList(_:)``.
    public var allowedTools: String?
    /// When to hand a whole slice of work to this skill instead of loading it into
    /// the conversation. Present means the skill is also an agent.
    ///
    /// Opt-in, because a skill is instructions that can be loaded where they are
    /// needed and most are better used that way. A skill written as a procedure
    /// somebody should follow — with the tools it needs listed beside it — is the
    /// one that is worth naming as a delegate.
    public var delegation: String?
    /// The Markdown after the frontmatter — the part loaded on activation.
    public var instructions: String

    /// Where it came from, when it was installed rather than written here.
    public var source: String?

    /// The words its author says people use for it, from `metadata.triggers`.
    ///
    /// The gap this closes is measured. Asked to fill a W-9, a matcher finds
    /// nothing in the `pdf` skill, whose description talks about PDF files — a
    /// W-9 is one, and only a reader who knows that makes the connection. The
    /// author knows. Comma-separated, and absent from almost every skill in the
    /// wild, which costs nothing.
    public var triggers: String { metadata["triggers"] ?? "" }

    /// `triggers` split into the phrases themselves, one per comma or newline,
    /// kept in the author's casing so a phrase reads as a name rather than as a
    /// matching token.
    ///
    /// Read wherever the alias matters — the skill line the model sees, the
    /// ranking that decides what to promote, and the vocabulary the delegate
    /// resolver matches a capability against — so the split is written once.
    public var triggerAliases: [String] { Skill.triggerAliases(triggers) }

    /// The same split, for a raw `metadata.triggers` value.
    ///
    /// Comma- or newline-separated because that is how the field is written by
    /// hand; blanks are dropped rather than kept as an empty phrase that would
    /// match every wording.
    public static func triggerAliases(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `allowed-tools` as a list.
    ///
    /// The field is a space-separated string in the standard and a comma-separated
    /// one in half the skills in the wild, so both are accepted — a tool list that
    /// silently parses to one entry named "read_file," is worse than either. A bare
    /// `*` or an absent field means every tool; an empty string means none, which is
    /// how a skill says it is reasoning only.
    public static func toolList(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }
        if cleaned == "*" { return nil }
        return cleaned
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    /// Files beside `SKILL.md`, relative to the skill folder, so the model can be
    /// told what else it may read.
    public var resources: [String] = []

    public var directory: URL?
}

// MARK: - Parsing

/// Reads the frontmatter of a `SKILL.md`.
///
/// The spec says "YAML frontmatter", and this reads the subset the spec actually
/// defines: scalar keys, and one level of nesting for `metadata`. A general YAML
/// parser would accept anchors, multi-document streams and flow collections that
/// no skill uses, and would then have to decide what they mean — a larger surface
/// for no gain.
public enum SkillParser {
    public enum Problem: LocalizedError, Equatable {
        case noFrontmatter
        case unterminatedFrontmatter
        case missingName
        case missingDescription
        case badName(String)
        case nameTooLong(Int)
        case descriptionTooLong(Int)
        case folderMismatch(name: String, folder: String)

        public var errorDescription: String? {
            switch self {
            case .noFrontmatter:
                return "no frontmatter — a SKILL.md has to open with a --- block declaring name and description"
            case .unterminatedFrontmatter:
                return "the frontmatter is never closed — the opening --- needs a matching one"
            case .missingName:
                return "the frontmatter has no name"
            case .missingDescription:
                return "the frontmatter has no description, which is the only thing the model sees until it loads the skill"
            case .badName(let name):
                return "“\(name)” is not a valid name — lowercase letters, digits and single hyphens only, and it cannot start or end with a hyphen"
            case .nameTooLong(let count):
                return "the name is \(count) characters; the limit is 64"
            case .descriptionTooLong(let count):
                return "the description is \(count) characters; the limit is 1024"
            case .folderMismatch(let name, let folder):
                return "the skill is named “\(name)” but its folder is “\(folder)” — the spec requires them to match"
            }
        }
    }

    public static func parse(_ text: String, folder: String? = nil) throws -> Skill {
        guard let (lines, body) = split(text) else { throw Problem.noFrontmatter }
        let fields = readFields(lines)

        guard let rawName = fields.scalars["name"], !rawName.isEmpty else { throw Problem.missingName }
        guard let summary = fields.scalars["description"], !summary.isEmpty else {
            throw Problem.missingDescription
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(name: name)
        if summary.count > 1024 { throw Problem.descriptionTooLong(summary.count) }
        if let folder, folder != name { throw Problem.folderMismatch(name: name, folder: folder) }

        return Skill(
            name: name,
            summary: summary,
            license: fields.scalars["license"],
            compatibility: fields.scalars["compatibility"]?.nilWhenEmpty,
            metadata: fields.metadata,
            allowedTools: fields.scalars["allowed-tools"]?.nilWhenEmpty,
            delegation: fields.scalars["agent"]?.nilWhenEmpty,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The name rules from the specification, which are also what makes a name
    /// safe to use as a folder.
    public static func validate(name: String) throws {
        guard name.count <= 64 else { throw Problem.nameTooLong(name.count) }
        guard !name.isEmpty,
              name.first != "-",
              name.last != "-",
              !name.contains("--"),
              name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        else { throw Problem.badName(name) }
    }

    /// Splits the leading `---` block from the body that follows it.
    ///
    /// Tolerant of what real files contain and the spec does not mention: a
    /// byte-order mark, and CRLF endings from anything written on Windows. A file
    /// that is otherwise perfectly valid should not fail to load over a character
    /// nobody can see.
    static func split(_ text: String) -> (lines: [String], body: String)? {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let normalised = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalised.components(separatedBy: "\n")

        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        let start = index + 1
        var end = start
        while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces) != "---" {
            end += 1
        }
        guard end < lines.count else { return nil }
        return (Array(lines[start..<end]), lines[(end + 1)...].joined(separator: "\n"))
    }

    /// Scalars at the top level, plus `key: value` pairs under `metadata`.
    ///
    /// Block scalars are supported because descriptions actually use them: several
    /// of the skills in the standard's own example collection write
    /// `description: >` and fold the text over several indented lines. Reading only
    /// the first line yields ">" — a marketplace of blank descriptions, produced by
    /// the one construct a long description needs.
    ///
    /// Lists and nested maps other than `metadata` are still skipped. Nothing in
    /// the standard uses them, and inventing a meaning for a field the spec leaves
    /// undefined is how two implementations quietly stop agreeing.
    static func readFields(_ lines: [String]) -> (scalars: [String: String], metadata: [String: String]) {
        var scalars: [String: String] = [:]
        var metadata: [String: String] = [:]
        var inMetadata = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }

            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let indented = line.first?.isWhitespace ?? false

            if indented {
                if inMetadata, !key.isEmpty, !value.isEmpty { metadata[key] = unquote(value) }
                continue
            }
            guard !key.isEmpty else { continue }
            if key == "metadata", value.isEmpty {
                inMetadata = true
                continue
            }
            inMetadata = false

            if let style = blockStyle(value) {
                let block = readBlock(lines, from: &index, folded: style)
                if !block.isEmpty { scalars[key] = block }
                continue
            }
            guard !value.isEmpty else { continue }
            scalars[key] = unquote(value)
        }
        return (scalars, metadata)
    }

    /// The style a `>` or `|` indicator asks for, or nil when the value is a plain
    /// scalar. The trailing `-`/`+` chomping indicator is accepted and treated as
    /// the default: no skill's meaning turns on whether the last newline is kept.
    static func blockStyle(_ value: String) -> Bool? {
        switch value {
        case ">", ">-", ">+": return true    // folded
        case "|", "|-", "|+": return false   // literal
        default: return nil
        }
    }

    /// Consumes the indented lines belonging to a block scalar.
    ///
    /// The block runs until a line that is neither blank nor indented past the
    /// key — blank lines belong to it, which is what lets a folded description
    /// hold a paragraph break.
    static func readBlock(_ lines: [String], from index: inout Int, folded: Bool) -> String {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                body.append("")
                index += 1
                continue
            }
            guard line.first?.isWhitespace == true else { break }
            body.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        while body.last?.isEmpty == true { body.removeLast() }

        guard folded else { return body.joined(separator: "\n") }
        // Folded: runs of lines become one line, and a blank line separates them.
        var paragraphs: [String] = []
        var current: [String] = []
        for line in body {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
                continue
            }
            current.append(line)
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n")
    }

    /// Strips the quotes a value may be wrapped in, and nothing else — a colon or
    /// a hash inside a description is ordinary text, not syntax.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

extension String {
    fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
