import CryptoKit
import Foundation

/// Downloads, verifies and swaps in a new copy of Bud.
///
/// Split into stages that can each be run and inspected on their own, because
/// the failure modes here are asymmetric: refusing a good update is an
/// inconvenience, and installing a bad one is arbitrary code execution. Every
/// step between "bytes arrived" and "the bundle was replaced" is therefore a
/// separate function with its own check.
public enum UpdateInstaller {
    /// The archive, its checksum, the bundle identity and the code signature are
    /// all checked before anything is moved into place.
    public struct Staged: Sendable {
        public let manifest: UpdateManifest
        /// The verified app, sitting next to its destination so the swap is a
        /// rename rather than a copy.
        public let bundle: URL
        public let stagingDirectory: URL
    }

    // MARK: Staging

    /// Downloads and verifies an update, leaving it ready to swap in.
    ///
    /// The staging directory is deliberately a sibling of the destination. A
    /// rename is only atomic within a filesystem, and an update that is half
    /// copied when the machine sleeps is how an app ends up unlaunchable.
    public static func stage(
        manifest: UpdateManifest,
        destination: URL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Staged {
        let parent = destination.deletingLastPathComponent()
        try preflight(parent: parent)

        let staging = parent.appendingPathComponent(".bud-update-\(manifest.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // The staging directory holds an executable; nothing else needs to see in.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        do {
            let archive = staging.appendingPathComponent("Bud.zip")
            guard let url = URL(string: manifest.url) else {
                throw UpdateError.insecureURL(manifest.url)
            }
            try await download(url, to: archive, expectedSize: manifest.size, session: session, progress: progress)

            let actualSize = try fileSize(archive)
            guard actualSize == manifest.size else {
                throw UpdateError.sizeMismatch(expected: manifest.size, actual: actualSize)
            }
            let digest = try sha256(of: archive)
            guard digest == manifest.sha256.lowercased() else {
                throw UpdateError.checksumMismatch(expected: manifest.sha256.lowercased(), actual: digest)
            }

            let bundle = try extractVerifiedBundle(
                archive: archive,
                into: staging,
                expecting: Bundle.main.bundleIdentifier
            )
            progress(1)
            return Staged(manifest: manifest, bundle: bundle, stagingDirectory: staging)
        } catch {
            // A failed update must not leave megabytes of half-downloaded
            // archive beside the app for ever.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Unpacks the archive and refuses anything that is not a copy of Bud.
    ///
    /// The checksum proves the bytes are the ones that were signed. This proves
    /// what those bytes *are* — that the archive contains one application, that
    /// it is Bud rather than something wearing Bud's name, and that macOS still
    /// accepts its signature. A valid archive containing a different app is the
    /// failure the checksum cannot see.
    public static func extractVerifiedBundle(
        archive: URL,
        into staging: URL,
        expecting expectedIdentifier: String?
    ) throws -> URL {
        let extract = staging.appendingPathComponent("extract", isDirectory: true)
        try? FileManager.default.removeItem(at: extract)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)

        let result = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extract.path])
        guard result.status == 0 else {
            throw UpdateError.invalidArchive(result.output.isEmpty ? "ditto exited \(result.status)" : result.output)
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: extract, includingPropertiesForKeys: nil
        )) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let bundle = apps.first else {
            throw UpdateError.archiveShape(
                "expected exactly one .app at the top level of the archive, found \(apps.count)"
            )
        }

        if let expectedIdentifier {
            let actual = try bundleIdentifier(of: bundle)
            guard actual == expectedIdentifier else {
                throw UpdateError.bundleIdentifierMismatch(expected: expectedIdentifier, actual: actual)
            }
        }

        // `--strict` verifies the bundle's own signature and its resources.
        // Without it, a bundle whose contents were edited after signing would
        // still pass, which is the entire thing this is meant to catch.
        let verify = try run("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        guard verify.status == 0 else {
            throw UpdateError.codeSignatureRejected(
                verify.output.isEmpty ? "codesign exited \(verify.status)" : verify.output
            )
        }

        // Verified, so it is safe for it to run. Gatekeeper would otherwise
        // refuse a downloaded app that is not Developer ID signed, and Bud is
        // ad-hoc signed by design — the signature that matters here is the one
        // over the manifest, not the one macOS would ask a notary about.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path])

        let final = staging.appendingPathComponent("Bud.app")
        do {
            try FileManager.default.moveItem(at: bundle, to: final)
        } catch {
            throw UpdateError.installFailed("could not stage the verified app: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: extract)
        try? FileManager.default.removeItem(at: archive)
        return final
    }

    // MARK: Swapping

    /// Replaces `target` with `staged`, returning the backup it kept.
    ///
    /// Both moves are renames within one directory, so the window in which no
    /// app exists at the destination is a single syscall. If the second rename
    /// fails the first is undone before the error is returned, because leaving
    /// the user with no app at all is worse than leaving them the old one.
    @discardableResult
    public static func apply(staged: URL, replacing target: URL) throws -> URL {
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).bud-backup-\(Int(Date().timeIntervalSince1970))")

        do {
            try FileManager.default.moveItem(at: target, to: backup)
        } catch {
            throw UpdateError.installFailed("could not move the current app aside: \(error.localizedDescription)")
        }

        do {
            try FileManager.default.moveItem(at: staged, to: target)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: target)
            throw UpdateError.installFailed("could not put the new app in place: \(error.localizedDescription)")
        }

