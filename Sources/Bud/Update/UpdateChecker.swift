import Foundation

/// What a check found.
public enum UpdateCheckResult: Sendable {
    case upToDate(current: BudVersion)
    /// - Parameter downloadURL: an authenticated route to the archive, when the
    ///   signed URL cannot be fetched directly. A private repository's
    ///   `browser_download_url` answers 404 to everyone, token or not — it is a
    ///   URL for a browser session, not for an API client — so the bytes have to
    ///   come from the asset API instead. The signed `url` and `sha256` still
    ///   decide what is accepted; this only decides what is fetched.
    case available(manifest: UpdateManifest, downloadURL: URL?)
}

/// Fetches a feed and decides whether it offers something worth installing.
///
/// The order of operations is the whole design: the signature is checked before
/// any other field is read, because until it verifies, every other field is
/// attacker-controlled text.
public enum UpdateChecker {
    public static func check(
        feed: UpdateFeed,
        current: BudVersion,
        session: URLSession = .shared
    ) async throws -> UpdateCheckResult {
        let fetched = try await fetch(feed: feed, session: session)
        do {
            try validate(fetched.manifest, feed: feed, current: current)
        } catch UpdateError.notNewer {
            // The ordinary answer to "is there an update?", and the answer every
            // time the user is already on the newest release. Reported as a
            // failure it would put an error in front of someone for the crime of
            // being current — which is exactly what running the latest build
            // looks like.
            //
            // The gate itself stays in `validate`, where it still refuses to
            // install anything that is not strictly newer. Refusing to install
            // and refusing to answer are different things.
            return .upToDate(current: current)
        }
        return .available(manifest: fetched.manifest, downloadURL: fetched.downloadURL)
    }

    /// Every gate between a fetched manifest and an install.
    ///
    /// Split out from the network work so each rule can be exercised on its own;
    /// a check that can only be tested by serving a real feed is a check that
    /// stops being tested.
    public static func validate(
        _ manifest: UpdateManifest,
        feed: UpdateFeed,
        current: BudVersion,
        runningOS: String = UpdateChecker.runningOS()
    ) throws {
        // First, and deliberately so. Everything below reads a field that is
        // only trustworthy once this passes.
        try UpdateSignature.verify(manifest, publicKey: feed.publicKey)

        guard manifest.schema == UpdateManifest.supportedSchema else {
            throw UpdateError.unsupportedSchema(manifest.schema)
        }
        // A stable user must not be handed a prerelease, but a prerelease user
        // taking a stable build is just an upgrade out of the channel.
        if feed.channel != "prerelease", manifest.channel != feed.channel {
            throw UpdateError.channelMismatch(expected: feed.channel, offered: manifest.channel)
        }
        guard osAtLeast(manifest.minOS, running: runningOS) else {
            throw UpdateError.unsupportedOS(required: manifest.minOS, running: runningOS)
        }
        // Refusing to move sideways or backwards is what stops a replayed — or
        // simply stale — manifest from reinstalling an older build over a newer
        // one, which is a downgrade an attacker would otherwise get for free.
        guard manifest.versionValue.isNewer(than: current) else {
            throw UpdateError.notNewer(current: current.display, offered: manifest.versionValue.display)
        }
        try validateDownloadURL(manifest.url)
    }

