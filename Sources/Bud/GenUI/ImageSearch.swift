import Foundation

/// One image found for a query.
public struct FoundImage: Sendable, Equatable {
    /// How the picture was arrived at, which is not the same as how good it is.
    public enum Source: Sendable, Equatable {
        /// The article for the thing itself. The strongest answer there is.
        case article
        /// A file whose name matches the words. Often right, and sometimes a
        /// cosplay photograph: "Rotom" reaches this, and so does "red panda".
        case search
    }

    public var query: String
    /// Where it came from, so a caller can weigh it.
    public var source: Source = .search
    public var url: String
    /// The article or file it came from.
    public var title: String
    /// The page it can be credited or read at.
    public var page: String?
    /// The licence, when the source states one.
    public var credit: String?
}

/// Looking up a picture for something.
///
/// There was no way to put an image in a generated surface unless something else
/// had already produced one. A surface showing a team could name the six, lay them
/// out, and show nothing — and the answer to that cannot be "write an MCP server
/// that returns sprites", because the same gap appears for a bird, a city, a
/// product or a diagram.
///
/// So: a lookup. Two keyless sources, in the order that gives the best answer
/// rather than the most:
///
/// 1. **Wikipedia** — for anything with an article. Asked for "Blaziken" it
///    returns the species artwork, which is exactly what a team sheet wants and
///    what a word search over filenames would never find. When it answers, that is
///    the answer: it matched the name, where the fallback would only have matched
///    the words.
/// 2. **Wikimedia Commons** — for everything else. Free images with their
///    licences attached.
///
/// Both are Wikimedia, which means no key, no account, and a documented API that
/// is not going to close on a whim.
public enum ImageSearch {
    /// Wikimedia asks for a real User-Agent and refuses requests without one — the
    /// first version of this returned nothing at all from Commons for that reason
    /// alone.
    private static let userAgent = "Bud/0.3.2 (https://github.com/mriver15/bud)"

    /// One call for a whole set. Six creatures is six lookups, and six round trips
    /// to draw one card is how a feature goes unused.
    public static let batchLimit = 8

    /// Findings are cached, because a surface is rebuilt on every streamed delta
    /// and a search repeated sixty times a second would be a small denial of
    /// service aimed at Wikimedia.
    private static let cache = Cache()

