import Foundation

/// The list of models Bud offers for a provider, folded from three sources: the
/// models Bud ships knowing about (`knownModels`), the models the provider lists
/// over its own `/models` endpoint, and the provider's suggested default.
///
/// The fetch is what makes the picker useful — OpenAI-compatible providers can
/// list hundreds of models — but it must never be the difference between a
/// working picker and an empty one, so every failure degrades to the curated
/// list rather than to nothing.
public enum ModelCatalog {
    /// A stalled `/models` call must not keep the picker waiting; 10s is enough
    /// for a cold TLS handshake on a slow link.
    static let timeout: TimeInterval = 10

    /// Cached merged lists, keyed by provider id.
    ///
    /// In-memory is enough: a provider's catalogue changes rarely, and the cache
    /// only has to span a single process. Reopening Settings within one session —
    /// the exact case the cache exists for — skips the fetch, while a fresh
    /// launch refetches, which is the natural cadence for a catalogue that may
    /// have grown since.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: [String]] = [:]

    /// The models offered for a provider, in display order.
    ///
    /// Fetched only for OpenAI-compatible providers that have a key; every other
    /// case — or any failure at all — falls back to the curated list. The caller
    /// adds the currently configured model when it is not already present.
    public static func models(for provider: ProviderDescriptor, key: String) async -> [String] {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let canFetch = provider.wireFormat == .openAICompatible && !trimmedKey.isEmpty

        // Only a fetch is worth caching; the no-key path is already instant.
        if canFetch, let cached = cacheLock.withLock({ cache[provider.id] }) {
            return cached
        }

        var fetched: [String] = []
        if canFetch {
            fetched = await fetchModels(baseURL: provider.baseURL, key: trimmedKey)
        }

        let merged = merge(curated: provider.knownModels, fetched: fetched, defaultModel: provider.defaultModel)
        if canFetch {
            cacheLock.withLock { cache[provider.id] = merged }
        }
        return merged
    }

    /// Curated + default, the list shown before the fetch lands.
    static func curated(_ provider: ProviderDescriptor) -> [String] {
        merge(curated: provider.knownModels, fetched: [], defaultModel: provider.defaultModel)
    }

    /// Curated + fetched + default, de-duplicated, order preserved.
    static func merge(curated: [String], fetched: [String], defaultModel: String?) -> [String] {
        let defaults = defaultModel.map { [$0] } ?? []
        var seen = Set<String>()
        var result: [String] = []
        for candidate in curated + fetched + defaults {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Parses the standard `{"data":[{"id":…}]}` shape, ignoring entries that
    /// lack an id.
    public static func parseModelList(_ json: JSONValue) -> [String] {
        guard let entries = json["data"]?.arrayValue else { return [] }
        return entries.compactMap { entry in
            entry["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    // MARK: - Transport

    /// Fetches the provider's own model list. Any failure returns `[]`, so the
    /// caller's merged result degrades to the curated list rather than failing.
    private static func fetchModels(baseURL: String, key: String) async -> [String] {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: base)?.appendingPathComponent("models") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            data = body
        } catch {
            return []
        }

        guard let json = JSONValue(parsing: String(decoding: data, as: UTF8.self)) else { return [] }
        return parseModelList(json)
    }
}
