import Foundation

/// One image found for a query.
public struct FoundImage: Sendable, Equatable {
    /// How the picture was arrived at, which is not the same as how good it is.
    public enum Source: Sendable, Equatable {
        /// The article for the thing itself. The strongest answer there is.
        case article
        /// The official artwork for the thing itself — what PokéAPI holds for
        /// a creature. The same strength as an article.
        case artwork
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
/// So: a lookup. Seven sources, in the order that gives the best answer rather
/// than the most, and each of them keyless, documented and public:
///
/// 1. **Wikipedia** — for anything with an article. Asked for "Blaziken" it
///    returns the species artwork, which is exactly what a team sheet wants and
///    what a word search over filenames would never find. When it answers, that is
///    the answer: it matched the name, where a search would only have matched
///    the words.
/// 2. **PokéAPI** — for any Pokémon, including the forms and species too new or
///    too obscure for an article. Official artwork straight from the games.
/// 3. **Bulbapedia** — the Pokémon encyclopaedia, gated the same way as
///    Wikipedia: it answers only when its article is *about* the thing asked.
/// 4. **Wikimedia Commons** — free images with their licences attached, for
///    everything else.
/// 5. **Open Library** — book covers.
/// 6. **iTunes** — album artwork.
/// 7. **Openverse** — the open-licensed search, last because it is the broadest
///    and therefore the weakest match.
public enum ImageSearch {
    /// Wikimedia asks for a real User-Agent and refuses requests without one — the
    /// first version of this returned nothing at all from Commons for that reason
    /// alone.
    /// Read from the bundle rather than written down: a user agent pinned to a
    /// released version is wrong from the next release onwards, and Wikimedia asks
    /// for one that identifies the client.
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Bud/\(version ?? "dev") (https://github.com/mriver15/bud)"
    }()

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

    /// The best images for one query, strongest source first.
    private static func lookup(_ query: String, perQuery: Int) async -> [FoundImage] {
        if let cached = cache.value(for: query) { return Array(cached.prefix(perQuery)) }

        // A named answer — an article or official artwork — is the thing itself.
        // Falling through to a search on top of that is how a surface ends up
        // showing a photograph of a person in a costume instead of the creature,
        // so it does not.
        if let article = await wikipedia(query) {
            cache.store([article], for: query)
            return [article]
        }
        if let artwork = await pokeArtwork(query) {
            cache.store([artwork], for: query)
            return [artwork]
        }
        // Bulbapedia's search matches mentions like any search, but the article it
        // reaches is gated the same way as Wikipedia's — so when it answers it is
        // an answer of the same strength, and when it does not the search tier
        // gets the question.
        if let article = await bulbapedia(query) {
            cache.store([article], for: query)
            return [article]
        }

        // Then the searches, best source first. The archive answers first in
        // the list, and the title-exact catalogues fill what it could not: a
        // photograph can answer any query, a cover only answers a book or an
        // album. Merging their files does not dilute the answer — the strongest
        // matches still come first, and every one says what it matched.
        let found = await search(query, perQuery: perQuery)
        cache.store(found, for: query)
        return found
    }

    /// The search tier, run in order until the budget is full: the photo
    /// archive first, then the title-exact catalogues, then the broad open
    /// search last — because the broadest match is the weakest one.
    private static let searchTier: [@Sendable (String, Int) async -> [FoundImage]] = [
        commons,
        openLibrary,
        itunes,
        openverse,
    ]

