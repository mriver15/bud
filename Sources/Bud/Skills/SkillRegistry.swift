import Foundation
import Observation

/// A place skills come from: a GitHub repository with skill folders in it.
///
/// A source rather than a registry, because there is no registry to be a client
/// of. The format is an open standard and the skills live in repositories, so
/// discovery is reading a repository — which also means the catalogue is not
/// limited to whatever a vendor chose to list. Point Bud at any repo with skill
/// folders in it and it browses that.
public struct SkillSource: Sendable, Codable, Identifiable, Equatable {
    public var owner: String
    public var repo: String
    public var branch: String
    /// Restricts discovery to one path inside the repository. Empty means the
    /// whole tree, which is right for a repo that is nothing but skills and wrong
    /// for one that merely contains some.
    public var path: String
    public var title: String

    public var id: String { "\(owner)/\(repo)" }

    public init(owner: String, repo: String, branch: String = "main", path: String = "", title: String) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.path = path
        self.title = title
    }

    public var webURL: URL? { URL(string: "https://github.com/\(owner)/\(repo)") }

    /// Where the skills are.
    ///
    /// One source is shipped, and it is the one that is checked rather than
    /// guessed: a list of half-remembered repositories would be a marketplace
    /// whose search box mostly returns nothing.
    public static let curated: [SkillSource] = [
        SkillSource(owner: "anthropics", repo: "skills", path: "skills", title: "Anthropic"),
    ]
}

/// A skill that exists in a source but is not installed here.
public struct AvailableSkill: Sendable, Identifiable, Equatable {
    public var source: SkillSource
    /// The folder the skill lives in, relative to the repository root.
    public var folder: String
    public var name: String
    public var summary: String
    public var isInstalled: Bool

    public var id: String { "\(source.id)/\(folder)" }
}

/// Browses sources and installs from them.
@MainActor
@Observable
public final class SkillRegistry {
    public private(set) var sources: [SkillSource]
    public private(set) var available: [AvailableSkill] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var installedNames: Set<String> = []

    /// Trees are kept because installing needs the file list too, and a browse
    /// followed by twenty installs should read each repository once.
    @ObservationIgnored private var trees: [String: [String]] = [:]
    @ObservationIgnored private static let sourcesKey = "bud.skillSources"

    public init() {
        let stored = UserDefaults.standard.data(forKey: Self.sourcesKey)
            .flatMap { try? JSONDecoder().decode([SkillSource].self, from: $0) }
        sources = stored ?? SkillSource.curated
        refreshInstalled()
    }

    public func refreshInstalled() {
        installedNames = Set(SkillStore.installed().map(\.name))
    }

    // MARK: - Sources

