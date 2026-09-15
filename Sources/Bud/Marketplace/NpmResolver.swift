import Foundation

/// The npm question a Glama row raises, and the memo of its answers.
///
/// Glama's `servers` directory publishes a server's source and nothing about
/// running it: no package identifier, no command. Its slug is therefore a
/// *candidate* name rather than an answer — `npx -y <slug>` for a package that
/// does not exist installs nothing and fails at launch, which is worse than a row
/// that says it is browse-only. This asks npm whether the candidate really names
/// a package someone can run, and answers only from what npm said.
///
/// Two properties make it usable behind a list of hundreds of rows: answers are
/// memoised for the life of the process — hits *and* misses, since a miss costs
/// the same request a hit does and is the more common answer — and a probe never
/// throws, so npm being slow or unreachable leaves a row exactly as it was built
/// rather than failing the catalogue that put it on screen.
///
/// `@unchecked Sendable`: every mutable field is reachable only through `lock`,
/// and the `let`s are immutable and thread-safe. Every critical section is a
/// synchronous function — `NSLock.lock()` is unavailable from an async context —
/// and none of them suspends.
public final class NpmResolver: @unchecked Sendable {
    /// Where package documents are read from. npm's public registry answers both
    /// the bare and the `@scope/name` form at this one host.
    public static let defaultBaseURLString = "https://registry.npmjs.org"

    /// A probe that has not answered by now is not worth waiting for: the row it
    /// belongs to is already on screen, and the next refresh asks again. Shorter
    /// than the catalogue clients' timeout, because nothing is waiting on it.
    public static let timeout: TimeInterval = 10

    /// The one resolver for the process, so an answer survives a catalogue
    /// reload, a source switch and a key change — none of which change what npm
    /// holds.
    public static let shared = NpmResolver()

    // MARK: - The question

    /// A package a Glama record's slug might name.
    ///
    /// Both readings are asked for. The bare slug is what the record calls itself
    /// and what a publisher who owns the name publishes; the scoped form is for a
    /// publisher who scoped the package to their Glama namespace, where
    /// `mriver15/getcompetitive` publishes `@mriver15/getcompetitive`.
    public struct Candidate: Sendable, Hashable {
        public var namespace: String
        public var slug: String

        public init(namespace: String, slug: String) {
            self.namespace = namespace
            self.slug = slug
        }

        /// The names npm is asked about, in the order it is asked.
        public var identifiers: [String] {
            guard !namespace.isEmpty else { return [slug] }
            return [slug, "@\(namespace)/\(slug)"]
        }
    }

    /// What one candidate's question resolved to.
    enum Outcome: Sendable, Equatable {
        /// npm holds a package by that name, and it declares something to run.
        case package(String)
        /// npm answered, and there is no such package to install.
        case absent
        /// npm could not be asked: offline, a 5xx, a body Bud could not read.
        case unavailable
    }

    /// The memo, and the one rule about what belongs in it.
    ///
    /// Its own type because that rule is the part worth stating without a
    /// network: an answer is kept, and a failure to reach npm is *not* an answer.
    /// Keeping one would hide a package that exists for the rest of the process's
    /// life because npm was unreachable once.
    struct Answers {
        private var answers: [Candidate: Outcome] = [:]

        /// What npm said, or `nil` when it has not been asked or could not be.
        func answer(for candidate: Candidate) -> Outcome? { answers[candidate] }

        mutating func record(_ outcome: Outcome, for candidate: Candidate) {
            guard outcome != .unavailable else { return }
            answers[candidate] = outcome
        }
    }

    // MARK: - State

    private let baseURLString: String
    private let session: URLSession
    private let lock = NSLock()
    private var answers = Answers()
    /// Probes already out, so two callers asking about one row at the same moment
    /// — a search landing while the browse list is still resolving — share a
    /// request instead of sending two.
    private var running: [Candidate: Task<Outcome, Never>] = [:]

    public init(
        baseURLString: String = NpmResolver.defaultBaseURLString,
        session: URLSession = .shared
    ) {
        self.baseURLString = baseURLString
        self.session = session
    }

    // MARK: - Asking

    /// The npm package behind a Glama record, or `nil` when npm has none for it —
    /// or could not be asked. Both are browse-only, which is what the caller does
    /// with `nil`.
    public func identifier(namespace: String, slug: String) async -> String? {
        let candidate = Candidate(namespace: namespace, slug: slug)
        guard case .package(let identifier) = await outcome(for: candidate) else { return nil }
        return identifier
    }

    /// The answer for a candidate, asking npm if this is the first time.
    func outcome(for candidate: Candidate) async -> Outcome {
        if let answered = cachedAnswer(candidate) { return answered }
        let probe = probeOrJoin(candidate)
        let outcome = await probe.value
        finish(outcome, for: candidate)
        return outcome
    }