    private static func search(_ query: String, perQuery: Int) async -> [FoundImage] {
        var found: [FoundImage] = []
        for source in searchTier {
            guard found.count < perQuery else { break }
            found.append(contentsOf: await source(query, perQuery))
        }
        return Array(found.prefix(perQuery))
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

    // MARK: - PokéAPI

    /// The name PokéAPI knows a Pokémon by: words lowercased and joined with
    /// hyphens, which turns "Mr. Mime" into "mr-mime" and "Iron Valiant" into
    /// "iron-valiant".
    static func slug(for query: String) -> String {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }

    /// The official artwork, or nil when the API does not know the name.
    ///
    /// PokéAPI answers an unknown name with a 404, so this is tried for any
    /// query: a miss is one cheap round trip, and a hit is the artwork itself —
    /// the answer a filename search can only hope for. It is what catches the
    /// creatures no encyclopaedia has an article for.
    private static func pokeArtwork(_ query: String) async -> FoundImage? {
        guard var components = URLComponents(string: "https://pokeapi.co/api/v2/pokemon/") else { return nil }
        components.percentEncodedPath += slug(for: query)
        guard let url = components.url else { return nil }
        guard let json = await get(url) else { return nil }
        return artwork(from: json, query: query)
    }

    /// The artwork, read out of a PokéAPI response.
    ///
    /// Split from the request for the same reason the Wikipedia parser is: the
    /// shapes that matter can be checked against a fixture without asking the
    /// API. The official artwork is preferred, then the Pokémon HOME render,
    /// then the game sprite — all of them are the creature itself.
    static func artwork(from json: JSONValue, query: String) -> FoundImage? {
        let sprites = json["sprites"]
        guard let source = sprites?["other"]?["official-artwork"]?["front_default"]?.stringValue
                ?? sprites?["other"]?["home"]?["front_default"]?.stringValue
                ?? sprites?["front_default"]?.stringValue,
              isRaster(source)
        else { return nil }
        let name = json["name"]?.stringValue ?? query
        let species = json["species"]?["name"]?.stringValue ?? name
        return FoundImage(
            query: query,
            source: .artwork,
            url: source,
            title: displayName(name),
            page: speciesPage(species),
            credit: "Pokémon artwork via PokéAPI"
        )
    }

    /// "charizard-mega-x" as a name rather than a slug.
    static func displayName(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    /// The article a Pokémon can be read at: its species' Bulbapedia page,
    /// which exists for every one of them.
    private static func speciesPage(_ slug: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let title = displayName(slug) + " (Pokémon)"
        var components = URLComponents(string: "https://bulbapedia.bulbagarden.net/wiki/")!
        components.percentEncodedPath += title.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return components.url?.absoluteString ?? ""
    }

    // MARK: - Bulbapedia

    /// A Bulbapedia article about the query, with its lead image.
    ///
    /// The File namespace is not searchable there, so this searches the articles
    /// themselves and takes the lead image of the one that is *about* the query —
    /// which for a creature is the artwork, exactly what the page itself shows.
    private static func bulbapedia(_ query: String) async -> FoundImage? {
        guard var components = URLComponents(string: "https://bulbapedia.bulbagarden.net/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "gsrlimit", value: "3"),
            URLQueryItem(name: "prop", value: "pageimages|info"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "640"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }
        guard let json = await get(url) else { return nil }
        return article(fromSearch: json, query: query)
    }

    /// The lead image of the first search hit that is about the query.
    ///
    /// A search matches mentions, so the same gate as Wikipedia applies: the page
    /// reached has to be the thing asked for. Asked for "Garchomp", "Garchomp
    /// (Pokémon)" is the artwork; asked for "sunset over mountains", "Sunset
    /// Colosseum" is a building in a game — the gate refuses it and the search
    /// tier gets the question instead.
    static func article(fromSearch json: JSONValue, query: String) -> FoundImage? {
        guard let pages = json["query"]?["pages"]?.objectValue else { return nil }
        for page in pages.values.sorted(by: { lhs, rhs in
            (lhs["index"]?.doubleValue ?? .greatestFiniteMagnitude)
                < (rhs["index"]?.doubleValue ?? .greatestFiniteMagnitude)
        }) {
            guard isAbout(page, query),
                  let source = page["thumbnail"]?["source"]?.stringValue,
                  isRaster(source),
                  let title = page["title"]?.stringValue
            else { continue }
            return FoundImage(
                query: query,
                source: .article,
                url: tidy(source),
                title: title,
                page: page["fullurl"]?.stringValue ?? page["canonicalurl"]?.stringValue,
                credit: "Bulbapedia"
            )
        }
        return nil
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
            // Screened on the **source file**, not on the address it was served
            // from. Asked for a "Lucario Voice Line.ogg", Commons offers the
            // picture it draws for an audio file — `fileicon-ogg.png` — which is a
            // raster image at a `.png` address and sailed through a check made on
            // the URL. The file is what it is; the address is a delivery detail.
            guard Self.isImageFile(name), Self.isRaster(source) else { return nil }
            // At least one word of the query has to be in the file's own name.
            //
            // Commons matches page *text*, so an uncommon name returns whatever
            // happens to mention it. Asked for "Annihilape" it answered with three
            // photographs of Mankey, including a 1948 baseball player named Tom
            // Mankey and a Second World War enlistment record — none of them named
            // Annihilape, all of them describing one. A match on the name is a
            // match; a match on the prose is a guess.
            guard Self.nameMentions(name, query) else { return nil }
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

    /// Whether the file itself is a picture.
    ///
    /// Separate from `isRaster`, which reads the address. A file called `.ogg` is
    /// not an image however it is served, and Commons serves one the picture it
    /// keeps for audio — which is how an audio file's icon arrived as a candidate
    /// picture for a creature.
    static func isImageFile(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp"].contains { lowered.hasSuffix($0) }
    }

    /// Whether the file's own name contains a word from the query.
    ///
    /// The query's words minus the ones too short or too common to mean anything:
    /// "red panda" is matched by `red` or `panda`, and "sunset over mountains" by
    /// any of its three.
    static func nameMentions(_ name: String, _ query: String) -> Bool {
        let ignored: Set<String> = ["the", "and", "for", "with", "from", "over", "under", "of", "a", "an"]
        let words = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !ignored.contains($0) }
        guard !words.isEmpty else { return true }
        let haystack = name.lowercased()
        return words.contains { haystack.contains($0) }
    }

    /// Wikimedia appends campaign parameters to its own image URLs. They are
    /// harmless and they make a URL twice as long as it needs to be, which matters
    /// when the model has to reproduce it exactly.
    static func tidy(_ url: String) -> String {
        guard let mark = url.firstIndex(of: "?"), url[mark...].contains("utm_") else { return url }
        return String(url[..<mark])
    }

    // MARK: - Open Library

    private static func openLibrary(_ query: String, limit: Int) async -> [FoundImage] {
        guard var components = URLComponents(string: "https://openlibrary.org/search.json") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "key,title,cover_i"),
            URLQueryItem(name: "limit", value: "\(limit + 3)"),
        ]
        guard let url = components.url else { return [] }
        guard let json = await get(url) else { return [] }

        // A cover id that has gone stale answers with a blank placeholder, not a
        // 404 — asked without `default=false` it always renders. So candidates
        // are checked before they are handed out; a placeholder is a broken
        // answer in everything but name.
        var found: [FoundImage] = []
        for candidate in covers(from: json, query: query) {
            guard found.count < limit else { break }
            guard let url = URL(string: candidate.url), await coverExists(url) else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Book covers, read out of an Open Library search response.
    ///
    /// Only covers whose title actually mentions the query: Open Library matches
    /// fuzzily and across languages, so a miss on the words is a book about
    /// something else.
    static func covers(from json: JSONValue, query: String) -> [FoundImage] {
        guard let docs = json["docs"]?.arrayValue else { return [] }
        var seen: Set<Int> = []
        return docs.compactMap { doc -> FoundImage? in
            guard let cover = doc["cover_i"]?.doubleValue, cover > 0,
                  let id = Int(exactly: cover), !seen.contains(id),
                  let title = doc["title"]?.stringValue, !title.isEmpty,
                  nameMentions(title, query),
                  let key = doc["key"]?.stringValue
            else { return nil }
            seen.insert(id)
            return FoundImage(
                query: query,
                url: "https://covers.openlibrary.org/b/id/\(id)-L.jpg",
                title: title,
                page: "https://openlibrary.org" + key,
                credit: "Open Library"
            )
        }
    }

    /// Whether the cover exists: asked with `default=false`, the library answers
    /// 404 instead of the blank placeholder it serves for a dead id.
    private static func coverExists(_ url: URL) async -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = [URLQueryItem(name: "default", value: "false")]
        guard let probe = components.url else { return false }
        var request = URLRequest(url: probe)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return true
    }

    // MARK: - iTunes

    private static func itunes(_ query: String, limit: Int) async -> [FoundImage] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            // Without a country the store answers with the local catalogue,
            // which is not the one the question was asked in.
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "\(limit + 3)"),
        ]
        guard let url = components.url else { return [] }
        guard let json = await get(url) else { return [] }
        return artwork(fromSearch: json, query: query, limit: limit)
    }

