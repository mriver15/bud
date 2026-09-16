import BudKit
import Foundation

let arguments = CommandLine.arguments

// Acts as a real MCP server over stdio. Used by `--verify-live` to exercise the
// whole client stack without depending on npx, uvx or the network.
if arguments.contains("--mcp-echo-server") {
    EchoMCPServer.run()
}

// Offline assertion suite. Deterministic, no network. The release gate.
if arguments.contains("--self-test") {
    let report = BudSelfTest.run()
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
    UIRender.run(outputDirectory: path)
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