    public func add(source: SkillSource) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        sources.append(source)
        persistSources()
    }

    public func remove(source: SkillSource) {
        sources.removeAll { $0.id == source.id }
        trees[source.id] = nil
        persistSources()
    }

    private func persistSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourcesKey)
    }

    // MARK: - Browsing

    public func browseAll() async {
        isLoading = true
        errorMessage = nil
        var collected: [AvailableSkill] = []
        var failures: [String] = []

        for source in sources {
            do {
                collected.append(contentsOf: try await browse(source))
            } catch {
                failures.append("\(source.title): \(error.localizedDescription)")
            }
        }

        available = collected.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        // Named rather than swallowed: a source that is down and a source with
        // nothing in it look identical from an empty list.
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isLoading = false
    }

    public func browse(_ source: SkillSource) async throws -> [AvailableSkill] {
        let paths = try await tree(for: source)
        let manifests = paths.filter { $0.hasSuffix("/SKILL.md") || $0 == "SKILL.md" }
        let installed = Set(SkillStore.installed().map(\.name))

        // One request per skill, run a few at a time. The raw host has no rate
        // limit, but twenty simultaneous connections to it is impolite and no
        // faster than six.
        return await withTaskGroup(of: AvailableSkill?.self) { group in
            var iterator = manifests.makeIterator()
            var results: [AvailableSkill] = []

            func addNext() {
                guard let manifest = iterator.next() else { return }
                group.addTask {
                    guard let text = try? await Self.raw(source: source, path: manifest),
                          let skill = try? SkillParser.parse(text)
                    else { return nil }
                    return AvailableSkill(
                        source: source,
                        folder: String(manifest.dropLast("/SKILL.md".count)),
                        name: skill.name,
                        summary: skill.summary,
                        isInstalled: installed.contains(skill.name)
                    )
                }
            }

            for _ in 0..<6 { addNext() }
            while let result = await group.next() {
                if let result { results.append(result) }
                addNext()
            }
            return results
        }
    }

    // MARK: - Installing

    /// A skill that has been downloaded and inspected, waiting on a decision.
    public struct PendingSkill: Identifiable, Sendable {
        public var entry: AvailableSkill
        public var report: SkillScanReport
        public var id: String { entry.id }
    }

    /// Set when a download finished and something in it needs a person to look.
    public private(set) var pending: PendingSkill?
    @ObservationIgnored private var pendingStaging: URL?
    @ObservationIgnored private var pendingFolder: URL?

    /// Downloads a skill, inspects it, and installs it if there is nothing to see.
    ///
    /// The decision is made before anything reaches the skills folder, which is
    /// the only order that helps: a screen applied after installing is a report on
    /// something already able to be used.
    public func prepare(_ entry: AvailableSkill) async throws {
        let (staging, folder) = try await download(entry)
        let report = SkillScanner.scan(directory: folder)

        if report.isBlocked {
            try? FileManager.default.removeItem(at: staging)
            throw SkillError.refused(report.findings(at: .blocked).map(\.title))
        }

        guard report.needsReview else {
            try commit(entry: entry, staging: staging, folder: folder)
            return
        }
        // Held rather than discarded: the download is done and the decision may
        // well be yes. `pendingStaging` is cleaned up either way.
        clearPending()
        pendingStaging = staging
        pendingFolder = folder
        pending = PendingSkill(entry: entry, report: report)
    }

    /// Installs what `prepare` held back.
    public func confirmPending() throws {
        guard let pending, let staging = pendingStaging, let folder = pendingFolder else { return }
        try commit(entry: pending.entry, staging: staging, folder: folder)
    }

    public func discardPending() {
        clearPending()
    }

    private func clearPending() {
        if let pendingStaging { try? FileManager.default.removeItem(at: pendingStaging) }
        pendingStaging = nil
        pendingFolder = nil
        pending = nil
    }

    private func commit(entry: AvailableSkill, staging: URL, folder: URL) throws {
        let origin = entry.source.webURL.map { "\($0)/tree/\(entry.source.branch)/\(entry.folder)" }
        let installed = try SkillStore.install(from: folder, origin: origin)
        try? FileManager.default.removeItem(at: staging)
        pendingStaging = nil
        pendingFolder = nil
        pending = nil
        refreshInstalled()
        available = available.map { row in
            var updated = row
            if row.name == installed.name { updated.isInstalled = true }
            return updated
        }
    }

    /// Downloads every file under the skill's folder into a staging directory.
    ///
    /// Every file, not just `SKILL.md`: the standard is explicit that a skill may
    /// carry scripts, references and assets, and a skill installed without them is
    /// one that fails the first time it is followed.
    private func download(_ skill: AvailableSkill) async throws -> (staging: URL, folder: URL) {
        let paths = try await tree(for: skill.source)
        let prefix = skill.folder.isEmpty ? "" : skill.folder + "/"
        let files = paths.filter { $0.hasPrefix(prefix) && $0 != prefix }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("bud-skill-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(skill.name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for path in files {
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            // A path from a repository is data. `..` in one would write outside the
            // folder it is being installed into, and the scanner would only see it
            // afterwards.
            guard !relative.split(separator: "/").contains("..") else { continue }
            let destination = folder.appendingPathComponent(relative)
            guard destination.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) else {
                continue
            }
            let data = try await Self.rawData(source: skill.source, path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
        }
        return (staging, folder)
    }

    public func uninstall(_ name: String) throws {
        try SkillStore.remove(name: name)
        refreshInstalled()
        available = available.map { entry in
            var updated = entry
            if entry.name == name { updated.isInstalled = false }
            return updated
        }
    }

    // MARK: - GitHub

    private struct Tree: Decodable {
        struct Entry: Decodable {
            var path: String
            var type: String
        }
        var tree: [Entry]
    }

    /// Every file path in the source, cached.
    private func tree(for source: SkillSource) async throws -> [String] {
        if let cached = trees[source.id] { return cached }
        guard let url = URL(string:
            "https://api.github.com/repos/\(source.owner)/\(source.repo)/git/trees/\(source.branch)?recursive=1"
        ) else { throw SkillError.badSource(source.id) }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Unauthenticated, so this is a small courtesy rather than a requirement.
        request.setValue("Bud", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SkillError.unreachable(source.id) }
        guard http.statusCode == 200 else {
            throw SkillError.sourceRefused(source.id, http.statusCode)
        }
        let decoded = try JSONDecoder().decode(Tree.self, from: data)

        let prefix = source.path.isEmpty ? "" : source.path + "/"
        let files = decoded.tree
            .filter { $0.type == "blob" && $0.path.hasPrefix(prefix) }
            .map(\.path)
        trees[source.id] = files
        return files
    }

    private static func raw(source: SkillSource, path: String) async throws -> String {
        let data = try await rawData(source: source, path: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillError.notText(path)
        }
        return text
    }

    private static func rawData(source: SkillSource, path: String) async throws -> Data {
        let encoded = path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        guard let url = URL(string:
            "https://raw.githubusercontent.com/\(source.owner)/\(source.repo)/\(source.branch)/\(encoded)"
        ) else { throw SkillError.unreachable(path) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SkillError.unreachable(path)
        }
        return data
    }
}

public enum SkillError: LocalizedError {
    case refused([String])
    case badSource(String)
    case unreachable(String)
    case sourceRefused(String, Int)
    case notText(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let reasons):
            // The reasons are the whole message: "refused" on its own tells
            // somebody nothing they can act on.
            return "This skill was not installed. " + reasons.joined(separator: "; ") + "."
        case .badSource(let source):
            return "“\(source)” is not a repository Bud can read"
        case .unreachable(let what):
            return "could not fetch \(what)"
        case .sourceRefused(let source, let code):
            return "the repository for “\(source)” answered \(code)"
        case .notText(let path):
            return "\(path) is not readable text"
        }
    }
}