    /// Album artwork, read out of an iTunes search response, one per album.
    ///
    /// The same gate as the other searches: an album whose name does not share a
    /// word with the query is a hit on the prose, not the thing.
    static func artwork(fromSearch json: JSONValue, query: String, limit: Int) -> [FoundImage] {
        guard let results = json["results"]?.arrayValue else { return [] }
        var found: [FoundImage] = []
        var seen: Set<String> = []
        for result in results {
            guard found.count < limit else { break }
            guard let title = result["collectionName"]?.stringValue, !title.isEmpty,
                  nameMentions(title, query),
                  let raw = result["artworkUrl100"]?.stringValue,
                  !seen.contains(artworkKey(raw))
            else { continue }
            seen.insert(artworkKey(raw))
            found.append(FoundImage(
                query: query,
                url: enlarge(raw),
                title: title,
                page: result["collectionViewUrl"]?.stringValue,
                credit: "iTunes"
            ))
        }
        return found
    }

    /// The identity of an artwork behind its address: the file the store
    /// serves, which is the same across re-releases even when the hash
    /// directories differ. Two pressings of one album are one picture.
    static func artworkKey(_ url: String) -> String {
        var trimmed = url
        if let mark = trimmed.lastIndex(of: "/") {
            trimmed = String(trimmed[..<mark])
        }
        return trimmed.components(separatedBy: "/").last ?? trimmed
    }

