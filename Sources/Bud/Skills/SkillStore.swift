import Foundation

/// The skills on this machine: `~/.bud/skills/<name>/`.
///
/// One directory per skill, in the shape the standard defines, so the folder is
/// the source of truth rather than a database that describes it. Someone who
/// writes a skill by hand, copies one in from another tool, or edits an installed
/// one with a text editor has done the right thing in every case — there is no
/// sync step to forget and no state that can disagree with the disk.
public enum SkillStore {
    public static var directory: URL {
        BudConfigLoader.budDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Everything installed, by name.
    ///
    /// A skill that will not parse is skipped rather than taking the list with it.
    /// Skills arrive from the internet and from other people, and one malformed
    /// folder should cost its own row, not the feature.
    public static func installed() -> [Skill] {
        ensureDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { read(directory: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func read(name: String) -> Skill? {
        read(directory: directory.appendingPathComponent(name, isDirectory: true))
    }

    /// Reads one skill folder, or nil when it is not one.
    public static func read(directory url: URL) -> Skill? {
        let manifest = url.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        guard var skill = try? SkillParser.parse(text, folder: url.lastPathComponent) else { return nil }
        skill.directory = url
        skill.source = readOrigin(url)
        skill.resources = resources(in: url)
        return skill
    }

    /// Files beside `SKILL.md`, relative to the skill folder.
    ///
    /// Capped, and directories are not descended into beyond a level or two: the
    /// list exists so the model knows what it may read, and a skill bundling
    /// thousands of files would spend more context saying so than the skill is
    /// worth.
    static func resources(in url: URL, limit: Int = 40) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [String] = []
        // Compared as path components rather than by trimming a prefix string: on
        // macOS an enumerator hands back `/private/var/...` for a directory named
        // `/var/...`, so a prefix match silently fails and every "relative" path
        // comes back absolute. Nothing looks broken until something tries to open
        // one from the skill's own folder.
        let base = url.standardizedFileURL.pathComponents
        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            if name == "SKILL.md" || name == ".origin" { continue }
            let parts = item.standardizedFileURL.pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
            found.append(parts.dropFirst(base.count).joined(separator: "/"))
            if found.count >= limit { break }
        }
        return found.sorted()
    }

    // MARK: - Installing

    /// Copies a skill folder in, replacing any skill of the same name.
    ///
    /// Replacing rather than refusing: the common case is installing a newer
    /// version of something already present, and a marketplace that cannot update
    /// the thing it installed is one nobody uses twice.
    @discardableResult
    public static func install(from source: URL, origin: String? = nil) throws -> Skill {
        ensureDirectory()
        guard let skill = read(directory: source) else {
            throw SkillStoreError.notASkill(source.lastPathComponent)
        }

        let destination = directory.appendingPathComponent(skill.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        quarantine(destination)
        if let origin {
            try? origin.write(
                to: destination.appendingPathComponent(".origin"),
                atomically: true,
                encoding: .utf8
            )
        }
        return read(name: skill.name) ?? skill
    }

    public static func remove(name: String) throws {
        let target = directory.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// Marks installed files as having come from the internet.
    ///
    /// macOS's own defence rather than one of ours: a quarantined file is one
    /// Gatekeeper will intervene on if it is ever opened or run. Bud downloaded
    /// these, so saying so is simply accurate — and it means a script inside a
    /// skill is treated exactly like a script downloaded in a browser.
    private static func quarantine(_ folder: URL) {
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return }
        for case let item as URL in walker {
            var values = URLResourceValues()
            values.quarantineProperties = [
                "agent": "Bud",
                "type": 0,
                "timestamp": Date(),
            ] as [String: Any]
            var url = item
            try? url.setResourceValues(values)
        }
    }

    /// Where an installed skill came from, written beside it at install time.
    private static func readOrigin(_ url: URL) -> String? {
        let text = try? String(contentsOf: url.appendingPathComponent(".origin"), encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    }
}

public enum SkillStoreError: LocalizedError {
    case notASkill(String)
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .notASkill(let folder):
            return "“\(folder)” has no readable SKILL.md, so it is not a skill"
        case .notWritable(let name):
            return "“\(name)” could not be written to the skills folder"
        }
    }
}

extension String {
    fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
