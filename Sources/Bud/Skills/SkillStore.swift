import Foundation

/// The skills on this machine: `~/.bud/skills/<name>/`.
///
/// One directory per skill, in the shape the standard defines, so the folder is
/// the source of truth rather than a database that describes it. Someone who
/// writes a skill by hand, copies one in from another tool, or edits an installed
/// one with a text editor has done the right thing in every case — there is no
/// sync step to forget and no state that can disagree with the disk.
public enum SkillStore {
    /// Read per call, not captured once: the headless modes redirect the bud
    /// directory after this file's static initialisers have run.
    private static var defaultDirectory: URL {
        BudConfigLoader.budDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    /// Redirects the store, and nothing but the test suite sets it.
    ///
    /// The cache's whole risk is that it stops noticing an edit to a folder this
    /// design invites people to edit, and proving it does notice means writing to
    /// a skills folder — which should not be the one somebody is using.
    nonisolated(unsafe) static var directoryOverride: URL?

    public static var directory: URL { directoryOverride ?? defaultDirectory }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Everything installed, by name.
    ///
    /// A skill that will not parse is skipped rather than taking the list with it.
    /// Skills arrive from the internet and from other people, and one malformed
    /// folder should cost its own row, not the feature.
    ///
    /// Cached, because this is on the request path — the prompt lists every skill
    /// every round — and reading and parsing every manifest and walking every
    /// folder to produce the same answer twenty-four times a turn is work nobody
    /// asked for. The cache is keyed on a fingerprint of what it was built from
    /// rather than on a flag, so a `SKILL.md` edited by hand is picked up on the
    /// next call: this design invites people to edit the folder, and a cache that
    /// stopped noticing would quietly undo that.
    public static func installed() -> [Skill] {
        ensureDirectory()
        guard let entries = directories() else { return [] }

        // Both the manifest and its folder. The manifest carries the name and the
        // description; the folder's own timestamp is what changes when a file is
        // added or removed beside it, which is the only other thing the cached
        // value depends on.
        let fingerprint = entries
            .map { "\($0.lastPathComponent):\(stamp(of: $0.appendingPathComponent("SKILL.md"))):\(stamp(of: $0))" }
            .joined(separator: "|")
        if let cached = cache.value(fingerprint: fingerprint) { return cached }

        let skills = entries
            .compactMap { read(directory: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cache.store(skills, fingerprint: fingerprint)
        return skills
    }

    private static func directories() -> [URL]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Size and modification date, which change when a file does.
    ///
    /// A stat, not a read: twenty of these cost less than one manifest parse, and
    /// being exact is cheaper than deciding when to be approximate.
    private static func stamp(of url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let date = values.contentModificationDate
        else { return "-" }
        // The size is absent for a directory, which is fine — its timestamp is
        // what is being read there. And the time is not rounded to the second: two
        // edits within one tick is exactly what a person saving a file twice looks
        // like, and rounding would call the second one unchanged.
        return "\(values.fileSize ?? -1)@\(date.timeIntervalSince1970)"
    }

    /// One entry, guarded. `installed()` is read from the prompt builder and from
    /// the settings pane, which are not the same thread.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var fingerprint = ""
        private var skills: [Skill] = []
        private var filled = false

        func value(fingerprint wanted: String) -> [Skill]? {
            lock.withLock { filled && fingerprint == wanted ? skills : nil }
        }

        func store(_ value: [Skill], fingerprint wanted: String) {
            lock.withLock {
                skills = value
                fingerprint = wanted
                filled = true
            }
        }

        func clear() {
            lock.withLock { filled = false }
        }
    }

    private static let cache = Cache()

    /// Drops the cached listing. Called when this store writes, so the next read
    /// is the one that sees it.
    public static func invalidate() { cache.clear() }

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
        invalidate()
        // The cognitive graph learns the skill the moment it is installed, so
        // a later query that names it can walk to what it connects to.
        _ = CognitiveStore.recordSkill(name: skill.name)
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
        invalidate()
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
