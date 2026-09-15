import Foundation

/// What a backend needs to reach a provider.
///
/// Separate from `BudConfig` on purpose: config is the user's stored settings for
/// *every* provider, this is the resolved credential for the one request in hand.
/// Backends should not know how settings are persisted.
public struct ProviderCredentials: Sendable, Hashable {
    public var apiKey: String
    /// Overrides the descriptor's base URL. This is what makes the custom entry
    /// work — an endpoint Bud has never heard of needs nothing else.
    public var baseURL: String?
    /// Extra headers some gateways require (OpenRouter's attribution headers,
    /// for instance).
    public var extraHeaders: [String: String]

    public init(
        apiKey: String = "",
        baseURL: String? = nil,
        extraHeaders: [String: String] = [:]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
    }

    /// The base URL to actually use: the override when present, otherwise the
    /// provider's own.
    public func resolvedBaseURL(for provider: ProviderDescriptor) -> String {
        let override = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? provider.baseURL : override
    }
}

/// Builds the backend for a provider.
///
/// The single place that maps a wire format onto an implementation, so adding a
/// dialect is one case here rather than a change everywhere.
public enum ProviderBackendFactory {
    public static func make(
        provider: ProviderDescriptor,
        credentials: ProviderCredentials
    ) -> any ChatBackend {
        switch provider.wireFormat {
        case .openAICompatible:
            return OpenAICompatibleBackend(provider: provider, credentials: credentials)
        case .anthropicMessages:
            return AnthropicMessagesBackend(provider: provider, credentials: credentials)
        case .googleGenerativeAI:
            return GoogleGenerativeAIBackend(provider: provider, credentials: credentials)
        }
    }
}

/// Shared request plumbing for the non-OpenAI dialects.
///
/// The OpenAI client has its own session and error handling because it was
/// written first; new dialects share these so three copies of the same timeout
/// policy and error-body draining do not drift apart.
enum ProviderHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // An inactivity timer, not a total budget: a long generation that keeps
        // emitting deltas stays alive, and only a genuinely dead socket trips it.
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 1800
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// Drains a bounded amount of a non-2xx body, so a huge HTML error page
    /// cannot be slurped into memory or into the transcript.
    static func errorBody(_ bytes: URLSession.AsyncBytes, limit: Int = 8192) async -> String {
        var collected = Data()
        do {
            for try await byte in bytes {
                collected.append(byte)
                if collected.count >= limit { break }
            }
        } catch {
            // A body that dies mid-read still tells us more than nothing.
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    /// Percent-encodes a path component. Model ids contain `/` and `:` — Google's
    /// are `models/gemini-2.5-pro` — and must not break the URL structure.
    static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