    /// The 600-pixel version of an iTunes artwork address: the store serves any
    /// size by substituting it in the path, and a 100-pixel cover at card size
    /// is a smear.
    static func enlarge(_ url: String) -> String {
        url.replacingOccurrences(of: "100x100", with: "600x600")
    }

    // MARK: - Openverse

    private static func openverse(_ query: String, limit: Int) async -> [FoundImage] {
        guard var components = URLComponents(string: "https://api.openverse.org/v1/images/") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page_size", value: "\(limit + 3)"),
            URLQueryItem(name: "mature", value: "false"),
        ]
        guard let url = components.url else { return [] }
        guard let json = await get(url) else { return [] }
        return images(fromSearch: json, query: query, limit: limit)
    }

    /// The images, read out of an Openverse search response, best first.
    ///
    /// Ranked by the search itself, so no name gate here: Openverse is a real
    /// search engine, not a prose match. The picture still has to be a raster
    /// file, and every result carries its licence.
    static func images(fromSearch json: JSONValue, query: String, limit: Int) -> [FoundImage] {
        guard let results = json["results"]?.arrayValue else { return [] }
        var seen: Set<String> = []
        return results.compactMap { result -> FoundImage? in
            guard let url = result["url"]?.stringValue, isRaster(url), !seen.contains(url) else { return nil }
            seen.insert(url)
            return FoundImage(
                query: query,
                url: url,
                title: result["title"]?.stringValue ?? "",
                page: result["foreign_landing_url"]?.stringValue,
                credit: license(from: result)
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    /// The licence in words rather than an API code: "by-nd" is CC BY-ND.
    static func license(from result: JSONValue) -> String? {
        let code = result["license"]?.stringValue?.lowercased() ?? ""
        let readable = [
            "cc0": "CC0", "pdm": "Public Domain Mark",
            "by": "CC BY", "by-sa": "CC BY-SA", "by-nc": "CC BY-NC", "by-nd": "CC BY-ND",
            "by-nc-sa": "CC BY-NC-SA", "by-nc-nd": "CC BY-NC-ND",
        ]
        if let name = readable[code] { return name }
        return code.isEmpty ? nil : code
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
