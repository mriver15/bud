import BudKit
import Foundation

let arguments = CommandLine.arguments

/// Points the store at a scratch file for the rest of this process.
///
/// The command-line modes are not the app, but they run the app's code: they spawn
/// subagents that record their runs, read conversation history, and open the store
/// at startup. Against the real database that means the gate writes into the thing
/// it is checking — fifty-four rows titled "verify" had accumulated in the user's
/// roster, which is what the Agents screen showed instead of their own work.
///
/// Called before anything can touch the store, so a mode that forgets to think
/// about this is still safe.
func useScratchStore() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bud-cli-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    BudDatabase.shared = BudDatabase(url: directory.appendingPathComponent("bud.sqlite"))
    StoredResults.overrideDirectory = directory.appendingPathComponent("store", isDirectory: true)
}

let runsHeadless = arguments.contains("--self-test")
    || arguments.contains("--verify-live")
    || arguments.contains("--verify-browser")
    || arguments.contains("--verify-ui")
    || arguments.contains("--render-ui")
    || arguments.contains("--measure")
    || arguments.contains("--profile")
if runsHeadless { useScratchStore() }

// Acts as a real MCP server over stdio. Used by `--verify-live` to exercise the
// whole client stack without depending on npx, uvx or the network.
if arguments.contains("--mcp-echo-server") {
    EchoMCPServer.run()
}

// Offline assertion suite. Deterministic, no network. The release gate.
if arguments.contains("--self-test") {
    let report = await BudSelfTest.run()
    for failure in report.failures {
        FileHandle.standardError.write(Data("FAIL  \(failure)\n".utf8))
    }
    print(report.ok
          ? "PASS  \(report.passed)/\(report.total) checks passed"
          : "FAIL  \(report.passed)/\(report.total) checks passed")
    exit(report.ok ? 0 : 1)
}

// Launches the real panel and inspects the rendered layer tree, then exits.
// Proves Liquid Glass is live rather than a flat fallback.
if arguments.contains("--verify-ui") {
    BudUIVerification.run()
}

// End-to-end checks against the live DeepSeek API, the live MCP registry, and a
// real MCP server process.
if arguments.contains("--verify-live") {
    let report = await BudLiveVerification.run()
    for failure in report.failures {
        FileHandle.standardError.write(Data("FAIL  \(failure)\n".utf8))
    }
    print(report.ok
          ? "PASS  \(report.passed)/\(report.total) live checks passed"
          : "FAIL  \(report.passed)/\(report.total) live checks passed")
    exit(report.ok ? 0 : 1)
}

// Reports what a request costs in time, and where the time goes.
if arguments.contains("--profile") {
    let ok = await PerformanceProfileCLI.run(arguments: arguments)
    exit(ok ? 0 : 1)
}

// Reports what a request costs before any conversation: the tool block, the
// system prompt, and the notes that ride along on every message.
if arguments.contains("--measure") {
    let ok = await RequestMeasureCLI.run(arguments: arguments)
    exit(ok ? 0 : 1)
}

// Drives the real browser against local fixtures, with no network.
if arguments.contains("--verify-browser") {
    BudBrowserVerification.run()
}

// Renders each real surface to a PNG for visual review, then exits.
if let index = arguments.firstIndex(of: "--render-ui") {
    let path = arguments.count > index + 1
        ? arguments[index + 1]
        : FileManager.default.temporaryDirectory.appendingPathComponent("bud-ui").path
    // An optional third argument renders only surfaces whose name contains it.
    let filter = arguments.count > index + 2 ? arguments[index + 2] : ""
    UIRender.run(outputDirectory: path, only: filter)
}

// Checks the update feed, and optionally installs what it finds.
//
// The updater replaces the bundle it is running from, so the only honest way to
// test it is to let it do exactly that to a real copy of the app — driving it
// through the UI would prove the same thing more slowly and less reliably.
if arguments.contains("--check-update") || arguments.contains("--install-update") {
    let install = arguments.contains("--install-update")
    let ok = await UpdateCLI.run(install: install, arguments: arguments)
    exit(ok ? 0 : 1)
}

BudApp.main()
