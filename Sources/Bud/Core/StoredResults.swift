import Foundation

/// Results too big to send, kept where they can still be read.
///
/// A tool result over the model-facing limit was truncated and the rest was gone:
/// a Wikipedia page fetched at 183,739 characters reached the model as its first
/// 24,000, and nothing could get at the other 87%. The user could still see it in
/// the transcript, which is not the same as the model being able to answer from it.
///
/// So the whole thing is written down and the model is handed a handle. That is not
/// a saving — the head still costs what it always did — and it is not meant to be:
/// it is the difference between a result being *read* and a result being *lost*.
///
/// **No index and no embeddings.** A vector index would need an embedding provider,
/// and the one this app talks to has no such endpoint; the content is mostly
/// structured data from MCP servers, where matching a pattern exactly beats
/// matching it approximately. What is here is a file and a search, which is what
/// the data actually calls for.
public enum StoredResults {
    /// `store_` and eight hex characters. Validated on the way back in, which is
    /// the only thing standing between a handle and a path.
    private static let prefix = "store_"
    private static let handleLength = 8

    /// Beyond this the stored copy is itself cut, and says so. A runaway command
    /// writing a gigabyte should not fill a disk to keep a conversation honest.
    public static let maxStoredBytes = 20_000_000

    /// How many are kept. Old ones are pruned by age, because a handle the model
    /// still holds has to keep working for as long as the conversation that
    /// produced it, and conversations are not long-lived here.
    public static let keep = 40

    /// Pointed elsewhere by the command-line modes, which write results of their
    /// own and have no business leaving them in the store a person reads. The same
    /// redirect the database takes, for the same reason.
    nonisolated(unsafe) public static var overrideDirectory: URL?

    public static var directory: URL {
        overrideDirectory ?? BudConfigLoader.budDirectory.appendingPathComponent("store", isDirectory: true)
    }

    // MARK: - Writing

    /// Writes `text` and returns the handle to read it back by, or nil when it
    /// could not be written — in which case the caller truncates, as before.
    @discardableResult
    public static func store(_ text: String) -> String? {
        // A spilled result is where a `run_shell env` or a large `read_file` ends
        // up, so the directory and the file are both kept to their owner.
        BudConfigLoader.createOwnerOnlyDirectory(directory)

        var body = text
        if let data = body.data(using: .utf8), data.count > maxStoredBytes {
            // Cut on a character boundary rather than a byte one, so the stored
            // copy is still valid UTF-8 and still searchable.
            let allowed = maxStoredBytes / 4
            body = String(text.prefix(allowed))
                + "\n\n…[the rest of this result was too large to keep — \(text.count - allowed) "
                + "characters discarded]"
        }

        let handle = prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(handleLength)).lowercased()
        do {
            try BudConfigLoader.writeOwnerOnly(Data(body.utf8), to: url(for: handle))
        } catch {
            return nil
        }
        prune()
        return handle
    }

    // MARK: - Reading

    /// Whether a string is shaped like a handle this store could have issued.
    ///
    /// Strict, and that is the point: a handle arrives from a model, is turned into
    /// a path, and anything less than an exact match on `store_` plus eight hex
    /// characters is how `store_../../.ssh/id_rsa` becomes a file read.
    public static func isHandle(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix(prefix) else { return false }
        let body = trimmed.dropFirst(prefix.count)
        return body.count == handleLength && body.allSatisfy(\.isHexDigit)
    }

    public static func url(for handle: String) -> URL {
        directory.appendingPathComponent("\(handle).txt")
    }

    public static func read(handle: String) -> String? {
        guard isHandle(handle) else { return nil }
        return try? String(contentsOf: url(for: handle.lowercased()), encoding: .utf8)
    }

    /// Lines containing `pattern`, with their numbers, as `search_files` reports
    /// them — the same shape the model already knows how to read.
    ///
    /// A stored result is one text, so its file and line are just a line.
    public static func search(handle: String, pattern: String, limit: Int) -> [String] {
        guard let text = read(handle: handle) else { return [] }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        var found: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if found.count >= limit { break }
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            guard expression.firstMatch(in: string, range: range) != nil else { continue }
            let clipped = string.count > 220 ? String(string.prefix(220)) + "…" : string
            found.append("\(index + 1): \(clipped.trimmingCharacters(in: .whitespaces))")
        }
        return found
    }

    /// A line range, 1-based and inclusive.
    public static func lines(handle: String, from: Int, to: Int) -> [String] {
        guard let text = read(handle: handle) else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(1, from)
        let end = min(all.count, max(start, to))
        guard start <= all.count else { return [] }
        return (start...end).map { "\($0): \(all[$0 - 1])" }
    }

    public static func lineCount(handle: String) -> Int {
        guard let text = read(handle: handle) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: - Sweeping

    /// Keeps the newest `keep`, by modification date. Not a cache with a policy:
    /// a conversation's handles stop being asked for when the conversation ends,
    /// and there is no signal for that beyond time.
    private static func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = entries.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        for stale in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: - What the model is handed

    /// The model-facing text for a result: the head of it, and the handle for the
    /// rest.
    ///
    /// Below the limit this is the text itself and nothing has changed. Above it,
    /// the old behaviour kept the head and said how much had been thrown away;
    /// this keeps the head and says where the rest went. The head is not shortened
    /// — that would be a different change with a different trade, and making it
    /// safe to shorten is exactly what having the handle now allows.
    public static func modelFacing(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }

        let head = String(text.prefix(limit))
        let rest = text.count - limit
        guard let handle = store(text) else {
            // Nothing was written, so nothing can be promised.
            return head + "\n\n…[truncated \(rest) characters]"
        }
        return head
            + "\n\n…[\(BudFormat.count(rest)) more characters, stored as \(handle). "
            + "Use read_stored with this handle to search it or read a line range.]"
    }
}
