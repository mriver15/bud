import CryptoKit
import Foundation

/// The version of an app bundle.
///
/// Ordering is on `build`, and that is the point of the type. Refusing a
/// downgrade requires being able to order two releases, and ordering arbitrary
/// vendor version strings has no correct general answer — "1.10.0" sorts before
/// "1.9.0" as text. A monotonic integer does not have that problem, so the
/// display string is only consulted when two releases genuinely share a build.
public struct BudVersion: Sendable, Hashable {
    /// The public version, `CFBundleShortVersionString`.
    public let version: String
    /// The monotonic build number, `CFBundleVersion`.
    public let build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    /// The running app's own version, read from its bundle.
    ///
    /// Returns nil rather than guessing when the bundle has no readable version:
    /// an updater that does not know what it is running cannot decide whether a
    /// candidate is newer, and assuming would be the difference between
    /// installing an update and reinstalling the same build for ever.
    public static func current(bundle: Bundle = .main) -> BudVersion? {
        guard let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let raw = bundle.infoDictionary?["CFBundleVersion"] as? String,
              let build = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return BudVersion(version: short, build: build)
    }

    public func isNewer(than other: BudVersion) -> Bool {
        if build != other.build { return build > other.build }
        return version.compare(other.version, options: .numeric) == .orderedDescending
    }

    public var display: String { "\(version) · build \(build)" }
}

/// One published release, as described by the signed `appcast.json`.
///
/// Everything that decides whether code gets installed is covered by the
/// signature. `notes` is outside the signed byte range as text, but its hash is
/// inside it, so the wording the user is shown cannot be rewritten in flight.
public struct UpdateManifest: Sendable, Hashable, Decodable {
    /// Rejected rather than ignored when unrecognised: a newer schema may mean
    /// fields this build would silently disregard, and silently disregarding a
    /// security-relevant field is how an updater gets owned.
    public static let supportedSchema = 1

    public let schema: Int
    public let channel: String
    public let version: String
    public let build: Int
    public let minOS: String
    public let published: String?
    public let notes: String
    public let url: String
    public let size: Int
    public let sha256: String
    public let signature: String

    public init(
        schema: Int = UpdateManifest.supportedSchema,
        channel: String,
        version: String,
        build: Int,
        minOS: String,
        published: String? = nil,
        notes: String,
        url: String,
        size: Int,
        sha256: String,
        signature: String
    ) {
        self.schema = schema
        self.channel = channel
        self.version = version
        self.build = build
        self.minOS = minOS
        self.published = published
        self.notes = notes
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.signature = signature
    }

    public var versionValue: BudVersion { BudVersion(version: version, build: build) }

    /// The exact bytes the signature covers.
    ///
    /// Deliberately a flat, line-oriented string rather than the JSON document.
    /// Signing re-encoded JSON would require the signer and the verifier to agree
    /// on key order, whitespace, number formatting *and* Unicode escaping — four
    /// independent ways to produce a signature that is valid but does not verify,
    /// which is a class of bug that only shows up in production. A fixed field
    /// list has exactly one representation.
    public var signingPayload: String {
        [
            "bud-update-v1",
            "build=\(build)",
            "version=\(version)",
            "channel=\(channel)",
            "minOS=\(minOS)",
            "url=\(url)",
            "size=\(size)",
            "sha256=\(sha256.lowercased())",
            "notes_sha256=\(UpdateSignature.hexDigest(of: notes))",
        ].joined(separator: "\n")
    }

    /// The hosts a manifest may point the download at.
    ///
    /// Not the primary defence — the signature already proves the URL came from
    /// whoever holds the signing key — but it bounds what a leaked key is worth.
    /// Without it, one stolen key turns every install into a downloader for an
    /// arbitrary host.
    ///
    /// Loopback is included so the update path can be exercised end to end
    /// against a local feed. It is not a hole: a manifest aimed at 127.0.0.1
    /// makes the victim download from the victim's own machine.
    public static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "raw.githubusercontent.com",
        "localhost",
        "127.0.0.1",
        "::1",
    ]
}

/// Signature checking, kept separate from everything that touches the network so
/// it can be tested — and reasoned about — on its own.
public enum UpdateSignature {
    public static func hexDigest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies a manifest against a base64 Ed25519 public key.
    ///
    /// An absent key is a refusal, not a skip. A build with no key configured
    /// cannot tell a genuine manifest from a forged one, and installing without
    /// a signature check is strictly worse than not updating at all.
    public static func verify(_ manifest: UpdateManifest, publicKey: String) throws {
        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UpdateError.signingKeyMissing }
        guard let keyBytes = Data(base64Encoded: trimmed), keyBytes.count == 32 else {
            throw UpdateError.signingKeyMalformed
        }
        guard let signatureBytes = Data(base64Encoded: manifest.signature) else {
            throw UpdateError.signatureInvalid
        }

        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        } catch {
            throw UpdateError.signingKeyMalformed
        }

        let payload = Data(manifest.signingPayload.utf8)
        guard key.isValidSignature(signatureBytes, for: payload) else {
            throw UpdateError.signatureInvalid
        }
    }
}

