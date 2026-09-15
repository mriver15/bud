import Foundation

/// Drives a check — and optionally an install — from the command line.
///
/// This exists because the updater's job is to replace the bundle it is running
/// from, and the only convincing test of that is to let it do so to a real copy
/// of the app. Driving it through the UI would exercise the same code more
/// slowly and far less reliably.
public enum UpdateCLI {
    @MainActor
    public static func run(install: Bool, arguments: [String]) async -> Bool {
        // Unbuffered, so a failure on stderr appears in the order it happened.
        // Block-buffered stdout flushes at exit, which puts every diagnostic
        // after the error it explains — and anything reading this output to
        // decide what went wrong would be reading it in the wrong order.
        setvbuf(stdout, nil, _IONBF, 0)

        var config = BudConfigLoader.load()

        if let index = arguments.firstIndex(of: "--feed"), arguments.count > index + 1 {
            config.updateFeedURL = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--channel"), arguments.count > index + 1 {
            config.updateChannel = arguments[index + 1]
        }

        let model = UpdateModel()
        guard let current = model.currentVersion else {
            fail(UpdateError.unknownCurrentVersion.errorDescription ?? "Bud cannot read its own version.")
            return false
        }
        print("running: \(current.display)  (\(Bundle.main.bundleURL.path))")

        await model.check(feed: config.updateFeed)

        switch model.phase {
        case .upToDate(let version):
            print("up to date: \(version.display)")
            return true

        case .available(let manifest):
            print("available: \(manifest.version) build \(manifest.build) [\(manifest.channel)]")
            print("  url    : \(manifest.url)")
            print("  size   : \(manifest.size) bytes")
            print("  sha256 : \(manifest.sha256)")
            print("  notes  : \(manifest.notes.replacingOccurrences(of: "\n", with: " "))")
            guard install else { return true }

            await model.install()
            switch model.phase {
            case .installed(let version):
                print("installed: \(version.display)")
                return true
            case .failed(let message):
                fail(message)
                return false
            default:
                fail("the install finished in an unexpected state: \(model.phase)")
                return false
            }

        case .failed(let message):
            fail(message)
            return false

        default:
            fail("the check finished in an unexpected state: \(model.phase)")
            return false
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("FAIL  \(message)\n".utf8))
    }
}