    /// What npm already said about a candidate, without asking it again. `nil`
    /// means the question is open — which is not the same as "no package", and is
    /// why a row waiting on a probe is not treated as a miss.
    func cachedAnswer(_ candidate: Candidate) -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return answers.answer(for: candidate)
    }

    /// The probe for this candidate, starting one if none is out.
    ///
    /// Look-up-and-start as one critical section: this resolver is a locked class
    /// rather than an actor, so a check followed by a start outside the lock is a
    /// race that would send the same request twice.
    private func probeOrJoin(_ candidate: Candidate) -> Task<Outcome, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let running = running[candidate] { return running }
        let base = baseURLString
        let session = self.session
        let probe = Task { await NpmResolver.probe(candidate, base: base, session: session) }
        running[candidate] = probe
        return probe
    }

    private func finish(_ outcome: Outcome, for candidate: Candidate) {
        lock.lock()
        defer { lock.unlock() }
        running[candidate] = nil
        answers.record(outcome, for: candidate)
    }

    // MARK: - Probing

    /// Asks npm about each name the candidate could be, in order, and stops at the
    /// first one it has.
    static func probe(_ candidate: Candidate, base: String, session: URLSession) async -> Outcome {
        for identifier in candidate.identifiers {
            switch await ask(identifier, base: base, session: session) {
            case .package(let name): return .package(name)
            case .absent: continue
            // The second name is one request to the same host that just failed;
            // asking it buys nothing but another timeout.
            case .unavailable: return .unavailable
            }
        }
        return .absent
    }

    /// One name, one request. Nothing here throws: a transport failure is an
    /// outcome like any other, and the caller's answer to it is to leave the row
    /// as it found it.
    private static func ask(_ identifier: String, base: String, session: URLSession) async -> Outcome {
        guard let url = packageURL(identifier, base: base) else { return .absent }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bud/1.0", forHTTPHeaderField: "User-Agent")

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            return .unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return outcome(status: status, body: body, asking: identifier)
    }

    // MARK: - Reading npm's answer

    /// Classifies one response.
    ///
    /// The status is the classification and the body only refines it, because the
    /// two disagree in both directions: npm answers a name it does not have with
    /// a 404 carrying `{"error":"Not found"}`, and a body Bud cannot read is a
    /// proxy's page rather than a statement about the package. Only a document
    /// that decodes, names the package that was asked about, and declares
    /// something to run is a hit. The rest is split into "no such package"
    /// (remembered) and "could not tell" (not remembered), and that split is what
    /// keeps one bad request from hiding a package for the rest of the session.
    static func outcome(status: Int, body: Data, asking identifier: String) -> Outcome {
        guard status == 200 else { return status == 404 ? .absent : .unavailable }
        guard let document = try? JSONDecoder().decode(PackageDocument.self, from: body),
              let name = document.name, !name.isEmpty
        else {
            return errorDocument(in: body) ? .absent : .unavailable
        }
        // npm answers with the package's own name. A document naming something
        // else is not an answer about this name, and installing what it does name
        // would install a different package than the one asked about.
        guard name.caseInsensitiveCompare(identifier) == .orderedSame else { return .unavailable }
        return document.isRunnable ? .package(name) : .absent
    }

    /// npm's miss document, which it sends on its own as well as with the 404.
    static func errorDocument(in body: Data) -> Bool {
        JSONValue(parsing: String(decoding: body, as: UTF8.self))?["error"] != nil
    }

    /// The document URL for one package name.
    ///
    /// Built from a validated name rather than from catalogue text: a name is
    /// third-party data, and the check is what keeps one from naming a path other
    /// than the one intended.
    static func packageURL(_ identifier: String, base: String) -> URL? {
        guard isPackageName(identifier) else { return nil }
        return URL(string: base + "/" + identifier)
    }

    /// npm's own rule for a name, narrowed to what this needs: letters, digits and
    /// `-._` within a segment, with npm's `@scope/name` form for the scoped one.
    /// Everything else — a query, a fragment, an escape, a second path segment —
    /// is a name npm cannot have published.
    static func isPackageName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 214 else { return false }
        let scoped = name.hasPrefix("@")
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == (scoped ? 2 : 1) else { return false }

        for (index, segment) in segments.enumerated() {
            let body = index == 0 && scoped ? segment.dropFirst() : segment[...]
            guard !body.isEmpty, body != ".", body != ".." else { return false }
            guard body.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { return false }
        }
        return true
    }

    /// The part of npm's package document an install for a row depends on.
    ///
    /// Only the latest release matters, and of that only its `bin`: `npx -y
    /// <name>` runs the package's executable, so a document that names none — a
    /// library, say — describes something that cannot be installed as a command.
    /// The rest of the document, every version ever published included, is
    /// decoded past unread.
    ///
    /// Nothing here is required. This reads a document Bud did not write, and a
    /// shape it does not recognise has to come back as "not installable" rather
    /// than as a throw.
    struct PackageDocument: Decodable {
        var name: String?
        private var distTags: [String: String]?
        /// Every version the package has ever published, read through `Lossy`:
        /// the history of a long-lived package is thousands of entries, Bud reads
        /// exactly one of them, and one entry npm spells oddly must not cost the
        /// answer about that one.
        private var versions: [String: Lossy<Version>]?

        private enum CodingKeys: String, CodingKey {
            case name, versions
            case distTags = "dist-tags"
        }

        private struct Version: Decodable {
            var bin: Bins?
        }

        /// `bin` is one path for a package with a single executable and an object
        /// keyed by command for a package with several; both mean there is one.
        enum Bins: Decodable {
            case one(String)
            case many([String: String])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let one = try? container.decode(String.self) {
                    self = .one(one)
                } else if let many = try? container.decode([String: String].self) {
                    self = .many(many)
                } else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "bin is neither a path nor a command table"
                    )
                }
            }

            var isEmpty: Bool {
                switch self {
                case .one(let path): return path.isEmpty
                case .many(let commands): return commands.isEmpty
                }
            }
        }

        /// Whether this document describes something `npx -y <name>` can run.
        /// A package with no `latest` release is not one: npm would have nothing
        /// to resolve the command to.
        var isRunnable: Bool {
            guard let latest = distTags?["latest"],
                  let version = versions?[latest]?.value,
                  let bin = version.bin
            else { return false }
            return !bin.isEmpty
        }
    }
}