/// Everything that can go wrong, as sentences a person can act on.
public enum UpdateError: LocalizedError, Sendable, Equatable {
    case signingKeyMissing
    case signingKeyMalformed
    case signatureInvalid
    case unsupportedSchema(Int)
    case malformedManifest(String)
    case insecureURL(String)
    case hostNotAllowed(String)
    case channelMismatch(expected: String, offered: String)
    case unsupportedOS(required: String, running: String)
    case notNewer(current: String, offered: String)
    case unknownCurrentVersion
    case downloadFailed(String)
    case sizeMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: String, actual: String)
    case invalidArchive(String)
    case archiveShape(String)
    case bundleIdentifierMismatch(expected: String, actual: String)
    case codeSignatureRejected(String)
    case notWritable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signingKeyMissing:
            return "This build has no update signing key, so it cannot tell a real update from a forged one. Refusing to install."
        case .signingKeyMalformed:
            return "The update signing key in this build is not a valid Ed25519 public key."
        case .signatureInvalid:
            return "The update's signature did not verify. It may have been tampered with in transit."
        case .unsupportedSchema(let schema):
            return "The update describes itself as schema \(schema), which this build is too old to read."
        case .malformedManifest(let detail):
            return "The update manifest could not be read: \(detail)"
        case .insecureURL(let url):
            return "The update would be downloaded over an insecure connection: \(url)"
        case .hostNotAllowed(let host):
            return "The update points at \(host), which is not a host Bud will download from."
        case .channelMismatch(let expected, let offered):
            return "You are on the \(expected) channel but this release is \(offered)."
        case .unsupportedOS(let required, let running):
            return "This update needs macOS \(required). You are running \(running)."
        case .notNewer(let current, let offered):
            return "The feed offers \(offered), which is not newer than the running \(current)."
        case .unknownCurrentVersion:
            return "Bud cannot read its own version, so it cannot tell whether an update is newer."
        case .downloadFailed(let detail):
            return "The download failed: \(detail)"
        case .sizeMismatch(let expected, let actual):
            return "The download was \(actual) bytes; the manifest promised \(expected)."
        case .checksumMismatch(let expected, let actual):
            return "The download's checksum does not match the manifest (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .invalidArchive(let detail):
            return "The download is not a readable archive: \(detail)"
        case .archiveShape(let detail):
            return "The download is not shaped like an app: \(detail)"
        case .bundleIdentifierMismatch(let expected, let actual):
            return "The download is \(actual), not \(expected). Refusing to replace Bud with something else."
        case .codeSignatureRejected(let detail):
            return "macOS rejected the downloaded app's code signature: \(detail)"
        case .notWritable(let path):
            return "Bud cannot write to \(path). Move Bud somewhere you own, or install the update by hand."
        case .installFailed(let detail):
            return "The update could not be installed: \(detail)"
        }
    }
}

/// Where updates come from, and which ones are wanted.
///
/// A value rather than a set of config reads so the whole check can be exercised
/// against a local feed without touching the user's settings.
public struct UpdateFeed: Sendable, Hashable {
    /// The repository whose releases carry the appcast.
    public var repo: String
    /// An explicit manifest URL. Overrides `repo` when set, which is how a feed
    /// other than GitHub's is used — and how the end-to-end check drives this
    /// against a local server.
    public var manifestURL: String
    /// Token for a private repository's release assets. Falls back to the
    /// environment when empty.
    public var token: String
    /// `stable` or `prerelease`.
    public var channel: String
    /// The base64 Ed25519 public key this build trusts.
    public var publicKey: String

    public init(
        repo: String = "mriver15/bud",
        manifestURL: String = "",
        token: String = "",
        channel: String = "stable",
        publicKey: String = ""
    ) {
        self.repo = repo
        self.manifestURL = manifestURL
        self.token = token
        self.channel = channel
        self.publicKey = publicKey
    }

    /// Where the manifest is fetched from.
    ///
    /// GitHub's releases API needs the asset looked up by name, so the asset URL
    /// cannot be guessed — it is discovered from the release payload. A feed that
    /// is not GitHub hands over a URL directly.
    public var usesGitHubReleasesAPI: Bool { manifestURL.trimmingCharacters(in: .whitespaces).isEmpty }
}