        // Belt and braces: the staged copy is verified, but the signature is
        // checked again at its final path. Moving a bundle is not supposed to
        // affect its signature, and if it did, this is the last moment anything
        // can be done about it.
        let verify = (try? run("/usr/bin/codesign", ["--verify", "--strict", target.path]))
            ?? CommandResult(status: 1, output: "codesign could not be run")
        guard verify.status == 0 else {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: backup, to: target)
            throw UpdateError.codeSignatureRejected(
                verify.output.isEmpty ? "the app failed verification after being moved" : verify.output
            )
        }

        // The staging directory has done its job and now holds only the emptied
        // shell it was built in. Left alone it would sit beside the app for ever,
        // one directory per update.
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())

        return backup
    }

    /// Puts a backup back, for when the new app turns out not to run.
    public static func restore(backup: URL, to target: URL) throws {
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: backup, to: target)
    }

    /// Removes backups left by earlier updates.
    ///
    /// Kept for a while after an update so a broken release can be put back, then
    /// removed: an app directory that quietly accumulates copies of itself is its
    /// own kind of bug.
    public static func cleanupStaleBackups(beside target: URL, olderThan seconds: TimeInterval = 86_400) {
        let parent = target.deletingLastPathComponent()
        let prefix = "\(target.lastPathComponent).bud-backup-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if Date().timeIntervalSince(modified) > seconds {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // MARK: Relaunching

    /// Brings Bud back once this process is gone.
    ///
    /// The relaunch cannot happen from here: `open` on a running app only
    /// activates the instance that is already there, so the updated copy would
    /// sit on disk while the old one kept running. A detached helper waits for
    /// this pid to disappear and then opens the app.
    ///
    /// The script is written here rather than fetched — a helper that downloads
    /// its own instructions would be a second, unchecked update path.
    public static func relaunchAfterExit(app: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("bud-relaunch-\(UUID().uuidString).sh")

        let script = """
        #!/bin/sh
        # Written by Bud to finish an update. Waits for the old process to exit,
        # then starts the new copy. Bounded so a pid that is never released
        # cannot leave this spinning for ever.
        pid="$1"
        app="$2"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.2
            i=$((i + 1))
            [ "$i" -gt 600 ] && exit 0
        done
        exec /usr/bin/open "$app"
        """

        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            throw UpdateError.installFailed("could not write the relaunch helper: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(pid), app.path]
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed("could not start the relaunch helper: \(error.localizedDescription)")
        }
    }

    // MARK: Plumbing

    /// Fails before a download rather than after one.
    ///
    /// An update that spends a minute fetching an archive only to discover it
    /// cannot write beside the app is a minute of the user's time spent to learn
    /// something that was knowable at the start.
    static func preflight(parent: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw UpdateError.notWritable(parent.path)
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }
    }

    private static func download(
        _ url: URL,
        to destination: URL,
        expectedSize: Int,
        session: URLSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Bud", forHTTPHeaderField: "User-Agent")
        // Release assets are served as bytes; the JSON accept header the metadata
        // calls use would ask GitHub for something it will not give.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        // The archive is about to be executed. Serving a previous download's
        // bytes because they share a URL is not a risk worth taking to save a
        // fetch, even though the checksum would catch it.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let monitor = TransferMonitor(limit: expectedSize, report: progress)
        let (temporary, response) = try await session.download(for: request, delegate: monitor)

        if let failure = monitor.failure {
            throw failure
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.downloadFailed("no HTTP response from \(url.host() ?? "the host")")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.downloadFailed("HTTP \(http.statusCode) from \(url.host() ?? "the host")")
        }

        // A redirect chain can land somewhere other than where the manifest
        // pointed, so the host is re-checked at the end rather than only at the
        // start. GitHub redirects release assets to a CDN, which is on the list.
        if let finalHost = http.url?.host()?.lowercased(),
           !UpdateManifest.allowedDownloadHosts.contains(finalHost) {
            throw UpdateError.hostNotAllowed(finalHost)
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
    }

    static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    /// Streamed rather than read in one go. An update archive is large, and the
    /// checksum is over bytes the user's machine is about to execute, so it is
    /// not worth holding all of it in memory to save a few lines.
    static func sha256(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw UpdateError.downloadFailed("the downloaded archive could not be read back")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func bundleIdentifier(of bundle: URL) throws -> String {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String
        else {
            throw UpdateError.archiveShape("the archive's app has no readable CFBundleIdentifier")
        }
        return identifier
    }

    struct CommandResult: Sendable {
        var status: Int32
        var output: String
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed("could not run \(launchPath): \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Watches a download and stops it if it grows past what the manifest promised.
///
/// The size is signed, so this is not what catches a forged manifest — the
/// checksum is. It stops a truncated or endless response from filling the disk
/// while the checksum that would have caught it is still being computed.
private final class TransferMonitor: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let report: @Sendable (Double) -> Void
    private var storedFailure: UpdateError?

    init(limit: Int, report: @escaping @Sendable (Double) -> Void) {
        self.limit = limit
        self.report = report
    }

    var failure: UpdateError? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let alreadyFailed = storedFailure != nil
        if !alreadyFailed, limit > 0, totalBytesWritten > Int64(limit) {
            storedFailure = .sizeMismatch(expected: limit, actual: Int(totalBytesWritten))
        }
        let failed = storedFailure != nil
        lock.unlock()

        if failed {
            downloadTask.cancel()
            return
        }
        if totalBytesExpectedToWrite > 0 {
            report(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }
    }
}