    public static func find(_ queries: [String], perQuery: Int = 3) async -> [FoundImage] {
        let wanted = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, query in
                if !unique.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
                    unique.append(query)
                }
            }
            .prefix(batchLimit)

        return await withTaskGroup(of: (Int, [FoundImage]).self) { group in
            for (index, query) in wanted.enumerated() {
                group.addTask { (index, await lookup(query, perQuery: perQuery)) }
            }
            var collected: [(Int, [FoundImage])] = []
            for await result in group { collected.append(result) }
            // Answered in the order asked, so a team comes back as a team.
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    /// The best images for one query, article first.
    private static func lookup(_ query: String, perQuery: Int) async -> [FoundImage] {
        if let cached = cache.value(for: query) { return Array(cached.prefix(perQuery)) }

        // An article answers for the thing itself. Falling through to a filename
        // search on top of that is how a surface ends up showing a photograph of a
        // person in a costume instead of the creature, so it does not.
        if let article = await wikipedia(query) {
            cache.store([article], for: query)
            return [article]
        }

        let found = await commons(query, limit: perQuery)
        cache.store(found, for: query)
        return found
    }

    // MARK: - Wikipedia

    /// The article's own lead image.
    ///
    /// A title lookup rather than a search: the question being asked is "what does
    /// this look like", and an encyclopaedia answers that for a named thing far
    /// better than a filename search does.
    private static func wikipedia(_ query: String) async -> FoundImage? {
        let title = query.replacingOccurrences(of: " ", with: "_")
        // Built rather than interpolated: `URL(string:)` re-encodes an already
        // encoded `%`, so a title with a space in it was being asked for as the
        // literal text "sunset%20over%20mountains" and coming back empty.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        guard var components = URLComponents(string: "https://en.wikipedia.org/api/rest_v1/page/summary/"),
              let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        components.percentEncodedPath += encoded
        guard let url = components.url else { return nil }

        guard let json = await get(url) else { return nil }
        return article(from: json, query: query)
    }

    /// The article's lead image, read out of a summary response.
    ///
    /// Split from the request so it can be checked against a response without
    /// asking Wikipedia for one — the shapes that matter here are the ones it
    /// returns for a title that is not an article.
    static func article(from json: JSONValue, query: String) -> FoundImage? {
        // A disambiguation page has no lead image worth having, and the summary
        // endpoint answers a title it does not know with a type rather than a 404:
        // a phrase like "sunset over mountains" comes back as `Internal error`.
        guard json["type"]?.stringValue == "standard",
              let image = json["originalimage"]?["source"]?.stringValue
                  ?? json["thumbnail"]?["source"]?.stringValue
        else { return nil }

        guard isAbout(json, query) else { return nil }

        return FoundImage(
            query: query,
            source: .article,
            url: tidy(image),
            title: json["title"]?.stringValue ?? query,
            page: json["content_urls"]?["desktop"]?["page"]?.stringValue,
            // The summary endpoint does not report a licence, and guessing one
            // would be worse than saying where it came from.
            credit: "Wikipedia"
        )
    }

    /// Whether the article reached is about the thing that was asked for.
    ///
    /// The summary endpoint follows redirects and does not say that it did. Asked
    /// for "Rotom" it answers with "List of generation IV Pokémon", whose lead image
    /// is the generic Pokémon logo: a standard page, a real picture, and an answer
    /// to a question nobody asked. Rendered as a team, four of six creatures came
    /// back as that same logo.
    ///
    /// So the resolved title has to be the one asked for. A parenthetical is allowed
    /// — "Rotom (Pokémon)" is still Rotom — but a different subject is not, because
    /// a surface showing the wrong picture is worse than one showing none. A
    /// response that does not state a resolved title is taken at its word.
    static func isAbout(_ json: JSONValue, _ query: String) -> Bool {
        guard let resolved = json["titles"]?["canonical"]?.stringValue
                ?? json["title"]?.stringValue
        else { return true }
        let asked = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        let reached = resolved.replacingOccurrences(of: " ", with: "_").lowercased()
        return reached == asked || reached.hasPrefix(asked + "_(")
    }

    // MARK: - Commons

    private static func commons(_ query: String, limit: Int) async -> [FoundImage] {
        // Composed with URLComponents for the same reason: it encodes a query
        // value once, correctly, and leaves it alone.
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "\(limit + 3)"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "640"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }

        guard let json = await get(url) else { return [] }
        return images(from: json, query: query)
    }

    /// The file results, read out of a Commons search response, best first.
    ///
    /// `pages` is a JSON object and objects have no order, so reading it as one
    /// gives the results in whatever order the dictionary feels like — which makes
    /// "the first one" arbitrary, and the first one is the one a model uses. The
    /// response carries the search rank on each page; that is the order.
    static func images(from json: JSONValue, query: String) -> [FoundImage] {
        guard let pages = json["query"]?["pages"]?.objectValue else { return [] }
        return pages.values
            .sorted { lhs, rhs in
                (lhs["index"]?.doubleValue ?? .greatestFiniteMagnitude)
                    < (rhs["index"]?.doubleValue ?? .greatestFiniteMagnitude)
            }
            .compactMap { page -> FoundImage? in
            guard let info = page["imageinfo"]?.arrayValue?.first,
                  let file = page["title"]?.stringValue
            else { return nil }
            // A thumbnail rather than the original: a 4000-pixel photograph is
            // megabytes to draw a 96-point tile, and the original is not better.
            guard let source = info["thumburl"]?.stringValue ?? info["url"]?.stringValue else { return nil }
            let name = file.replacingOccurrences(of: "File:", with: "")
            // SVG is left out: it is not something every image loader will decode,
            // and a tile that silently fails is worse than the next result.
            guard Self.isRaster(source) else { return nil }
            return FoundImage(
                query: query,
                url: tidy(source),
                title: name,
                page: info["descriptionurl"]?.stringValue,
                credit: info["extmetadata"]?["LicenseShortName"]?["value"]?.stringValue
                    ?? info["extmetadata"]?["License"]?["value"]?.stringValue
            )
        }
    }

    static func isRaster(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp"].contains { lowered.contains($0) }
    }

    /// Wikimedia appends campaign parameters to its own image URLs. They are
    /// harmless and they make a URL twice as long as it needs to be, which matters
    /// when the model has to reproduce it exactly.
    static func tidy(_ url: String) -> String {
        guard let mark = url.firstIndex(of: "?"), url[mark...].contains("utm_") else { return url }
        return String(url[..<mark])
    }

    // MARK: - Plumbing

    private static func get(_ url: URL) async -> JSONValue? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              // A guard against something that is not the API answering with 200.
              data.count < 4_000_000
        else { return nil }
        return JSONValue(parsing: String(decoding: data, as: UTF8.self))
    }

    /// Guarded, and small. `find` is called from a view's render path as well as
    /// from a tool, and an unguarded dictionary shared between those is a crash
    /// waiting for the right timing.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [FoundImage]] = [:]
        private var order: [String] = []
        private let limit = 120

        func value(for query: String) -> [FoundImage]? {
            lock.withLock { entries[query.lowercased()] }
        }

        func store(_ images: [FoundImage], for query: String) {
            lock.withLock {
                let key = query.lowercased()
                if entries[key] == nil { order.append(key) }
                entries[key] = images
                while order.count > limit {
                    entries.removeValue(forKey: order.removeFirst())
                }
            }
        }
    }
}