    /// A manifest may only point the download at somewhere Bud already trusts.
    ///
    /// The signature proves the URL came from the key holder, so this is not the
    /// primary defence. It is what bounds the damage if that key ever leaks: one
    /// stolen key should not turn every install into a downloader for an
    /// arbitrary host.
    public static func validateDownloadURL(_ raw: String) throws {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { throw UpdateError.insecureURL(raw) }

        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        // Plain HTTP is allowed only to the machine itself, so the update path
        // can be exercised against a local feed. It is not a hole: an attacker
        // who controls the manifest can only make the victim fetch from the
        // victim's own loopback.
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw UpdateError.insecureURL(raw)
        }
        guard UpdateManifest.allowedDownloadHosts.contains(host) else {
            throw UpdateError.hostNotAllowed(host)
        }
    }

    // MARK: Fetching

    /// A manifest, plus an authenticated route to its archive when there is one.
    private struct Fetched {
        var manifest: UpdateManifest
        var downloadURL: URL?
    }

    private static func fetch(feed: UpdateFeed, session: URLSession) async throws -> Fetched {
        let bytes: Data
        var downloadURL: URL?

        if feed.usesGitHubReleasesAPI {
            let release = try await fetchFromGitHubReleases(feed: feed, session: session)
            bytes = release.manifestBytes
            downloadURL = release.downloadURL
        } else {
            guard let url = URL(string: feed.manifestURL) else {
                throw UpdateError.malformedManifest("the feed URL is not a valid URL: \(feed.manifestURL)")
            }
            bytes = try await get(url, token: nil, session: session).data
        }

        do {
            return Fetched(
                manifest: try JSONDecoder().decode(UpdateManifest.self, from: bytes),
                downloadURL: downloadURL
            )
        } catch {
            throw UpdateError.malformedManifest(error.localizedDescription)
        }
    }

    private struct ReleaseFetch {
        var manifestBytes: Data
        /// The archive, addressed through the API, when that is the only route
        /// that works. Nil for a public repository, where the signed URL is fine.
        var downloadURL: URL?
    }

    /// Finds the newest matching release, pulls its `appcast.json`, and works out
    /// how the archive will actually be fetched.
    ///
    /// Asset URLs cannot be constructed from the tag — GitHub generates the path
    /// and it changes with each upload — so they have to be discovered.
    private static func fetchFromGitHubReleases(feed: UpdateFeed, session: URLSession) async throws -> ReleaseFetch {
        let token = feed.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://api.github.com/repos/\(feed.repo)/releases?per_page=20") else {
            throw UpdateError.malformedManifest("the repository \(feed.repo) is not a valid owner/name pair")
        }

        let response = try await get(url, token: token.isEmpty ? nil : token, session: session)
        guard let releases = try? JSONDecoder().decode(JSONValue.self, from: response.data).arrayValue else {
            throw UpdateError.malformedManifest("GitHub did not return a list of releases")
        }

        for release in releases {
            guard let object = release.objectValue else { continue }
            // Drafts are not published; a stable channel never takes a
            // prerelease, and GitHub marks those explicitly.
            if object["draft"]?.boolValue == true { continue }
            if feed.channel != "prerelease", object["prerelease"]?.boolValue == true { continue }

            let assets = object["assets"]?.arrayValue ?? []
            guard let appcast = assets.first(where: { $0.objectValue?["name"]?.stringValue == "appcast.json" }),
                  let asset = appcast.objectValue
            else { continue }

            let bytes: Data
            if !token.isEmpty,
               let apiURL = asset["url"]?.stringValue,
               let endpoint = URL(string: apiURL) {
                bytes = try await get(endpoint, token: token, accept: "application/octet-stream", session: session).data
            } else if let browserURL = asset["browser_download_url"]?.stringValue,
                      let endpoint = URL(string: browserURL) {
                bytes = try await get(endpoint, token: token.isEmpty ? nil : token, session: session).data
            } else {
                continue
            }

            // The archive is addressed the same way as the manifest, and for the
            // same reason: a private repository's browser_download_url answers 404
            // to an API client whether or not it carries a token. That was worth
            // discovering against a real private release rather than a stub.
            var archive: URL?
            if !token.isEmpty,
               let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: bytes),
               let wanted = URL(string: manifest.url)?.lastPathComponent,
               let match = assets.first(where: { $0.objectValue?["name"]?.stringValue == wanted }),
               let assetURL = match.objectValue?["url"]?.stringValue {
                archive = URL(string: assetURL)
            }

            return ReleaseFetch(manifestBytes: bytes, downloadURL: archive)
        }

        throw UpdateError.malformedManifest("no \(feed.channel) release of \(feed.repo) carries an appcast.json asset")
    }

    @discardableResult
    static func get(
        _ url: URL,
        token: String?,
        accept: String? = nil,
        session: URLSession
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bud", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Never from cache. A cached manifest means a user who checks after a
        // release is told they are up to date, and goes on being told that until
        // the cache happens to expire — the one failure an updater must not have.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.downloadFailed("no HTTP response from \(url.host() ?? "the feed")")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateError.downloadFailed("HTTP \(http.statusCode) from \(url.host() ?? "the feed")\(snippet(data))")
            }
            return (data, http)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
    }

    private static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : ": \(text)"
    }

    // MARK: Platform

    public static func runningOS() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Component-wise, so `26.10` is not judged older than `26.9` the way a
    /// string comparison would judge it.
    public static func osAtLeast(_ required: String, running: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let want = parts(required)
        let have = parts(running)
        for index in 0..<max(want.count, have.count) {
            let lhs = index < want.count ? want[index] : 0
            let rhs = index < have.count ? have[index] : 0
            if lhs != rhs { return rhs > lhs }
        }
        return true
    }
}
